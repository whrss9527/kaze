import XCTest
@testable import Proxi

/// 改名（ProxySwitch → Proxi）：数据目录、命令行脚本、同步文件夹、程序本身、旧的 URL 命令和发布包名字。
final class RenameTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("rename-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testMigrateDataDirectory() throws {
        let fm = FileManager.default
        let legacy = root.appendingPathComponent("Application Support/ProxySwitch", isDirectory: true)
        let current = root.appendingPathComponent("Application Support/Proxi", isDirectory: true)
        try fm.createDirectory(at: legacy.appendingPathComponent("imports"), withIntermediateDirectories: true)
        try Data("proxies: []\n".utf8).write(to: legacy.appendingPathComponent("imports/本机.yaml"))
        let legacyURL = Store.directoryURLString(legacy)
        XCTAssertTrue(legacyURL.hasPrefix("file://") && legacyURL.hasSuffix("/ProxySwitch/"), legacyURL)
        let config = """
        {"profiles":[{"id":"6D2F2A1E-0000-4000-8000-000000000001","name":"Charles","color":"#16a34a","kind":"http","host":"127.0.0.1","port":8888}],
         "engine":{"mode":"rule"}}
        """
        try Data(config.utf8).write(to: legacy.appendingPathComponent("config.json"))
        try Data("旧日志\n".utf8).write(to: legacy.appendingPathComponent("proxyswitch.log"))

        XCTAssertTrue(Store.migrate(from: legacy, to: current))
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
        XCTAssertTrue(fm.fileExists(atPath: current.appendingPathComponent("imports/本机.yaml").path))
        XCTAssertEqual(try String(contentsOf: current.appendingPathComponent("proxi.log"), encoding: .utf8), "旧日志\n")
        XCTAssertFalse(fm.fileExists(atPath: current.appendingPathComponent("proxyswitch.log").path))
        let migrated = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: current.appendingPathComponent("config.json")))
        XCTAssertEqual(migrated.profiles.map(\.name), ["Charles"])

        // 挪过一次就不再挪；新目录已经有了时也不动旧的（比如又运行过旧版本）。
        XCTAssertFalse(Store.migrate(from: legacy, to: current))
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        XCTAssertFalse(Store.migrate(from: legacy, to: current))
        XCTAssertTrue(fm.fileExists(atPath: legacy.path))
    }

    func testMigrateWithoutConfig() throws {
        // 只有日志和内核目录（还没加过配置）：照样整个挪过去。
        let fm = FileManager.default
        let legacy = root.appendingPathComponent("ProxySwitch", isDirectory: true)
        let current = root.appendingPathComponent("Proxi", isDirectory: true)
        try fm.createDirectory(at: legacy.appendingPathComponent("core"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: legacy.appendingPathComponent("core/cache.db"))
        XCTAssertTrue(Store.migrate(from: legacy, to: current))
        XCTAssertTrue(fm.fileExists(atPath: current.appendingPathComponent("core/cache.db").path))
        XCTAssertFalse(fm.fileExists(atPath: current.appendingPathComponent("config.json").path))
    }

    func testRelocatePaths() {
        let legacy = URL(fileURLWithPath: "/Users/me/Library/Application Support/ProxySwitch", isDirectory: true)
        let current = URL(fileURLWithPath: "/Users/me/Library/Application Support/Proxi", isDirectory: true)
        let text = #"{"a":"/Users/me/Library/Application Support/ProxySwitch/imports/x.yaml","b":"file:\/\/\/Users\/me\/Library\/Application%20Support\/ProxySwitch\/imports\/y.list","c":"file:///Users/me/Library/Application%20Support/ProxySwitch/z","d":"/Users/me/Library/Application Support/ProxySwitchOld/w"}"#
        let expected = #"{"a":"/Users/me/Library/Application Support/Proxi/imports/x.yaml","b":"file:\/\/\/Users\/me\/Library\/Application%20Support\/Proxi\/imports\/y.list","c":"file:///Users/me/Library/Application%20Support/Proxi/z","d":"/Users/me/Library/Application Support/ProxySwitchOld/w"}"#
        XCTAssertEqual(Store.relocatePaths(in: text, from: legacy, to: current), expected)
    }

    func testCommandLineScripts() {
        // 改名前装的脚本。
        let old = "#!/bin/sh\n# ProxySwitch 的命令行工具：proxyswitch help 看用法。\nexec '/Applications/ProxySwitch.app/Contents/MacOS/ProxySwitch' \"$@\"\n"
        XCTAssertTrue(CommandLineInstaller.isOurScript(old))
        XCTAssertEqual(CommandLineInstaller.target(of: old), "/Applications/ProxySwitch.app/Contents/MacOS/ProxySwitch")
        // 路径里有空格和单引号也能原样读回来。
        let path = "/Users/me/My Apps/it's/Proxi.app/Contents/MacOS/Proxi"
        let script = CommandLineInstaller.script(for: path)
        XCTAssertTrue(script.contains("proxi help"))
        XCTAssertTrue(CommandLineInstaller.isOurScript(script))
        XCTAssertEqual(CommandLineInstaller.target(of: script), path)
        // 别的程序的同名文件不认。
        XCTAssertFalse(CommandLineInstaller.isOurScript("#!/usr/bin/env node\nrequire('proxi')\n"))
        XCTAssertNil(CommandLineInstaller.target(of: "#!/bin/sh\necho hi\n"))
        XCTAssertEqual(CommandLineInstaller.path, "/usr/local/bin/proxi")
        XCTAssertEqual(CommandLineInstaller.legacyPath, "/usr/local/bin/proxyswitch")
        XCTAssertTrue(CommandLineInstaller.mcpConfig.contains("\"proxi\""))
        XCTAssertTrue(CommandLineInstaller.mcpCommand.hasPrefix("claude mcp add proxi -- "))
    }

    func testSocketPath() {
        XCTAssertTrue(UnixSocket.defaultPath.hasSuffix("/Proxi/control.sock"), UnixSocket.defaultPath)
    }

    #if os(macOS)
    func testLegacyURLScheme() {
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://toggle")!), .toggle)
        XCTAssertEqual(URLCommand.parse(URL(string: "PROXYSWITCH://off")!), .turnOff)
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://use?name=%E5%85%AC%E5%8F%B8")!), .use("公司"))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://toggle")!), .toggle)
        XCTAssertEqual(URLCommand.parse(URL(string: "Proxi://on")!), .turnOn)
        XCTAssertNil(URLCommand.parse(URL(string: "https://example.com/toggle")!))
    }

    func testBundleRenameTarget() {
        let legacy = URL(fileURLWithPath: "/Applications/ProxySwitch.app", isDirectory: true)
        XCTAssertEqual(BundleRename.target(for: legacy, exists: { _ in false })?.path, "/Applications/Proxi.app")
        // 同一个文件夹里已经有 Proxi.app：不改（不覆盖别的东西）。
        XCTAssertNil(BundleRename.target(for: legacy, exists: { $0.lastPathComponent == "Proxi.app" }))
        XCTAssertNil(BundleRename.target(for: URL(fileURLWithPath: "/Applications/Proxi.app", isDirectory: true), exists: { _ in false }))
        XCTAssertNil(BundleRename.target(for: URL(fileURLWithPath: "/Users/me/Downloads/ProxySwitch (1).app", isDirectory: true), exists: { _ in false }))
        XCTAssertEqual(BundleRename.target(for: URL(fileURLWithPath: "/Users/me/Applications/ProxySwitch.app"), exists: { _ in false })?.path, "/Users/me/Applications/Proxi.app")
    }

    func testUpdateAssetNames() {
        XCTAssertEqual(UpdateChecker.archiveName, "Proxi-macos.zip")
        XCTAssertEqual(UpdateChecker.thinArchiveName(for: "arm64"), "Proxi-macos-arm64.zip")
        XCTAssertTrue(UpdateChecker.userAgent.hasPrefix("Proxi/"))
        // 发布里新旧名字的包都有（旧名字的给改名前的版本更新用）：选新名字的。
        let json = """
        {"tag_name":"v0.11.0","assets":[
          {"name":"ProxySwitch-macos-arm64.zip","size":1,"browser_download_url":"https://x/ProxySwitch-macos-arm64.zip"},
          {"name":"ProxySwitch-macos.zip","size":1,"browser_download_url":"https://x/ProxySwitch-macos.zip"},
          {"name":"Proxi-macos.zip","size":3,"browser_download_url":"https://x/Proxi-macos.zip"},
          {"name":"Proxi-macos-arm64.zip","size":2,"browser_download_url":"https://x/Proxi-macos-arm64.zip"},
          {"name":"SHA256SUMS.txt","size":1,"browser_download_url":"https://x/SHA256SUMS.txt"}]}
        """
        XCTAssertEqual(UpdateChecker.parse(Data(json.utf8), architecture: "arm64")?.archiveName, "Proxi-macos-arm64.zip")
        XCTAssertEqual(UpdateChecker.parse(Data(json.utf8), architecture: "x86_64")?.archiveName, "Proxi-macos.zip")
        if ProcessInfo.processInfo.environment[UpdateChecker.overrideVariable] == nil {
            XCTAssertEqual(UpdateChecker.apiURL.absoluteString, "https://api.github.com/repos/whrss9527/proxi/releases/latest")
        }
        XCTAssertEqual(InstallLocation.appName, "Proxi.app")
    }

    func testCloudFolderMigration() throws {
        guard ProcessInfo.processInfo.environment[CloudFile.overrideVariable] == nil else { throw XCTSkip("指定了同步文件夹") }
        let drive = root.appendingPathComponent("CloudDocs", isDirectory: true)
        let legacyFile = drive.appendingPathComponent("ProxySwitch/config.json")
        let file = drive.appendingPathComponent("Proxi/config.json")
        // 旧文件夹里没有：不动。
        XCTAssertFalse(CloudFile.migrateLegacyFolder(drive: drive))
        var config = AppConfig()
        config.profiles = [Profile(name: "公司代理", color: ProfilePalette.colors[1], host: "proxy.corp", port: 3128)]
        let old = SyncedConfig(updatedAt: Date(timeIntervalSince1970: 1_000), device: "另一台 Mac", config: config)
        try CloudFile.write(old, to: legacyFile)
        XCTAssertTrue(CloudFile.migrateLegacyFolder(drive: drive))
        let copied = try XCTUnwrap(CloudFile.read(at: file))
        XCTAssertEqual(copied.device, "另一台 Mac")
        XCTAssertEqual(copied.updatedAt, old.updatedAt)
        XCTAssertEqual(copied.config.profiles.map(\.name), ["公司代理"])
        // 旧文件夹里的留着，给还没更新的 Mac 用。
        XCTAssertEqual(try CloudFile.read(at: legacyFile)?.config.profiles.map(\.name), ["公司代理"])
        // 复制过了、旧的没有更新：不再复制。
        XCTAssertFalse(CloudFile.migrateLegacyFolder(drive: drive))
        // 新文件夹里的更新：不覆盖。
        try CloudFile.write(SyncedConfig(updatedAt: Date(timeIntervalSince1970: 3_000), device: "这台", config: AppConfig()), to: file)
        XCTAssertFalse(CloudFile.migrateLegacyFolder(drive: drive))
        XCTAssertEqual(try CloudFile.read(at: file)?.device, "这台")
        // 还没更新的 Mac 之后又往旧文件夹写了更新的：复制过来。
        try CloudFile.write(SyncedConfig(updatedAt: Date(timeIntervalSince1970: 5_000), device: "旧版本的 Mac", config: config), to: legacyFile)
        XCTAssertTrue(CloudFile.migrateLegacyFolder(drive: drive))
        XCTAssertEqual(try CloudFile.read(at: file)?.device, "旧版本的 Mac")
    }
    #endif
}
