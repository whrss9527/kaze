import XCTest
@testable import ProxySwitch

final class DesiredProxyTests: XCTestCase {
    func testHttpProfileCommands() {
        var profile = Profile(name: "本机", color: "#16a34a", kind: .http, host: "127.0.0.1", port: 7890)
        profile.bypass = "localhost, 10.*, <local>"
        let commands = DesiredProxy(profile: profile).commands(service: "Wi-Fi").map { $0.joined(separator: " ") }
        XCTAssertEqual(commands, [
            "-setwebproxy Wi-Fi 127.0.0.1 7890",
            "-setwebproxystate Wi-Fi on",
            "-setsecurewebproxy Wi-Fi 127.0.0.1 7890",
            "-setsecurewebproxystate Wi-Fi on",
            "-setsocksfirewallproxystate Wi-Fi off",
            "-setautoproxystate Wi-Fi off",
            "-setproxyautodiscovery Wi-Fi off",
            "-setproxybypassdomains Wi-Fi localhost 10.0.0.0/8",
        ])
    }

    func testOffKeepsAddressesAndRestoresDiscovery() {
        let commands = DesiredProxy(offWithAutoDiscovery: true, bypassDomains: []).commands(service: "以太网").map { $0.joined(separator: " ") }
        XCTAssertFalse(commands.contains { $0.hasPrefix("-setwebproxy ") || $0.hasPrefix("-setsecurewebproxy ") || $0.hasPrefix("-setautoproxyurl") })
        XCTAssertTrue(commands.contains("-setproxyautodiscovery 以太网 on"))
        XCTAssertEqual(commands.last, "-setproxybypassdomains 以太网 Empty")
    }

    func testPacAndSocks() {
        let pac = Profile(name: "PAC", color: "#000000", kind: .pac, pacURL: "http://127.0.0.1:7890/proxy.pac")
        let pacCommands = DesiredProxy(profile: pac).commands(service: "Wi-Fi").map { $0.joined(separator: " ") }
        XCTAssertTrue(pacCommands.contains("-setautoproxyurl Wi-Fi http://127.0.0.1:7890/proxy.pac"))
        XCTAssertTrue(pacCommands.contains("-setautoproxystate Wi-Fi on"))
        XCTAssertTrue(pacCommands.contains("-setwebproxystate Wi-Fi off"))

        let socks = Profile(name: "SOCKS", color: "#000000", kind: .socks5, host: "127.0.0.1", port: 1080)
        let socksCommands = DesiredProxy(profile: socks).commands(service: "Wi-Fi").map { $0.joined(separator: " ") }
        XCTAssertTrue(socksCommands.contains("-setsocksfirewallproxy Wi-Fi 127.0.0.1 1080"))
        XCTAssertTrue(socksCommands.contains("-setsocksfirewallproxystate Wi-Fi on"))
        XCTAssertTrue(socksCommands.contains("-setwebproxystate Wi-Fi off"))
    }

    func testRestoreSnapshot() {
        var snapshot = ProxySnapshot()
        snapshot.httpEnabled = true
        snapshot.httpHost = "proxy.corp"
        snapshot.httpPort = 3128
        snapshot.autoDiscovery = true
        snapshot.exceptions = ["*.corp"]
        let desired = DesiredProxy(restoring: snapshot)
        XCTAssertEqual(desired.http, DesiredProxy.Endpoint(host: "proxy.corp", port: 3128))
        XCTAssertTrue(desired.autoDiscovery)
        XCTAssertEqual(desired.bypassDomains, ["*.corp"])
    }
}

final class BypassListTests: XCTestCase {
    func testConversion() {
        XCTAssertEqual(BypassList.domains(from: "localhost;127.*;10.*;172.16.*;192.168.1.*;<local>;*.local, 169.254/16"),
                       ["localhost", "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/16", "192.168.1.0/24", "*.local", "169.254/16"])
        XCTAssertEqual(BypassList.domains(from: ""), [])
        XCTAssertEqual(BypassList.domains(from: "a.com, a.com"), ["a.com"])
    }
}

final class ProxySnapshotTests: XCTestCase {
    func testParseAndMatch() {
        let snapshot = ProxySnapshot(dictionary: [
            "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 7890,
            "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890,
            "SOCKSEnable": 0, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 7891,
            "ProxyAutoConfigEnable": 0, "ProxyAutoConfigURLString": "http://x/proxy.pac",
            "ProxyAutoDiscoveryEnable": 1, "ExceptionsList": ["*.local", "169.254/16"],
        ])
        XCTAssertTrue(snapshot.isActive)
        XCTAssertTrue(snapshot.httpActive)
        XCTAssertFalse(snapshot.socksActive)
        XCTAssertFalse(snapshot.pacActive)
        XCTAssertTrue(snapshot.autoDiscovery)
        XCTAssertEqual(snapshot.summary, "127.0.0.1:7890")
        let profile = Profile(name: "本机", color: "#16a34a", kind: .http, host: "127.0.0.1", port: 7890)
        XCTAssertTrue(snapshot.matches(profile))
        let other = Profile(name: "其他", color: "#16a34a", kind: .http, host: "127.0.0.1", port: 8080)
        XCTAssertFalse(snapshot.matches(other))
        let socks = Profile(name: "SOCKS", color: "#16a34a", kind: .socks5, host: "127.0.0.1", port: 7891)
        XCTAssertFalse(snapshot.matches(socks))
        XCTAssertEqual(snapshot.asProfile(name: "系统代理")?.serverAddress, "127.0.0.1:7890")
        XCTAssertFalse(ProxySnapshot(dictionary: [:]).isActive)
        XCTAssertEqual(ProxySnapshot(dictionary: [:]).summary, "未开启")
    }

