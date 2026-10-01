import XCTest
@testable import Proxi

/// 可选扩展「代理引擎」：默认关着、状态的存取、配置列表里那条配置不写进文件、发布信息的解析、代理引擎状态文件的读取。
final class ExtensionTests: XCTestCase {
    func testOffByDefault() throws {
        let state = PersistedState()
        XCTAssertFalse(state.extensionState.enabled)
        XCTAssertNil(state.extensionState.acceptedVersion)
        let decoded = try JSONDecoder().decode(PersistedState.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.extensionState.enabled)
        XCTAssertFalse(decoded.extensionState.migrationChecked)
    }

    func testStateRoundTrip() throws {
        var state = PersistedState()
        state.extensionState.enabled = true
        state.extensionState.acceptedVersion = ExtensionManager.disclaimerVersion
        state.extensionState.acceptedAt = Date(timeIntervalSince1970: 1_000_000)
        state.extensionState.profile = Profile.engineProfile(port: 7891)
        state.extensionState.restoreActive = true
        let data = try JSONEncoder().encode(state)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["extension"], "存在 state.json 的 extension 里")
        let decoded = try JSONDecoder().decode(PersistedState.self, from: data)
        XCTAssertEqual(decoded.extensionState.acceptedVersion, ExtensionManager.disclaimerVersion)
        XCTAssertEqual(decoded.extensionState.profile?.port, 7891)
        XCTAssertTrue(decoded.extensionState.restoreActive)
        // 认不出的值不影响整个状态。
        let broken = try JSONDecoder().decode(PersistedState.self, from: Data(#"{"extension":{"enabled":"yes","acceptedVersion":1}}"#.utf8))
        XCTAssertFalse(broken.extensionState.enabled)
        XCTAssertEqual(broken.extensionState.acceptedVersion, 1)
    }

    func testEngineProfileIsNeverWrittenOrSynced() throws {
        var config = AppConfig()
        config.profiles = [Profile.engineProfile(port: 7890), Profile(name: "公司代理", color: "#000", host: "proxy.corp", port: 3128)]
        XCTAssertTrue(config.profiles[0].engine)
        XCTAssertEqual(config.profiles[0].targets, [.system])
        let data = try JSONEncoder().encode(config)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let profiles = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        XCTAssertEqual(profiles.map { $0["name"] as? String }, ["公司代理"])
        // 以前的版本写进去的也不读。
        let legacy = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"profiles":[{"name":"x","engine":true,"port":7890},{"name":"y"}]}"#.utf8))
        XCTAssertEqual(legacy.profiles.map(\.name), ["y"])
    }

    func testReleaseAssets() throws {
        let json = """
        {"tag_name":"v1.2.3","assets":[
          {"name":"Proxi-macos.zip","size":10,"browser_download_url":"https://example.com/Proxi-macos.zip"},
          {"name":"Proxi-Engine-1.2.3.zip","size":20,"browser_download_url":"https://example.com/Proxi-Engine-1.2.3.zip"},
          {"name":"SHA256SUMS.txt","size":1,"browser_download_url":"https://example.com/SHA256SUMS.txt"}]}
        """
        let assets = try XCTUnwrap(ExtensionManager.assets(in: Data(json.utf8), version: "1.2.3"))
        XCTAssertEqual(assets.0.absoluteString, "https://example.com/Proxi-Engine-1.2.3.zip")
        XCTAssertEqual(assets.1, 20)
        XCTAssertEqual(assets.2.absoluteString, "https://example.com/SHA256SUMS.txt")
        // 版本不对、没有校验文件：不装。
        XCTAssertNil(ExtensionManager.assets(in: Data(json.utf8), version: "1.2.4"))
        XCTAssertNil(ExtensionManager.assets(in: Data(#"{"assets":[{"name":"Proxi-Engine-1.2.3.zip","browser_download_url":"https://e/x"}]}"#.utf8), version: "1.2.3"))
        XCTAssertEqual(ExtensionManager.archiveName(version: "0.13.0"), "Proxi-Engine-0.13.0.zip")
        if ProcessInfo.processInfo.environment[ExtensionManager.feedVariable] == nil {
            XCTAssertEqual(ExtensionManager.feedURL(version: "0.13.0").absoluteString, "https://api.github.com/repos/whrss9527/proxi/releases/tags/v0.13.0")
        }
        XCTAssertEqual(ExtensionManager.appURL.lastPathComponent, "Proxi Engine.app")
        XCTAssertEqual(ExtensionManager.dataDirectory.lastPathComponent, "engine")
    }

    func testEngineStatusFile() throws {
        let json = #"{"version":"1.0","pid":123,"mixedPort":7890,"coreRunning":true,"coreReady":true,"summary":"ok","updatedAt":"2026-10-01T00:00:00Z"}"#
        let status = try XCTUnwrap(ExtensionStatus.decode(Data(json.utf8)))
        XCTAssertEqual(status.mixedPort, 7890)
        XCTAssertTrue(status.coreRunning)
        let fresh = status.updatedAt.addingTimeInterval(5)
        XCTAssertTrue(status.isAlive(now: fresh, processExists: { _ in true }))
        XCTAssertFalse(status.isAlive(now: fresh, processExists: { _ in false }), "进程不在了")
        XCTAssertFalse(status.isAlive(now: status.updatedAt.addingTimeInterval(120), processExists: { _ in true }), "太久没更新")
        XCTAssertNil(ExtensionStatus.decode(Data("{}".utf8)))
    }

    /// 关着的扩展不发任何网络请求：install() 一开始就被拒绝。
    @MainActor
    func testDisabledExtensionRefusesToDownload() async {
        let manager = ExtensionManager()
        manager.readState = { ExtensionState() }
        do {
            try await manager.install()
            XCTFail("没开启时不应该下载")
        } catch {
            XCTAssertEqual(error as? ExtensionError, .notEnabled)
        }
        // 开着、但说明的版本不对（说明改过）：也不下载。
        var stale = ExtensionState()
        stale.enabled = true
        stale.acceptedVersion = ExtensionManager.disclaimerVersion - 1
        manager.readState = { stale }
        XCTAssertTrue(manager.needsDisclaimer)
        do {
            try await manager.install()
            XCTFail("说明没同意时不应该下载")
        } catch {
            XCTAssertEqual(error as? ExtensionError, .notAccepted)
        }
    }
}
