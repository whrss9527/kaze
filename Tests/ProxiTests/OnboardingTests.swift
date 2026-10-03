import XCTest
@testable import Proxi

/// 新手引导里填的内容拼成第一套配置。
final class OnboardingTests: XCTestCase {
    private let color = ProfilePalette.colors[0]

    func testHostAndPort() throws {
        var draft = OnboardingDraft()
        draft.address = " proxy.corp.example:3128 "
        let (profile, password) = try draft.build(color: color, existingNames: [])
        XCTAssertEqual(profile.kind, .http)
        XCTAssertEqual(profile.host, "proxy.corp.example")
        XCTAssertEqual(profile.port, 3128)
        XCTAssertEqual(profile.name, "proxy.corp.example")
        XCTAssertEqual(profile.color, color)
        // 默认四个地方都接管。
        XCTAssertEqual(profile.targets, Set(ProxyTarget.allCases))
        XCTAssertEqual(profile.username, "")
        XCTAssertEqual(password, "")
    }

    func testFullAddressWithKindAndLogin() throws {
        var draft = OnboardingDraft()
        draft.address = "socks5://alice:s%40cret@10.0.0.8:1080"
        draft.absorbAddress()
        XCTAssertEqual(draft.kind, .socks5)
        XCTAssertEqual(draft.username, "alice")
        XCTAssertEqual(draft.password, "s@cret")
        draft.name = "  内网网关 "
        draft.targets = [.environment, .git]
        let (profile, password) = try draft.build(color: color, existingNames: [])
        XCTAssertEqual(profile.kind, .socks5)
        XCTAssertEqual(profile.host, "10.0.0.8")
        XCTAssertEqual(profile.port, 1080)
        XCTAssertEqual(profile.name, "内网网关")
        XCTAssertEqual(profile.username, "alice")
        XCTAssertEqual(password, "s@cret")
        XCTAssertEqual(profile.targets, [.environment, .git])
    }

    func testLocalProxyNameAndUniqueNames() throws {
        var draft = OnboardingDraft()
        draft.address = "127.0.0.1:8888"
        XCTAssertEqual(try draft.build(color: color, existingNames: []).profile.name, L("本机代理 %@", 8888))
        draft.name = "Charles"
        XCTAssertEqual(try draft.build(color: color, existingNames: ["Charles", "Charles 2"]).profile.name, "Charles 3")
    }

    func testPasswordWithoutUserIsDropped() throws {
        var draft = OnboardingDraft()
        draft.address = "proxy.corp.example:3128"
        draft.password = "secret"
        XCTAssertEqual(try draft.build(color: color, existingNames: []).password, "")
    }

    func testPACOnlySetsTheSystemProxy() throws {
        var draft = OnboardingDraft()
        draft.kind = .pac
        draft.address = "http://proxy.corp.example/proxy.pac"
        draft.username = "alice"
        draft.password = "secret"
        let (profile, password) = try draft.build(color: color, existingNames: [])
        XCTAssertEqual(profile.pacURL, "http://proxy.corp.example/proxy.pac")
        XCTAssertEqual(profile.targets, [.system])
        XCTAssertEqual(profile.name, "proxy.corp.example")
        XCTAssertEqual(profile.username, "")
        XCTAssertEqual(password, "")
    }

    func testProblems() {
        var draft = OnboardingDraft()
        XCTAssertThrowsError(try draft.build(color: color, existingNames: []))
        draft.address = "proxy.corp.example"
        XCTAssertThrowsError(try draft.build(color: color, existingNames: [])) { error in
            XCTAssertEqual(error.localizedDescription, L("地址里要带端口，比如 %@:3128", "proxy.corp.example"))
        }
        draft.address = "proxy.corp.example:3128"
        draft.targets = []
        XCTAssertThrowsError(try draft.build(color: color, existingNames: []))
        draft.kind = .pac
        draft.address = "proxy.pac"
        XCTAssertThrowsError(try draft.build(color: color, existingNames: []))
    }
}