    func testPacMatchIgnoresCase() {
        let snapshot = ProxySnapshot(dictionary: ["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "http://127.0.0.1:7890/Proxy.pac"])
        let profile = Profile(name: "PAC", color: "#000", kind: .pac, pacURL: "http://127.0.0.1:7890/proxy.pac")
        XCTAssertTrue(snapshot.matches(profile))
        XCTAssertEqual(snapshot.summary, "PAC http://127.0.0.1:7890/Proxy.pac")
    }
}

final class NpmProxyTests: XCTestCase {
    func testUpdate() {
        let content = "registry=https://registry.npmmirror.com\nproxy=http://old:1\nhttps-proxy=http://old:1\n"
        let updated = NpmProxy.update(content, proxyURL: "http://127.0.0.1:7890", noProxy: "localhost")
        XCTAssertEqual(updated, "registry=https://registry.npmmirror.com\nproxy=http://127.0.0.1:7890\nhttps-proxy=http://127.0.0.1:7890\nnoproxy=localhost\n")
        XCTAssertEqual(NpmProxy.update(updated, proxyURL: "", noProxy: ""), "registry=https://registry.npmmirror.com\n")
        XCTAssertEqual(NpmProxy.update("", proxyURL: "", noProxy: ""), "")
    }
}

final class TerminalCommandsTests: XCTestCase {
    func testExportAndFish() {
        let export = TerminalCommands.export(proxyURL: "http://127.0.0.1:7890", noProxy: "it's")
        XCTAssertTrue(export.hasPrefix("export http_proxy='http://127.0.0.1:7890' https_proxy='http://127.0.0.1:7890' no_proxy='it'\\''s' HTTP_PROXY="))
        let fish = TerminalCommands.fish(proxyURL: "socks5://127.0.0.1:1080", noProxy: "")
        XCTAssertTrue(fish.hasPrefix("set -gx http_proxy 'socks5://127.0.0.1:1080'; set -gx HTTP_PROXY 'socks5://127.0.0.1:1080'; "))
        XCTAssertTrue(fish.contains("set -gx no_proxy '\(Profile.defaultNoProxy)'"))
    }
}

final class ParsingTests: XCTestCase {
    func testLsof() {
        let output = "p512\ncClashX\nf23\nn*:7890\nf24\nn127.0.0.1:7891\np9000\ncnode\nf18\nn[::1]:3000\n"
        let listeners = LocalProxyDetector.parseLsof(output)
        XCTAssertEqual(listeners, [
            LocalProxyDetector.Listener(port: 7890, process: "ClashX"),
            LocalProxyDetector.Listener(port: 7891, process: "ClashX"),
            LocalProxyDetector.Listener(port: 3000, process: "node"),
        ])
    }

    func testURLCommands() {
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://toggle")!), .toggle)
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://on")!), .turnOn)
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://off")!), .turnOff)
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://settings")!), .settings(nil))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://settings?page=about")!), .settings(.about))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://settings?page=nope")!), .settings(nil))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://panel")!), .panel)
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://update")!), .update)
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://use?name=%E5%85%AC%E5%8F%B8")!), .use("公司"))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://use/home")!), .use("home"))
        XCTAssertNil(URLCommand.parse(URL(string: "proxyswitch://nope")!))
        XCTAssertNil(URLCommand.parse(URL(string: "https://example.com/toggle")!))
    }

    func testServiceSelection() {
        let services = [
            NetworkServices.Service(name: "Wi-Fi", bsdName: "en0", enabled: true),
            NetworkServices.Service(name: "Thunderbolt Bridge", bsdName: "bridge0", enabled: true),
            NetworkServices.Service(name: "Bluetooth PAN", bsdName: "en3", enabled: false),
            NetworkServices.Service(name: "VPN", bsdName: nil, enabled: true),
        ]
        XCTAssertEqual(NetworkServices.select(services: services) { $0 == "en0" || $0 == "en3" }, ["Wi-Fi"])
        XCTAssertEqual(NetworkServices.select(services: services) { _ in false }, ["Wi-Fi", "Thunderbolt Bridge", "VPN"])
    }

    func testVersionCompare() {
        XCTAssertTrue(UpdateChecker.isNewer("1.2.0", than: "1.1.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.2", than: "1.1.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.1.9", than: "1.1.9"))
        XCTAssertFalse(UpdateChecker.isNewer("0.9", than: "1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("v0.2.0", than: "0.1.9"))
        // 预发布版本比同号的正式版本旧，但比更早的正式版本新。
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0-beta.1", than: "0.1.1"))
        XCTAssertFalse(UpdateChecker.isNewer("0.2.0-beta.1", than: "0.2.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.2.0-beta.1"))
    }

    func testReleaseParse() throws {
        let json = """
        {"tag_name":"v0.2.0","html_url":"https://github.com/whrss9527/proxyswitch-mac/releases/tag/v0.2.0",
         "body":"- 一键更新\\n- 修复","published_at":"2026-09-24T08:56:44Z","draft":false,"prerelease":false,
         "assets":[{"name":"ProxySwitch-macos.zip","size":1186132,"browser_download_url":"https://github.com/whrss9527/proxyswitch-mac/releases/download/v0.2.0/ProxySwitch-macos.zip"},
                   {"name":"SHA256SUMS.txt","size":89,"browser_download_url":"https://github.com/whrss9527/proxyswitch-mac/releases/download/v0.2.0/SHA256SUMS.txt"}]}
        """
        let release = try XCTUnwrap(UpdateChecker.parse(Data(json.utf8)))
        XCTAssertEqual(release.version, "0.2.0")
        XCTAssertEqual(release.tag, "v0.2.0")
        XCTAssertEqual(release.pageURL.absoluteString, "https://github.com/whrss9527/proxyswitch-mac/releases/tag/v0.2.0")
        XCTAssertEqual(release.notes, "- 一键更新\n- 修复")
        XCTAssertNotNil(release.publishedAt)
        XCTAssertEqual(release.archiveSize, 1186132)
        XCTAssertEqual(release.archiveURL?.lastPathComponent, "ProxySwitch-macos.zip")
        XCTAssertEqual(release.checksumsURL?.lastPathComponent, "SHA256SUMS.txt")
        XCTAssertTrue(release.canInstall)

        let bare = try XCTUnwrap(UpdateChecker.parse(Data(#"{"tag_name":"0.3.0","assets":[]}"#.utf8)))
        XCTAssertEqual(bare.version, "0.3.0")
        XCTAssertFalse(bare.canInstall)
        XCTAssertEqual(bare.pageURL, UpdateChecker.releasesURL)
        XCTAssertNil(UpdateChecker.parse(Data("{}".utf8)))
        XCTAssertNil(UpdateChecker.parse(Data("not json".utf8)))
    }

    func testChecksums() throws {
        let text = """
        说明行
        0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0  ProxySwitch-macos.zip
        DEADBEEF  太短的
        5891B5B522D5DF086D0FF0B110FBD9D21BB4FC7163AF34D08286A2E846F6BE03 *hello.txt
        """
        XCTAssertEqual(Checksums.parse(text), [
            "ProxySwitch-macos.zip": "0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0",
            "hello.txt": "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03",
        ])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("checksum-\(UUID().uuidString).bin")
        try Data("hello\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try Checksums.sha256(of: file), "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03")
    }

    func testInstallPlan() {
        let apps = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let home = URL(fileURLWithPath: "/Users/me/Applications", isDirectory: true)
        let folders = [apps, home]
        let everything: (URL) -> Bool = { _ in true }
        let onlyHome: (URL) -> Bool = { $0 == home }
        let installed = URL(fileURLWithPath: "/Applications/ProxySwitch.app")
        let downloads = URL(fileURLWithPath: "/Users/me/Downloads/ProxySwitch.app")
        let translocated = URL(fileURLWithPath: "/private/var/folders/ab/T/AppTranslocation/1234/d/ProxySwitch.app")

        // 平时：原地替换。
        XCTAssertEqual(InstallLocation.plan(bundle: installed, translocated: false, original: nil, readOnly: false, folders: folders, canWrite: everything),
                       InstallPlan(target: installed, trashAfter: nil, relocating: false))
        // 在下载文件夹里直接打开（被系统搬到临时位置）：装进「应用程序」，旧的移到废纸篓。
        XCTAssertEqual(InstallLocation.plan(bundle: translocated, translocated: true, original: downloads, readOnly: true, folders: folders, canWrite: everything),
                       InstallPlan(target: installed, trashAfter: downloads, relocating: true))
        // 标准账户写不了 /Applications：装进 ~/Applications，不用输密码。
        XCTAssertEqual(InstallLocation.plan(bundle: translocated, translocated: true, original: downloads, readOnly: true, folders: folders, canWrite: onlyHome),
                       InstallPlan(target: home.appendingPathComponent("ProxySwitch.app"), trashAfter: downloads, relocating: true))
        // 本来就在「应用程序」里、只是带着隔离标记被搬走运行：原地替换。
        XCTAssertEqual(InstallLocation.plan(bundle: translocated, translocated: true, original: installed, readOnly: true, folders: folders, canWrite: everything),
                       InstallPlan(target: installed, trashAfter: nil, relocating: false))
        // 找不到原来的位置：装进「应用程序」，不删别的。
        XCTAssertEqual(InstallLocation.plan(bundle: translocated, translocated: true, original: nil, readOnly: true, folders: folders, canWrite: everything),
                       InstallPlan(target: installed, trashAfter: nil, relocating: true))
        // 浏览器给重名文件加了后缀：装回标准名字。
        let renamed = URL(fileURLWithPath: "/Users/me/Downloads/ProxySwitch (1).app")
        XCTAssertEqual(InstallLocation.plan(bundle: translocated, translocated: true, original: renamed, readOnly: true, folders: folders, canWrite: everything)?.target.path, installed.path)
        // 只读的磁盘（比如挂载的映像）：也搬。
        XCTAssertEqual(InstallLocation.plan(bundle: URL(fileURLWithPath: "/Volumes/PS/ProxySwitch.app"), translocated: false, original: nil, readOnly: true, folders: folders, canWrite: everything)?.relocating, true)
        // 不是 .app（开发时 swift run）：没法更新。
        XCTAssertNil(InstallLocation.plan(bundle: URL(fileURLWithPath: "/Users/me/.build/debug"), translocated: false, original: nil, readOnly: false, folders: folders, canWrite: everything))
        XCTAssertEqual(InstallLocation.displayName(of: apps), "「应用程序」")
    }

    func testTranslocationLookup() {
        // Security 框架里的函数要能找到，普通位置不算被搬走。
        XCTAssertTrue(Translocation.available)
        XCTAssertFalse(Translocation.isTranslocated(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        XCTAssertTrue(Translocation.isTranslocated(URL(fileURLWithPath: "/private/var/folders/ab/T/AppTranslocation/1234/d/ProxySwitch.app")))
    }

    func testNetworkRoutes() {
        let github = URL(string: "https://github.com/whrss9527/proxyswitch-mac/releases/download/v1/ProxySwitch-macos.zip")!
        var off = ProxySnapshot()
        off.httpEnabled = false
        var coreProxy = ProxySnapshot()
        coreProxy.httpEnabled = true; coreProxy.httpHost = "127.0.0.1"; coreProxy.httpPort = 7890
        coreProxy.httpsEnabled = true; coreProxy.httpsHost = "127.0.0.1"; coreProxy.httpsPort = 7890
        var other = ProxySnapshot()
        other.httpsEnabled = true; other.httpsHost = "proxy.corp"; other.httpsPort = 3128

        XCTAssertEqual(NetworkRoute.routes(for: github, corePort: 7890, system: off), [.core(7890), .direct])
        XCTAssertEqual(NetworkRoute.routes(for: github, corePort: 7890, system: coreProxy), [.core(7890), .direct])
        XCTAssertEqual(NetworkRoute.routes(for: github, corePort: 7890, system: other), [.core(7890), .system, .direct])
        XCTAssertEqual(NetworkRoute.routes(for: github, corePort: nil, system: other), [.system, .direct])
        XCTAssertEqual(NetworkRoute.routes(for: github, corePort: nil, system: off), [.direct])
        // 本机地址（测试用的发布源）不经代理。
        XCTAssertEqual(NetworkRoute.routes(for: URL(string: "http://127.0.0.1:8765/latest.json")!, corePort: 7890, system: other), [.direct])
        XCTAssertTrue(coreProxy.pointsAtLocalhost(port: 7890))
        XCTAssertFalse(coreProxy.pointsAtLocalhost(port: 7891))

        let configuration = URLSessionConfiguration.ephemeral
        NetworkRoute.core(7890).apply(to: configuration)
        XCTAssertEqual(configuration.connectionProxyDictionary?[kCFNetworkProxiesHTTPSPort as String] as? Int, 7890)
        NetworkRoute.direct.apply(to: configuration)
        XCTAssertEqual(configuration.connectionProxyDictionary?.count, 0)
        NetworkRoute.system.apply(to: configuration)
        XCTAssertNil(configuration.connectionProxyDictionary)
    }

    func testThinArchiveSelection() throws {
        let json = """
        {"tag_name":"v0.5.0","assets":[
          {"name":"ProxySwitch-macos.zip","size":49000000,"browser_download_url":"https://x/ProxySwitch-macos.zip"},
          {"name":"ProxySwitch-macos-arm64.zip","size":25000000,"browser_download_url":"https://x/ProxySwitch-macos-arm64.zip"},
          {"name":"SHA256SUMS.txt","size":300,"browser_download_url":"https://x/SHA256SUMS.txt"}]}
        """
        let arm = try XCTUnwrap(UpdateChecker.parse(Data(json.utf8), architecture: "arm64"))
        XCTAssertEqual(arm.archiveName, "ProxySwitch-macos-arm64.zip")
        XCTAssertEqual(arm.archiveSize, 25000000)
        // 没有这个架构的精简包时用通用包。
        let intel = try XCTUnwrap(UpdateChecker.parse(Data(json.utf8), architecture: "x86_64"))
        XCTAssertEqual(intel.archiveName, "ProxySwitch-macos.zip")
        XCTAssertTrue(["arm64", "x86_64"].contains(UpdateChecker.machineArchitecture))
    }

    func testPermissionErrorMapping() {
        func cocoa(_ posix: Int32) -> NSError {
            NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(posix))])
        }
        XCTAssertTrue(UpdateInstaller.needsAdmin(cocoa(EACCES)))
        XCTAssertFalse(UpdateInstaller.isBlockedBySystem(cocoa(EACCES)))
        XCTAssertTrue(UpdateInstaller.isBlockedBySystem(cocoa(EPERM)))
        XCTAssertFalse(UpdateInstaller.needsAdmin(cocoa(EPERM)))
        XCTAssertTrue(UpdateInstaller.needsAdmin(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
        XCTAssertFalse(UpdateInstaller.needsAdmin(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
    }

    func testInstallReplacesAndCreates() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("install-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        func makeApp(_ url: URL, marker: String) throws {
            try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
            try Data(marker.utf8).write(to: url.appendingPathComponent("Contents/\(marker)"))
        }
        // 替换已有的。
        let target = root.appendingPathComponent("Applications/ProxySwitch.app")
        try makeApp(target, marker: "old")
        let newApp = root.appendingPathComponent("download/ProxySwitch.app")
        try makeApp(newApp, marker: "new")
        try await UpdateInstaller.install(newApp: newApp, replacing: target)
        XCTAssertTrue(fm.fileExists(atPath: target.appendingPathComponent("Contents/new").path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathComponent("Contents/old").path))
        XCTAssertFalse(fm.fileExists(atPath: newApp.path))
        let leftovers = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Applications").path)
        XCTAssertEqual(leftovers, ["ProxySwitch.app"])
        // 目标文件夹还不存在（比如 ~/Applications）：建出来再放进去。
        let fresh = root.appendingPathComponent("Home/Applications/ProxySwitch.app")
        let another = root.appendingPathComponent("download2/ProxySwitch.app")
        try makeApp(another, marker: "v2")
        try await UpdateInstaller.install(newApp: another, replacing: fresh)
        XCTAssertTrue(fm.fileExists(atPath: fresh.appendingPathComponent("Contents/v2").path))
    }

    func testSyncedConfigRoundTripAndMerge() throws {
        var config = AppConfig()
        config.profiles = [Profile(name: "a", color: "#111111", kind: .socks5, host: "h", port: 1)]
        let synced = SyncedConfig(updatedAt: Date(timeIntervalSince1970: 1_800_000_000), device: "MacBook", config: config)
        let data = try CloudFile.encoder.encode(synced)
        let decoded = try CloudFile.decoder.decode(SyncedConfig.self, from: data)
        XCTAssertEqual(decoded, synced)
        // 只有 config 的老文件也能读。
        let minimal = try CloudFile.decoder.decode(SyncedConfig.self, from: Data(#"{"config":{"profiles":[]}}"#.utf8))
        XCTAssertEqual(minimal.device, "未知设备")
        XCTAssertEqual(minimal.updatedAt, .distantPast)

        let shared = Profile(name: "共有", color: "#111111", host: "1.1.1.1", port: 1)
        var local = AppConfig()
        local.profiles = [shared, Profile(name: "本机独有", color: "#222222", host: "2.2.2.2", port: 2), Profile(name: "同名同地址", color: "#333333", host: "3.3.3.3", port: 3)]
        local.offMode = .restore
        var cloud = AppConfig()
        cloud.profiles = [Profile(name: "云端独有", color: "#444444", host: "4.4.4.4", port: 4), shared, Profile(name: "同名同地址", color: "#555555", host: "3.3.3.3", port: 3)]
        cloud.offMode = .direct
        let merged = local.merging(cloud: cloud)
        XCTAssertEqual(merged.profiles.map(\.name), ["云端独有", "共有", "同名同地址", "本机独有"])
        XCTAssertEqual(merged.offMode, .restore)

        let older = SyncedConfig(updatedAt: Date(timeIntervalSince1970: 1), device: "old", config: AppConfig())
        let newer = SyncedConfig(updatedAt: Date(timeIntervalSince1970: 2), device: "new", config: AppConfig())
        XCTAssertEqual(CloudFile.newest([older, newer, older])?.device, "new")
        XCTAssertNil(CloudFile.newest([]))
    }

    func testDriveDetection() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNil(CloudFile.driveURL(home: home))
        let drive = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: drive, withIntermediateDirectories: true)
        XCTAssertEqual(CloudFile.driveURL(home: home)?.lastPathComponent, "com~apple~CloudDocs")
    }

    func testRuleConversion() {
        let conf = """
        [General]
        skip-proxy = 192.168.0.0/16
        [Rule]
        # 注释
        DOMAIN-SUFFIX,google.com,Proxy
        DOMAIN-SUFFIX,google.com,Proxy
        DOMAIN,ad.example.com,Reject
        DOMAIN-KEYWORD,baidu,direct
        IP-CIDR,91.108.56.0/22,PROXY,no-resolve
        IP-CIDR6,2001:b28:f23d::/48,Proxy
        GEOIP,cn,DIRECT
        USER-AGENT,MicroMessenger*,Proxy
        RULE-SET,https://example.com/apple.list,PROXY
        RULE-SET,local-name,DIRECT
        FINAL,direct
        [URL Rewrite]
        ^https?://(www.)?g.cn https://www.google.com 302
        """
        let converted = RuleConverter.convert(conf)
        XCTAssertEqual(converted.rules, [
            "DOMAIN-SUFFIX,google.com,节点",
            "DOMAIN,ad.example.com,REJECT",
            "DOMAIN-KEYWORD,baidu,DIRECT",
            "IP-CIDR,91.108.56.0/22,节点,no-resolve",
            "IP-CIDR6,2001:b28:f23d::/48,节点",
            "GEOIP,CN,DIRECT",
            "MATCH,DIRECT",
        ])
        XCTAssertEqual(converted.ruleSets, [RuleSetReference(url: "https://example.com/apple.list", policy: "节点")])
        XCTAssertEqual(converted.skipped, 2)

        // Surge 的 .list 规则集：没有策略字段，用默认策略；内联到 FINAL 之前。
        let list = RuleConverter.convert("DOMAIN-SUFFIX,apple.news\nIP-CIDR,17.0.0.0/8,no-resolve\n", defaultPolicy: "节点")
        XCTAssertEqual(list.rules, ["DOMAIN-SUFFIX,apple.news,节点", "IP-CIDR,17.0.0.0/8,节点,no-resolve"])
        let merged = RuleConverter.merge(converted, ruleSetRules: ["https://example.com/apple.list": list.rules])
        XCTAssertEqual(merged.last, "MATCH,DIRECT")
        XCTAssertEqual(merged.count, converted.rules.count + list.rules.count)
        XCTAssertTrue(merged.contains("DOMAIN-SUFFIX,apple.news,节点"))

        // Clash 的规则文件和 payload 列表。
        let clash = "port: 7890\nrules:\n  - DOMAIN-SUFFIX,x.com,Proxy\n  - 'GEOIP,CN,DIRECT'\n  - MATCH,Proxy\nproxies: []\n"
        XCTAssertEqual(RuleConverter.convert(clash).rules, ["DOMAIN-SUFFIX,x.com,节点", "GEOIP,CN,DIRECT", "MATCH,节点"])
        let payload = "payload:\n  - '+.example.com'\n  - 'sub.example.org'\n  - '10.0.0.0/8'\n"
        XCTAssertEqual(RuleConverter.convert(payload, defaultPolicy: "DIRECT").rules, ["DOMAIN-SUFFIX,example.com,DIRECT", "DOMAIN,sub.example.org,DIRECT", "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve"])
        XCTAssertEqual(RuleConverter.policy("Reject"), "REJECT")
        XCTAssertEqual(RuleConverter.policy("自定义组"), "节点")
    }

    func testCoreConfig() throws {
        var engine = EngineConfig()
        engine.subscriptions = [Subscription(name: "机场", url: "https://air.example.com/sub?token=\"x\"")]
        engine.mixedPort = 7891
        engine.apiPort = 9098
        let input = CoreConfigBuilder.Input(engine: engine, secret: "s3cret", directory: URL(fileURLWithPath: "/tmp/core"), testURL: "https://cp.cloudflare.com/generate_204", rules: RuleConverter.chinaDirectRules)
        let yaml = CoreConfigBuilder.yaml(input)
        XCTAssertTrue(yaml.contains("mixed-port: 7891\n"))
        XCTAssertTrue(yaml.contains("external-controller: \"127.0.0.1:9098\"\n"))
        XCTAssertTrue(yaml.contains("secret: \"s3cret\"\n"))
        XCTAssertTrue(yaml.contains("    url: \"https://air.example.com/sub?token=\\\"x\\\"\"\n"))
        XCTAssertTrue(yaml.contains("    path: \"/tmp/core/providers/\(engine.subscriptions[0].providerName).yaml\"\n"))
        XCTAssertTrue(yaml.contains("    use: [\(engine.subscriptions[0].providerName)]\n"))
        XCTAssertTrue(yaml.contains("  - \"GEOIP,CN,DIRECT\"\n  - \"MATCH,节点\"\n"))
        XCTAssertTrue(yaml.hasSuffix("\n"))
        // 没有 MATCH 时补上。
        var global = input
        global.rules = ["DOMAIN-SUFFIX,x.com,DIRECT"]
        XCTAssertTrue(CoreConfigBuilder.yaml(global).hasSuffix("  - \"MATCH,节点\"\n"))
        XCTAssertEqual(CoreConfigBuilder.quote("a\"b\\c\n"), "\"a\\\"b\\\\c\\n\"")
        XCTAssertEqual(CoreConfigBuilder.makeSecret().count, 32)
    }

    func testEngineModels() throws {
        XCTAssertNil(Subscription.validate(url: "https://air.example.com/sub"))
        XCTAssertNil(Subscription.validate(url: "file:///Users/me/nodes.txt"))
        XCTAssertEqual(Subscription(name: "f", url: "file:///Users/me/nodes.txt").filePath, "/Users/me/nodes.txt")
        XCTAssertNil(Subscription(name: "h", url: "https://x/y").filePath)
        XCTAssertNotNil(Subscription.validate(url: "ss://abc"))
        XCTAssertNotNil(Subscription.validate(url: ""))
        var fileEngine = EngineConfig()
        fileEngine.subscriptions = [Subscription(name: "f", url: "file:///tmp/nodes.txt")]
        let fileYAML = CoreConfigBuilder.yaml(CoreConfigBuilder.Input(engine: fileEngine, secret: "s", directory: URL(fileURLWithPath: "/tmp/core"), testURL: "https://t", rules: []))
        XCTAssertTrue(fileYAML.contains("    type: file\n    path: \"/tmp/core/providers/\(fileEngine.subscriptions[0].providerName).yaml\"\n"))
        XCTAssertFalse(fileYAML.contains("interval: 86400"))
        var engine = EngineConfig()
        XCTAssertFalse(engine.wantsCore)
        engine.subscriptions = [Subscription(name: "a", url: "https://x/y")]
        XCTAssertTrue(engine.wantsCore)
        engine.enabled = false
        XCTAssertFalse(engine.wantsCore)
        engine.ruleSource = .url(RulePresets.all[1].url)
        let data = try JSONEncoder().encode(engine)
        let decoded = try JSONDecoder().decode(EngineConfig.self, from: data)
        XCTAssertEqual(decoded, engine)
        XCTAssertEqual(decoded.ruleSource.title, "黑名单 + 去广告")
        XCTAssertEqual(try JSONDecoder().decode(EngineConfig.self, from: Data("{}".utf8)).mixedPort, 7890)
        XCTAssertEqual(try JSONDecoder().decode(RuleSource.self, from: Data(#"{"kind":"url","url":"https://a/b"}"#.utf8)), .url("https://a/b"))
        XCTAssertEqual(try JSONDecoder().decode(RuleSource.self, from: Data(#"{"kind":"nope"}"#.utf8)), .chinaDirect)

        // 内置代理的配置：HTTP 和 SOCKS 都指到内核端口。
        let profile = Profile.engineProfile(port: 7890)
        XCTAssertTrue(profile.engine)
        XCTAssertEqual(profile.summary, "内置代理 · 127.0.0.1:7890")
        let desired = DesiredProxy(profile: profile)
        XCTAssertEqual(desired.http, DesiredProxy.Endpoint(host: "127.0.0.1", port: 7890))
        XCTAssertEqual(desired.socks, DesiredProxy.Endpoint(host: "127.0.0.1", port: 7890))
        let roundTrip = try JSONDecoder().decode(Profile.self, from: try JSONEncoder().encode(profile))
        XCTAssertTrue(roundTrip.engine)
    }

    func testSpeedFormatter() {
        let figure = "\u{2007}"
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 0), figure + figure + figure + "0B")
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 999), figure + "999B")
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 1024), figure + "1.0K")
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 9_900), figure + "9.7K")
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 512_000), figure + "500K")
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 1_258_291), figure + "1.2M")
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 125_829_120), figure + "120M")
        XCTAssertEqual(SpeedFormatter.compact(bytesPerSecond: 2_147_483_648), figure + "2.0G")
        XCTAssertTrue(SpeedFormatter.compact(bytesPerSecond: -5).hasSuffix("0B"))
        XCTAssertTrue(SpeedFormatter.full(bytesPerSecond: 2048).hasSuffix("/s"))
        // 32 位计数回绕后的差值也对。
        let old = ["en0": InterfaceCounters.Sample(received: UInt32.max - 10, sent: 100)]
        let new = ["en0": InterfaceCounters.Sample(received: 20, sent: 150), "en1": InterfaceCounters.Sample(received: 5, sent: 5)]
        let delta = InterfaceCounters.delta(from: old, to: new)
        XCTAssertEqual(delta.received, 31)
        XCTAssertEqual(delta.sent, 50)
        XCTAssertNotNil(InterfaceCounters.read())
    }

    /// 菜单栏图标带网速时，两行小字的墨迹中线要和开关的中线重合，两个箭头要左右对齐（按像素检查真实渲染的结果）。
    func testStatusIconSpeedAlignment() throws {
        // 8.0K 对 45K：位数、小数点都不一样，以前右对齐整行会让箭头错位。
        let pairs: [(Int, Int)] = [(8_192, 46_080), (14_000_000, 15_000_000), (999, 1_258_291)]
        for (up, down) in pairs {
            let upload = SpeedFormatter.compact(bytesPerSecond: up)
            let download = SpeedFormatter.compact(bytesPerSecond: down)
            for state in [StatusIconState.off, .on(NSColor.systemGreen), .external] {
                for side in SpeedSide.allCases {
                    let image = StatusIcon.image(for: state, upload: upload, download: download, textColor: NSColor.black.cgColor, speedSide: side)
                    XCTAssertEqual(image.size.height, StatusIcon.speedHeight)
                    XCTAssertEqual(image.isTemplate, state == .off)
                    let scale: CGFloat = 2
                    let bitmap = try XCTUnwrap(StatusIcon.bitmap(of: image, scale: scale))
                    let iconWidth = Int(StatusIcon.iconSize.width * scale)
                    let gapHalf = Int(StatusIcon.speedGap * scale) / 2
                    // 网速在左边时开关在最右边，反之开关在最左边。
                    let iconRange = side == .left ? (bitmap.pixelsWide - iconWidth)..<bitmap.pixelsWide : 0..<iconWidth
                    let textRange = side == .left ? 0..<(bitmap.pixelsWide - iconWidth - gapHalf) : (iconWidth + gapHalf)..<bitmap.pixelsWide
                    let icon = try XCTUnwrap(inkRows(bitmap, xRange: iconRange))
                    let text = try XCTUnwrap(inkRows(bitmap, xRange: textRange))
                    let iconCenter = Double(icon.min + icon.max) / 2
                    let textCenter = Double(text.min + text.max) / 2
                    XCTAssertLessThanOrEqual(abs(iconCenter - textCenter), 1.5, "\(upload)/\(download) \(state) \(side)：开关中线 \(iconCenter)，网速中线 \(textCenter)（像素，2x）")
                    // 两行都画出来了，而且没有贴到边上被裁掉。
                    XCTAssertGreaterThan(text.max - text.min, Int(StatusIcon.speedLinePitch * scale))
                    XCTAssertGreaterThan(text.min, 0)
                    XCTAssertLessThan(text.max, bitmap.pixelsHigh - 1)
                    // 箭头单独占一列：上下两行网速最左边的墨迹（就是箭头）在同一列。
                    let half = bitmap.pixelsHigh / 2
                    let top = try XCTUnwrap(inkColumns(bitmap, xRange: textRange, yRange: 0..<half))
                    let bottom = try XCTUnwrap(inkColumns(bitmap, xRange: textRange, yRange: half..<bitmap.pixelsHigh))
                    XCTAssertLessThanOrEqual(abs(top.min - bottom.min), 1, "\(upload)/\(download) \(side)：上行箭头 x=\(top.min)，下行箭头 x=\(bottom.min)")
                    // 数字紧跟箭头：每行里相邻墨迹之间最大的空隙（箭头和数字之间）不超过几个像素，不会空出一截补位的空格。
                    XCTAssertLessThanOrEqual(largestGap(bitmap, xRange: textRange, yRange: 0..<half), 8, "\(upload) \(side)：箭头和数字之间空得太大")
                    XCTAssertLessThanOrEqual(largestGap(bitmap, xRange: textRange, yRange: half..<bitmap.pixelsHigh), 8, "\(download) \(side)：箭头和数字之间空得太大")
                    // 开关和网速之间留着间距，没有画到一起。
                    let iconColumns = try XCTUnwrap(inkColumns(bitmap, xRange: iconRange, yRange: 0..<bitmap.pixelsHigh))
                    if side == .left {
                        XCTAssertGreaterThan(iconColumns.min, top.max)
                    } else {
                        XCTAssertLessThan(iconColumns.max, top.min)
                    }
                }
            }
        }
        // 数值变了图标宽度不变（图标不会跟着跳）。
        XCTAssertEqual(StatusIcon.image(for: .off, upload: SpeedFormatter.compact(bytesPerSecond: 0), download: SpeedFormatter.compact(bytesPerSecond: 0), textColor: NSColor.black.cgColor).size.width,
                       StatusIcon.image(for: .off, upload: SpeedFormatter.compact(bytesPerSecond: 1_000_000_000), download: SpeedFormatter.compact(bytesPerSecond: 999_000), textColor: NSColor.black.cgColor).size.width)
        // 没有网速时还是原来的小开关。
        XCTAssertEqual(StatusIcon.image(for: .off).size, StatusIcon.iconSize)
    }

    /// 某个区域里相邻两列墨迹之间最大的空白宽度（像素）。
    private func largestGap(_ bitmap: NSBitmapImageRep, xRange: Range<Int>, yRange: Range<Int>) -> Int {
        var previous: Int?
        var largest = 0
        for x in xRange where x >= 0 && x < bitmap.pixelsWide {
            var inked = false
            for y in yRange where y >= 0 && y < bitmap.pixelsHigh {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.25 {
                    inked = true
                    break
                }
            }
            guard inked else { continue }
            if let previous {
                largest = max(largest, x - previous - 1)
            }
            previous = x
        }
        return largest
    }

    /// 位图里某个区域内有墨迹（不透明）的最左和最右一列。
    private func inkColumns(_ bitmap: NSBitmapImageRep, xRange: Range<Int>, yRange: Range<Int>) -> (min: Int, max: Int)? {
        var minX = Int.max
        var maxX = Int.min
        for y in yRange where y >= 0 && y < bitmap.pixelsHigh {
            for x in xRange where x >= 0 && x < bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.25 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
        }
        return minX == Int.max ? nil : (minX, maxX)
    }

    /// 位图里某个横向范围内有墨迹（不透明）的最上和最下一行。
    private func inkRows(_ bitmap: NSBitmapImageRep, xRange: Range<Int>) -> (min: Int, max: Int)? {
        var minY = Int.max
        var maxY = Int.min
        for y in 0..<bitmap.pixelsHigh {
            for x in xRange where x >= 0 && x < bitmap.pixelsWide {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0.25 {
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        return minY == Int.max ? nil : (minY, maxY)
    }

    func testReleaseNotesCleaning() {
        let notes = "## 0.2.0\r\n\r\n- 一键更新\r\n  * 子项\r\n普通一行"
        XCTAssertEqual(ReleaseNotes.cleaned(notes), "0.2.0\n\n• 一键更新\n• 子项\n普通一行")
    }

    func testProxyAddressParse() {
        XCTAssertEqual(ProxyAddress.parse("127.0.0.1:7890"), ProxyAddress(kind: nil, host: "127.0.0.1", port: 7890))
        XCTAssertEqual(ProxyAddress.parse(" http://127.0.0.1:7890/ "), ProxyAddress(kind: .http, host: "127.0.0.1", port: 7890))
        XCTAssertEqual(ProxyAddress.parse("socks5://user:pass@proxy.corp:1080"), ProxyAddress(kind: .socks5, host: "proxy.corp", port: 1080))
        XCTAssertEqual(ProxyAddress.parse("[::1]:1080"), ProxyAddress(kind: nil, host: "::1", port: 1080))
        XCTAssertEqual(ProxyAddress.parse("https://proxy.corp"), ProxyAddress(kind: .http, host: "proxy.corp", port: nil))
        XCTAssertEqual(ProxyAddress.parse("proxy.corp"), ProxyAddress(kind: nil, host: "proxy.corp", port: nil))
        XCTAssertFalse(ProxyAddress.parse("proxy.corp")!.splitsFields)
        XCTAssertTrue(ProxyAddress.parse("proxy.corp:3128")!.splitsFields)
        XCTAssertNil(ProxyAddress.parse(""))
        XCTAssertNil(ProxyAddress.parse("ftp://x:1"))
        XCTAssertNil(ProxyAddress.parse("host:abc"))
        XCTAssertNil(ProxyAddress.parse("host:70000"))
    }

    func testProfileValidation() {
        var profile = Profile(name: "x", color: "#000", kind: .http, host: "127.0.0.1", port: 7890)
        XCTAssertNil(profile.validate())
        profile.port = 70000
        XCTAssertNotNil(profile.validate())
        profile.port = 80
        profile.host = "a b"
        XCTAssertNotNil(profile.validate())
        var pac = Profile(name: "p", color: "#000", kind: .pac, pacURL: "ftp://x")
        XCTAssertNotNil(pac.validate())
        pac.pacURL = "http://127.0.0.1/proxy.pac"
        XCTAssertNil(pac.validate())
        var empty = Profile(name: "e", color: "#000")
        empty.targets = []
        XCTAssertNotNil(empty.validate())
    }

    @MainActor
    func testCloudSyncPullAndPush() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        var remoteConfig = AppConfig()
        remoteConfig.profiles = [Profile(name: "云端", color: "#111111", host: "10.0.0.1", port: 8080)]
        try CloudFile.write(SyncedConfig(updatedAt: Date(), device: "另一台 Mac", config: remoteConfig), to: file)

        let sync = CloudSync(folder: folder)
        var current = AppConfig()
        var applied: AppConfig?
        var enabledFlags: [Bool] = []
        sync.currentConfig = { current }
        sync.applyRemote = { applied = $0; current = $0 }
        sync.onEnabledChanged = { enabledFlags.append($0) }

        // 启动时按记录的开关恢复：读到云端的配置就应用。
        sync.start(enabled: true)
        await sync.syncNow()
        XCTAssertEqual(applied, remoteConfig)
        guard case .synced(_, let device) = sync.status else { return XCTFail("状态不对：\(sync.status)") }
        XCTAssertEqual(device, "另一台 Mac")

        // 本机改动稍后写到云端。
        current.profiles.append(Profile(name: "本机", color: "#222222", host: "10.0.0.2", port: 9090))
        sync.localChanged(current)
        try await Task.sleep(for: .seconds(2))
        let written = try XCTUnwrap(try CloudFile.read(at: file))
        XCTAssertEqual(written.config, current)
        XCTAssertEqual(written.device, CloudFile.deviceName)

        // 关掉后不再写。
        sync.disable()
        XCTAssertEqual(enabledFlags, [false])
        XCTAssertEqual(sync.status, .off)
        current.profiles.removeAll()
        sync.localChanged(current)
        try await Task.sleep(for: .seconds(1.5))
        XCTAssertEqual(try CloudFile.read(at: file)?.config.profiles.count, 2)
    }

    @MainActor
    func testCloudSyncEnableAsksWhenCloudDiffers() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("config.json")
        var remoteConfig = AppConfig()
        remoteConfig.profiles = [Profile(name: "云端", color: "#111111", host: "10.0.0.1", port: 8080)]
        try CloudFile.write(SyncedConfig(updatedAt: Date(), device: "另一台 Mac", config: remoteConfig), to: file)

        let sync = CloudSync(folder: folder)
        var current = AppConfig()
        current.profiles = [Profile(name: "本机", color: "#222222", host: "10.0.0.2", port: 9090)]
        sync.currentConfig = { current }
        sync.applyRemote = { current = $0 }
        await sync.enable()
        XCTAssertFalse(sync.enabled)
        XCTAssertEqual(sync.pending?.device, "另一台 Mac")

        sync.resolve(.merge)
        XCTAssertNil(sync.pending)
        try await Task.sleep(for: .seconds(1))
        XCTAssertTrue(sync.enabled)
        XCTAssertEqual(current.profiles.map(\.name), ["云端", "本机"])
        let written = try XCTUnwrap(try CloudFile.read(at: file))
        XCTAssertEqual(written.config.profiles.map(\.name), ["云端", "本机"])

        // 云端没有文件时直接开启并把本机的写上去。
        let empty = CloudSync(folder: folder.appendingPathComponent("empty", isDirectory: true))
        empty.currentConfig = { current }
        await empty.enable()
        XCTAssertTrue(empty.enabled)
        XCTAssertEqual(try CloudFile.read(at: folder.appendingPathComponent("empty/config.json"))?.config, current)
    }

    func testConfigRoundTrip() throws {
        var config = AppConfig()
        config.profiles = [Profile(name: "a", color: "#111111", kind: .socks5, host: "h", port: 1)]
        config.toggleHotkey = nil
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        XCTAssertEqual(decoded, config)
        XCTAssertNil(decoded.toggleHotkey)
        XCTAssertTrue(decoded.autoCheckUpdates)
        // 缺少 toggleHotkey 键时用默认快捷键。
        let minimal = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(minimal.toggleHotkey, HotkeyBinding.defaultToggle)
        XCTAssertEqual(minimal.speedSide, .left)
        config.speedSide = .right
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: try JSONEncoder().encode(config)).speedSide, .right)
    }
}

/// 共享期间防睡眠：决定逻辑，以及真的向系统要一条断言再释放。
final class SleepGuardTests: XCTestCase {
    func testShouldHold() {
        XCTAssertTrue(PowerAssertion.shouldHold(wanted: true, onBattery: false, allowOnBattery: false))
        XCTAssertFalse(PowerAssertion.shouldHold(wanted: true, onBattery: true, allowOnBattery: false))
        XCTAssertTrue(PowerAssertion.shouldHold(wanted: true, onBattery: true, allowOnBattery: true))
        XCTAssertFalse(PowerAssertion.shouldHold(wanted: false, onBattery: false, allowOnBattery: true))
    }

