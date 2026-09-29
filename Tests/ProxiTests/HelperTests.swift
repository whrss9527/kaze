import XCTest
@testable import Proxi
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class HelperTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ps-helper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("source/rules"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("target"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSafeRelativePaths() {
        for good in ["config.yaml", "rules/rs-1234.list", "providers/manual.txt", "Country.mmdb"] {
            XCTAssertTrue(HelperFiles.isSafeRelativePath(good), good)
        }
        for bad in ["", "/etc/passwd", "../x", "rules/../../x", "rules//x", "./config.yaml", "rules/.", "a\0b", String(repeating: "a", count: 1100)] {
            XCTAssertFalse(HelperFiles.isSafeRelativePath(bad), bad)
        }
    }

    func testCopiesOnlyRegularFilesOfTheOwner() throws {
        let source = root.appendingPathComponent("source").path
        let target = root.appendingPathComponent("target").path
        let owner = UInt32(getuid())
        try "mixed-port: 7890\n".write(toFile: source + "/config.yaml", atomically: true, encoding: .utf8)
        try "DOMAIN,a.com\n".write(toFile: source + "/rules/a.list", atomically: true, encoding: .utf8)
        try HelperFiles.copy(["config.yaml", "rules/a.list"], from: source, to: target, owner: owner)
        XCTAssertEqual(try String(contentsOfFile: target + "/config.yaml", encoding: .utf8), "mixed-port: 7890\n")
        XCTAssertEqual(try String(contentsOfFile: target + "/rules/a.list", encoding: .utf8), "DOMAIN,a.com\n")
        // 再复制一次会覆盖，不留临时文件。
        try "mixed-port: 7891\n".write(toFile: source + "/config.yaml", atomically: true, encoding: .utf8)
        try HelperFiles.copy(["config.yaml"], from: source, to: target, owner: owner)
        XCTAssertEqual(try String(contentsOfFile: target + "/config.yaml", encoding: .utf8), "mixed-port: 7891\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target + "/config.yaml.ps-tmp"))

        // 符号链接（哪怕指向自己的文件）、目录、别人的文件、不安全的路径都不复制。
        try FileManager.default.createSymbolicLink(atPath: source + "/link.yaml", withDestinationPath: source + "/config.yaml")
        XCTAssertThrowsError(try HelperFiles.copy(["link.yaml"], from: source, to: target, owner: owner))
        XCTAssertThrowsError(try HelperFiles.copy(["rules"], from: source, to: target, owner: owner))
        XCTAssertThrowsError(try HelperFiles.copy(["config.yaml"], from: source, to: target, owner: owner &+ 1))
        XCTAssertThrowsError(try HelperFiles.copy(["../source/config.yaml"], from: source, to: target, owner: owner))
        XCTAssertThrowsError(try HelperFiles.copy(["missing.yaml"], from: source, to: target, owner: owner))
        XCTAssertThrowsError(try HelperFiles.copy(["config.yaml"], from: "relative/dir", to: target, owner: owner))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target + "/link.yaml"))
    }

    func testLaunchdPlist() throws {
        let data = try HelperInstaller.plist(uid: 501, appVersion: "0.10.0")
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["Label"] as? String, HelperPaths.label)
        XCTAssertEqual(plist["ProgramArguments"] as? [String], [HelperPaths.executable, "helper", "run", "--uid", "501", "--version", "0.10.0"])
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? Bool, true)
    }

    func testStatusAndVersions() {
        let status = HelperStatus(["protocol": HelperProtocol.version, "version": "0.10.0", "core": "v1.19.31", "running": true, "forwarding": false])
        XCTAssertTrue(status.isCurrent)
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.coreVersion, "v1.19.31")
        XCTAssertFalse(HelperStatus(["protocol": 0]).isCurrent)
        XCTAssertEqual(HelperDaemon.coreVersion(from: "Mihomo Meta v1.19.31 darwin arm64 with go1.26.8"), "v1.19.31")
        XCTAssertNil(HelperDaemon.coreVersion(from: "garbage"))
        // 内核目录在 root 的数据目录里，和用户的目录分开。
        XCTAssertTrue(HelperPaths.coreDirectory.hasPrefix(HelperPaths.dataDirectory + "/"))
        XCTAssertFalse(HelperPaths.coreDirectory.contains("~"))
    }
}