    @MainActor
    func testAssertionIsCreatedAndReleased() {
        let guardian = SleepGuard()
        guardian.update(wanted: true, allowOnBattery: true)
        XCTAssertEqual(guardian.status, .holding)
        XCTAssertTrue(PowerAssertion.currentNames().contains(PowerAssertion.name))
        guardian.update(wanted: false, allowOnBattery: true)
        XCTAssertEqual(guardian.status, .off)
        XCTAssertFalse(PowerAssertion.currentNames().contains(PowerAssertion.name))
        // 共享设置里的默认值：保持，但只在接电源时。
        let share = ShareConfig()
        XCTAssertTrue(share.keepAwake)
        XCTAssertFalse(share.keepAwakeOnBattery)
    }
}

/// 网址诊断：网址的整理、内核日志行的解析、结论引擎的每个场景。
final class DiagnoseTests: XCTestCase {
    func testTargetNormalize() {
        XCTAssertEqual(DiagnoseTarget.normalize("youtube.com")?.absoluteString, "https://youtube.com")
        XCTAssertEqual(DiagnoseTarget.normalize(" http://a.b/c?d=1 ")?.absoluteString, "http://a.b/c?d=1")
        XCTAssertNil(DiagnoseTarget.normalize("ftp://x"))
        XCTAssertNil(DiagnoseTarget.normalize(""))
        XCTAssertNil(DiagnoseTarget.normalize("not a url"))
        let https = DiagnoseTarget(url: DiagnoseTarget.normalize("youtube.com")!, perspective: .mac)
        XCTAssertEqual(https.host, "youtube.com")
        XCTAssertEqual(https.port, 443)
        let http = DiagnoseTarget(url: DiagnoseTarget.normalize("http://example.com:8080/x")!, perspective: .device)
        XCTAssertEqual(http.port, 8080)
        XCTAssertEqual(DiagnoseTarget(url: DiagnoseTarget.normalize("http://example.com")!, perspective: .mac).port, 80)
    }

    func testRouteTraceParse() throws {
        let matched = try XCTUnwrap(RouteTrace.parse("[TCP] 192.168.1.20:52011 --> www.youtube.com:443 match DomainSuffix(youtube.com) using 节点[香港 01]"))
        XCTAssertEqual(matched.host, "www.youtube.com")
        XCTAssertEqual(matched.port, 443)
        XCTAssertEqual(matched.rule, "DomainSuffix(youtube.com)")
        XCTAssertEqual(matched.chain, "节点[香港 01]")
        XCTAssertEqual(matched.outbound, "香港 01")
        XCTAssertFalse(matched.isDirect)
        XCTAssertNil(matched.error)
        let direct = try XCTUnwrap(RouteTrace.parse("[TCP] 127.0.0.1:60000 --> cp.cloudflare.com:443 match Match using DIRECT"))
        XCTAssertEqual(direct.rule, "Match")
        XCTAssertTrue(direct.isDirect)
        let mode = try XCTUnwrap(RouteTrace.parse("[TCP] 127.0.0.1:60000(Safari) --> example.com:80 using GLOBAL"))
        XCTAssertEqual(mode.rule, "")
        XCTAssertEqual(mode.chain, "GLOBAL")
        XCTAssertEqual(mode.port, 80)
        let none = try XCTUnwrap(RouteTrace.parse("[TCP] 127.0.0.1:1 --> example.com:443 doesn't match any rule using DIRECT"))
        XCTAssertEqual(none.rule, "没有命中任何规则")
        XCTAssertTrue(none.isDirect)
        let failed = try XCTUnwrap(RouteTrace.parse("[TCP] dial 节点 (match Match/) 192.168.1.20:52012 --> www.youtube.com:443 error: dial tcp 1.2.3.4:443: i/o timeout"))
        XCTAssertEqual(failed.chain, "节点")
        XCTAssertEqual(failed.rule, "Match/")
        XCTAssertEqual(failed.host, "www.youtube.com")
        XCTAssertEqual(failed.error, "dial tcp 1.2.3.4:443: i/o timeout")
        let failedNoRule = try XCTUnwrap(RouteTrace.parse("[TCP] dial DIRECT 127.0.0.1:2 --> [::1]:443 error: connection refused"))
        XCTAssertEqual(failedNoRule.chain, "DIRECT")
        XCTAssertEqual(failedNoRule.host, "::1")
        XCTAssertEqual(failedNoRule.rule, "")
        XCTAssertNil(RouteTrace.parse("[UDP] 127.0.0.1:1 --> 1.1.1.1:53 match Match using DIRECT"))
        XCTAssertNil(RouteTrace.parse("time=... level=info msg=something else"))
    }

    func testVerdicts() {
        var facts = DiagnoseFacts(perspective: .mac, host: "youtube.com")
        // 本机没开代理：直连通就是正常，不通就让开代理。
        facts.direct = ProbeResult(ok: true, status: 200, latencyMs: 120, failure: nil)
        XCTAssertEqual(Verdict.make(facts).headline, "直连正常，本机没开代理")
        facts.direct = ProbeResult(ok: false, status: nil, latencyMs: nil, failure: .timeout)
        facts.engineHasNodes = true
        XCTAssertEqual(Verdict.make(facts).actions.first, .turnOnEngine)
        facts.engineHasNodes = false
        XCTAssertEqual(Verdict.make(facts).actions.first, .openNodes)
        // 经节点访问成功：链路正常。
        facts.engineHasNodes = true
        facts.macRoute = .engine
        facts.proxiedVia = "节点代理"
        facts.proxied = ProbeResult(ok: true, status: 200, latencyMs: 310, failure: nil)
        facts.trace = RouteTrace(host: "youtube.com", port: 443, rule: "Match", chain: "节点[香港 01]", error: nil)
        XCTAssertEqual(Verdict.make(facts).headline, "链路正常")
        // 规则分到直连但直连不通：让它走节点。
        facts.proxied = ProbeResult(ok: false, status: nil, latencyMs: nil, failure: .timeout)
        facts.trace = RouteTrace(host: "youtube.com", port: 443, rule: "GeoIP(CN)", chain: "DIRECT", error: "dial tcp 1.2.3.4:443: i/o timeout")
        let pinned = Verdict.make(facts)
        XCTAssertEqual(pinned.headline, "规则把它分到了直连，但直连不通")
        XCTAssertEqual(pinned.actions.first, .pinToProxy("youtube.com"))
        // 节点连不上：自动选择。
        facts.trace = RouteTrace(host: "youtube.com", port: 443, rule: "Match", chain: "节点[香港 01]", error: "i/o timeout")
        facts.nodeDelay = 0
        XCTAssertEqual(Verdict.make(facts).actions.first, .autoSelect)
        // 节点能通但这个网站不通：换节点。
        facts.nodeDelay = 86
        XCTAssertEqual(Verdict.make(facts).headline, "节点能通，但这个网站经它打不开")
        // 转发给上游代理失败。
        facts.trace = RouteTrace(host: "youtube.com", port: 443, rule: "Match", chain: "上游代理", error: "connection refused")
        XCTAssertEqual(Verdict.make(facts).headline, "转发给上游代理失败")
        // 设备视角：入口没监听；链路通但设备没有连接记录。
        var device = DiagnoseFacts(perspective: .device, host: "youtube.com")
        XCTAssertEqual(Verdict.make(device).actions, [.openShare])
        device.shareListening = true
        device.proxiedVia = "共享入口"
        device.proxied = ProbeResult(ok: true, status: 200, latencyMs: 300, failure: nil)
        device.deviceRecentConnections = 0
        XCTAssertTrue(Verdict.make(device).headline.contains("设备最近没有对它的连接"))
        device.deviceRecentConnections = 3
        XCTAssertEqual(Verdict.make(device).headline, "链路正常")
        XCTAssertEqual(Verdict.Action.pinToProxy("a.b").title, "让 a.b 走节点")
    }

    func testDiagnoseURLCommand() {
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://diagnose?url=https://youtube.com&from=device")!), .diagnose(url: "https://youtube.com", device: true))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://diagnose")!), .diagnose(url: nil, device: false))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://settings?page=diagnose")!), .settings(.diagnose))
        XCTAssertEqual(ProbeResult(ok: true, status: 204, latencyMs: 88, failure: nil).summary, "HTTP 204，88 ms")
        XCTAssertEqual(ProbeResult(ok: false, status: nil, latencyMs: nil, failure: .reset).summary, "连接被中断（常见于被屏蔽）")
        XCTAssertFalse(DNSProbe.resolve("localhost").isEmpty)
    }
}

/// 自定义规则：输入的整理、校验、生成的规则行和在配置里的位置。
final class CustomRuleTests: XCTestCase {
    func testNormalizeAndLines() throws {
        XCTAssertEqual(CustomRule.normalize("https://www.YouTube.com/watch?v=1"), "www.youtube.com")
        XCTAssertEqual(CustomRule.normalize("*.youtube.com"), "youtube.com")
        XCTAssertEqual(CustomRule.normalize(" .Example.org. "), "example.org")
        XCTAssertEqual(CustomRule.normalize("youtube.com:443"), "youtube.com")
        XCTAssertEqual(CustomRule.normalize("10.0.0.0/8"), "10.0.0.0/8")
        XCTAssertEqual(CustomRule.normalize("fe80::1"), "fe80::1")
        XCTAssertEqual(CustomRule(pattern: "YouTube.com", policy: .proxy).line, "DOMAIN-SUFFIX,youtube.com,节点")
        XCTAssertEqual(CustomRule(pattern: "8.8.8.8", policy: .direct).line, "IP-CIDR,8.8.8.8/32,DIRECT,no-resolve")
        XCTAssertEqual(CustomRule(pattern: "10.0.0.0/8", policy: .reject).line, "IP-CIDR,10.0.0.0/8,REJECT,no-resolve")
        XCTAssertEqual(CustomRule(pattern: "fe80::/10", policy: .direct).line, "IP-CIDR6,fe80::/10,DIRECT,no-resolve")
        XCTAssertNil(CustomRule(pattern: "not a domain", policy: .proxy).line)
        XCTAssertNil(CustomRule.validate("youtube.com"))
        XCTAssertNil(CustomRule.validate("8.8.8.8"))
        XCTAssertNotNil(CustomRule.validate(""))
        XCTAssertNotNil(CustomRule.validate("not a domain"))
        // 配置里的位置：局域网直连之后、预设规则之前；停用的不出现；全局模式下也在。
        var engine = EngineConfig()
        engine.customRules = [CustomRule(pattern: "youtube.com", policy: .proxy), CustomRule(pattern: "bank.example", policy: .direct)]
        engine.customRules[1].enabled = false
        let input = CoreConfigBuilder.Input(engine: engine, secret: "s", directory: URL(fileURLWithPath: "/tmp/core"), testURL: "https://t", rules: RuleConverter.chinaDirectRules)
        let yaml = CoreConfigBuilder.yaml(input)
        XCTAssertTrue(yaml.contains("  - \"IP-CIDR6,fe80::/10,DIRECT,no-resolve\"\n  - \"DOMAIN-SUFFIX,youtube.com,节点\"\n  - \"DOMAIN-SUFFIX,cn,DIRECT\"\n"))
        XCTAssertFalse(yaml.contains("bank.example"))
        var global = input
        global.rules = RuleConverter.globalRules
        XCTAssertTrue(CoreConfigBuilder.yaml(global).contains("  - \"DOMAIN-SUFFIX,youtube.com,节点\"\n  - \"MATCH,节点\"\n"))
        // 共享给设备时同样带着自定义规则。
        var shared = input
        shared.share = ShareInputs(port: 7892, allowedPrefixes: ["127.0.0.0/8"], upstream: .engine)
        XCTAssertTrue(CoreConfigBuilder.yaml(shared).contains("    - \"DOMAIN-SUFFIX,youtube.com,节点\"\n"))
        // 存取。
        let decoded = try JSONDecoder().decode(EngineConfig.self, from: try JSONEncoder().encode(engine))
        XCTAssertEqual(decoded, engine)
        XCTAssertTrue(try JSONDecoder().decode(EngineConfig.self, from: Data("{}".utf8)).customRules.isEmpty)
    }
}

/// 局域网共享：设置的解析、上游的判断、内核配置里的入口，以及连接列表的归并。
final class ShareTests: XCTestCase {
    func testShareConfig() throws {
        let parsed = ShareConfig.parseClients("192.168.1.20, 192.168.2.0/24; fe80::1\n10.0.0.256 bad/8 10.0.0.0/33 192.168.1.20")
        XCTAssertEqual(parsed.prefixes, ["192.168.1.20/32", "192.168.2.0/24", "fe80::1/128"])
        XCTAssertEqual(parsed.invalid, ["10.0.0.256", "bad/8", "10.0.0.0/33"])
        var share = ShareConfig()
        XCTAssertFalse(share.enabled)
        XCTAssertEqual(share.port, 7892)
        XCTAssertEqual(share.allowedPrefixes, ShareConfig.loopbackPrefixes + ShareConfig.lanPrefixes)
        XCTAssertNil(share.validate())
        // 填了设备就只允许它们，回环仍然在（内核自己的端口也受这份名单限制）。
        share.allowedClients = "192.168.1.20"
        XCTAssertEqual(share.allowedPrefixes, ["127.0.0.0/8", "::1/128", "192.168.1.20/32"])
        share.port = 80
        XCTAssertNotNil(share.validate())
        share.port = 7892
        share.allowedClients = "abc"
        XCTAssertNotNil(share.validate())
        // 本机状态里带着共享设置；旧文件没有这一项时用默认值。
        let old = try JSONDecoder().decode(PersistedState.self, from: Data(#"{"syncEnabled":true}"#.utf8))
        XCTAssertEqual(old.share, ShareConfig())
        XCTAssertTrue(old.syncEnabled)
        var persisted = PersistedState()
        persisted.share.enabled = true
        persisted.share.port = 8899
        persisted.share.allowedClients = "192.168.1.20"
        let decoded = try JSONDecoder().decode(PersistedState.self, from: try JSONEncoder().encode(persisted))
        XCTAssertEqual(decoded.share, persisted.share)
    }

    func testShareUpstreamFollowsTheMac() {
        let http = Profile(name: "公司", color: "#000", kind: .http, host: "proxy.corp", port: 8080)
        let socks = Profile(name: "隧道", color: "#000", kind: .socks5, host: "127.0.0.1", port: 1080)
        let pac = Profile(name: "PAC", color: "#000", kind: .pac, pacURL: "http://x/p.pac")
        let engine = Profile.engineProfile(port: 7890)
        let off = ProxySnapshot()
        XCTAssertEqual(ShareUpstream(status: .off(next: http), snapshot: off), .direct)
        XCTAssertEqual(ShareUpstream(status: .on(engine), snapshot: off), .engine)
        XCTAssertEqual(ShareUpstream(status: .on(http), snapshot: off), .proxy(kind: .http, host: "proxy.corp", port: 8080))
        XCTAssertEqual(ShareUpstream(status: .on(socks), snapshot: off), .proxy(kind: .socks5, host: "127.0.0.1", port: 1080))
        XCTAssertNotNil(ShareUpstream(status: .on(pac), snapshot: off).warning)
        XCTAssertEqual(ShareUpstream(status: .on(pac), snapshot: off).title, "直接连接（PAC 没法转发）")
        // 别的程序设置的系统代理：转发给它；PAC 优先，没法转发。
        var external = ProxySnapshot()
        external.httpsEnabled = true
        external.httpsHost = "10.0.0.8"
        external.httpsPort = 8888
        XCTAssertEqual(ShareUpstream(status: .external(external.summary), snapshot: external), .proxy(kind: .http, host: "10.0.0.8", port: 8888))
        external.pacEnabled = true
        external.pacURL = "http://x/p.pac"
        XCTAssertNotNil(ShareUpstream(status: .external(external.summary), snapshot: external).warning)
        var socksOnly = ProxySnapshot()
        socksOnly.socksEnabled = true
        socksOnly.socksHost = "127.0.0.1"
        socksOnly.socksPort = 1086
        XCTAssertEqual(ShareUpstream(status: .external(socksOnly.summary), snapshot: socksOnly), .proxy(kind: .socks5, host: "127.0.0.1", port: 1086))
        XCTAssertEqual(ShareUpstream.proxy(kind: .socks5, host: "h", port: 1).title, "socks5://h:1")
        XCTAssertEqual(ShareUpstream.direct.summary, "设备经这台 Mac 直连")
    }

    func testCoreConfigWithShare() {
        var engine = EngineConfig()
        var input = CoreConfigBuilder.Input(engine: engine, secret: "s", directory: URL(fileURLWithPath: "/tmp/core"), testURL: "https://t", rules: RuleConverter.chinaDirectRules)
        // 没开共享：没有入口，也没有名单。域名嗅探总是开着（设备按假 IP 来连时也能按域名分流）。
        let plain = CoreConfigBuilder.yaml(input)
        XCTAssertFalse(plain.contains("listeners:"))
        XCTAssertFalse(plain.contains("lan-allowed-ips:"))
        XCTAssertFalse(plain.contains("sub-rules:"))
        XCTAssertTrue(plain.contains("\nsniffer:\n  enable: true\n  parse-pure-ip: true\n  override-destination: true\n"))
        XCTAssertTrue(plain.contains("    TLS:\n      ports: [443, 8443]\n"))
        // 只为共享而运行：本机的代理端口关掉，共享入口在 0.0.0.0，流量直连。
        input.share = ShareInputs(port: 7892, allowedPrefixes: ["127.0.0.0/8", "192.168.0.0/16"], upstream: .direct)
        let direct = CoreConfigBuilder.yaml(input)
        XCTAssertTrue(direct.contains("\nmixed-port: 0\n"))
        XCTAssertTrue(direct.contains("lan-allowed-ips:\n  - \"127.0.0.0/8\"\n  - \"192.168.0.0/16\"\n"))
        XCTAssertTrue(direct.contains("listeners:\n  - name: \"lan-share\"\n    type: mixed\n    listen: \"0.0.0.0\"\n    port: 7892\n    rule: \"lan-share\"\n"))
        XCTAssertTrue(direct.hasSuffix("sub-rules:\n  \"lan-share\":\n    - \"MATCH,DIRECT\"\n"))
        XCTAssertFalse(direct.contains("proxies:\n"))
        XCTAssertFalse(direct.contains("proxy-providers:"))
        // 本机用公司代理：局域网直连，其余转发给它。
        input.share?.upstream = .proxy(kind: .http, host: "proxy.corp", port: 3128)
        let relay = CoreConfigBuilder.yaml(input)
        XCTAssertTrue(relay.contains("proxies:\n  - name: \"上游代理\"\n    type: http\n    server: \"proxy.corp\"\n    port: 3128\n"))
        XCTAssertTrue(relay.contains("  \"lan-share\":\n    - \"DOMAIN-SUFFIX,local,DIRECT\"\n"))
        XCTAssertTrue(relay.contains("    - \"IP-CIDR,192.168.0.0/16,DIRECT,no-resolve\"\n    - \"IP-CIDR,169.254.0.0/16,DIRECT,no-resolve\"\n"))
        XCTAssertTrue(relay.hasSuffix("    - \"MATCH,上游代理\"\n"))
        input.share?.upstream = .proxy(kind: .socks5, host: "127.0.0.1", port: 1080)
        XCTAssertTrue(CoreConfigBuilder.yaml(input).contains("    type: socks5\n    server: \"127.0.0.1\"\n    port: 1080\n"))
        // 本机用内置代理：共享入口按和本机一样的规则分流，本机的代理端口照常开着。
        engine.subscriptions = [Subscription(name: "a", url: "https://x/y")]
        input.engine = engine
        input.share?.upstream = .engine
        let mirrored = CoreConfigBuilder.yaml(input)
        XCTAssertTrue(mirrored.contains("\nmixed-port: 7890\n"))
        XCTAssertTrue(mirrored.contains("proxy-providers:"))
        XCTAssertFalse(mirrored.contains("proxies:\n"))
        XCTAssertTrue(mirrored.contains("  \"lan-share\":\n    - \"DOMAIN-SUFFIX,local,DIRECT\"\n"))
        XCTAssertTrue(mirrored.hasSuffix("    - \"GEOIP,CN,DIRECT\"\n    - \"MATCH,节点\"\n"))
        XCTAssertEqual(CoreConfigBuilder.shareRules(upstream: .unsupported("x"), mainRules: ["MATCH,节点"]), ["MATCH,DIRECT"])
        XCTAssertEqual(CoreConfigBuilder.shareRules(upstream: .engine, mainRules: ["MATCH,节点"]), ["MATCH,节点"])
        // 内置代理停用时不加载订阅，只做共享。
        engine.enabled = false
        input.engine = engine
        let disabled = CoreConfigBuilder.yaml(input)
        XCTAssertFalse(disabled.contains("proxy-providers:"))
        XCTAssertTrue(disabled.contains("\nmixed-port: 0\n"))
    }

    func testShareClientsGrouping() throws {
        let json = """
        {"downloadTotal":1,"uploadTotal":1,"connections":[
          {"id":"1","metadata":{"network":"tcp","type":"Mixed","sourceIP":"192.168.1.20","destinationIP":"1.2.3.4","sourcePort":"1","destinationPort":"443","host":"store.playstation.com","inboundName":"lan-share"},"upload":10,"download":100,"start":"2026-09-27T10:00:01Z","chains":["DIRECT"],"rule":"Match","rulePayload":""},
          {"id":"2","metadata":{"network":"tcp","type":"Mixed","sourceIP":"192.168.1.20","destinationIP":"5.6.7.8","sourcePort":"2","destinationPort":"443","host":"","inboundName":"lan-share"},"upload":1,"download":2,"start":"2026-09-27T10:00:00Z","chains":["DIRECT"],"rule":"Match","rulePayload":""},
          {"id":"3","metadata":{"network":"tcp","type":"Mixed","sourceIP":"192.168.1.30","destinationIP":"","sourcePort":"9","destinationPort":"80","host":"example.org","inboundName":"lan-share"},"upload":0,"download":0,"start":"2026-09-27T10:00:05Z","chains":["上游代理"],"rule":"Match","rulePayload":""},
          {"id":"4","metadata":{"network":"tcp","type":"Mixed","sourceIP":"127.0.0.1","destinationIP":"","sourcePort":"3","destinationPort":"80","host":"example.com","inboundName":""},"upload":5,"download":5,"start":"2026-09-27T10:00:02Z","chains":["节点"],"rule":"Match","rulePayload":""}
        ]}
        """
        struct Envelope: Decodable { var connections: [CoreConnection] }
        let connections = try JSONDecoder().decode(Envelope.self, from: Data(json.utf8)).connections
        XCTAssertEqual(connections.count, 4)
        XCTAssertEqual(connections[1].metadata.displayHost, "5.6.7.8")
        let clients = ShareClient.group(connections, listener: "lan-share")
        XCTAssertEqual(clients.map(\.ip), ["192.168.1.20", "192.168.1.30"])
        XCTAssertEqual(clients[0].connections, 2)
        XCTAssertEqual(clients[0].upload, 11)
        XCTAssertEqual(clients[0].download, 102)
        XCTAssertEqual(clients[0].lastHost, "store.playstation.com")
        XCTAssertEqual(clients[0].lastOutbound, "DIRECT")
        XCTAssertEqual(clients[1].lastHost, "example.org")
        XCTAssertEqual(clients[1].lastOutbound, "上游代理")
        // 内核在没有连接时给的是 null。
        XCTAssertTrue(ShareClient.group([], listener: "lan-share").isEmpty)
        // 「最近的连接」里的一条：目标、出口、规则。
        let recent = ShareConnection(connections[0])
        XCTAssertEqual(recent.target, "store.playstation.com:443")
        XCTAssertEqual(recent.outbound, "DIRECT")
        XCTAssertEqual(recent.rule, "Match")
        XCTAssertEqual(recent.client, "192.168.1.20")
        XCTAssertEqual(ShareConnection(connections[1]).target, "5.6.7.8:443")
    }

    func testShareURLCommands() {
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://share")!), .share(nil))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://share/on")!), .share(true))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://share/off")!), .share(false))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://share?state=on")!), .share(true))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxyswitch://settings?page=share")!), .settings(.share))
    }

    func testLocalNetworkAddresses() {
        // 只看有线、Wi‑Fi 和网桥，不含回环和链路本地地址。
        let addresses = LocalNetwork.ipv4Addresses()
        XCTAssertFalse(addresses.values.contains("127.0.0.1"))
        XCTAssertFalse(addresses.values.contains { $0.hasPrefix("169.254.") })
        XCTAssertTrue(addresses.keys.allSatisfy { $0.hasPrefix("en") || $0.hasPrefix("bridge") })
        XCTAssertEqual(LocalNetwork.addresses().map(\.ip).sorted(), Array(addresses.values).sorted())
    }
}
