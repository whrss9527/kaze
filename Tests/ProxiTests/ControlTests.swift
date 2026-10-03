import XCTest
@testable import Proxi

final class ControlProtocolTests: XCTestCase {
    func testCatalogAndSchemas() {
        let names = ControlCatalog.tools.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertNotNil(ControlCatalog.tool(named: "get_status"))
        let use = ControlCatalog.tool(named: "use_profile")!
        XCTAssertEqual(use.permission, .operate)
        let schema = use.inputSchema
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["required"] as? [String], ["profile"])
        // 只剩查看状态和开关、切换配置：没有改配置的工具。
        XCTAssertEqual(Set(names), ["get_status", "list_profiles", "get_logs", "turn_on", "use_profile", "turn_off", "toggle", "test_profiles"])
        XCTAssertTrue(ControlPermission.operate.allows(.readOnly))
        XCTAssertFalse(ControlPermission.readOnly.allows(.operate))
        XCTAssertFalse(ControlPermission.off.allows(.readOnly))
        let params = ControlParams(["a": " x ", "n": 3, "b": "yes", "e": ""])
        XCTAssertEqual(params.string("a"), "x")
        XCTAssertNil(params.string("e"))
        XCTAssertEqual(params.int("n"), 3)
        XCTAssertEqual(params.bool("b"), true)
        XCTAssertThrowsError(try params.require("missing"))
    }

    /// 以前版本的「完全控制」读出来按「开关和切换」算，读不出来的网络规则只跳过那一条。
    func testLegacyPermissionAndRules() throws {
        let json = #"{"permission":"full","networkSwitching":true,"networkRules":[{"match":"ssid:Office","action":"mode:global"},{"match":"other","action":"off"}]}"#
        let automation = try JSONDecoder().decode(AutomationConfig.self, from: Data(json.utf8))
        XCTAssertEqual(automation.permission, .operate)
        XCTAssertEqual(automation.networkRules.count, 1)
        XCTAssertEqual(automation.networkRules.first?.action, .off)
        XCTAssertEqual(ControlPermission.allCases, [.off, .readOnly, .operate])
    }

    func testMCPServer() throws {
        var calls: [(String, [String: Any])] = []
        let server = MCPServer(version: "1.0") { name, arguments in
            calls.append((name, arguments))
            if name == "turn_off" { throw ControlError.failed("不行") }
            return ["text": "好了", "value": 1]
        }
        func send(_ object: [String: Any]) -> [String: Any]? {
            server.handle(JSONRPC.encode(object))
        }
        let initialize = try XCTUnwrap(send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26", "capabilities": [:], "clientInfo": ["name": "test", "version": "1"]]]))
        let info = try XCTUnwrap(initialize["result"] as? [String: Any])
        XCTAssertEqual(info["protocolVersion"] as? String, "2025-03-26")
        XCTAssertNotNil(info["instructions"] as? String)
        XCTAssertNil(send(["jsonrpc": "2.0", "method": "notifications/initialized"]))
        let list = try XCTUnwrap(send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])?["result"] as? [String: Any])
        let tools = try XCTUnwrap(list["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, ControlCatalog.tools.count)
        XCTAssertNotNil(tools.first?["inputSchema"] as? [String: Any])
        let result = try XCTUnwrap(send(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "get_status", "arguments": ["x": 1]]])?["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        let content = try XCTUnwrap((result["content"] as? [[String: Any]])?.first?["text"] as? String)
        XCTAssertTrue(content.hasPrefix("好了"))
        XCTAssertNil(result["structuredContent"], "旧版协议不带结构化内容")
        XCTAssertEqual(calls.first?.0, "get_status")
        let failed = try XCTUnwrap(send(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "turn_off"]])?["result"] as? [String: Any])
        XCTAssertEqual(failed["isError"] as? Bool, true)
        let unknown = try XCTUnwrap(send(["jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": ["name": "nope"]]))
        XCTAssertNotNil(unknown["error"])
        XCTAssertNotNil(send(["jsonrpc": "2.0", "id": 6, "method": "bogus"])?["error"])
        XCTAssertNotNil(send(["jsonrpc": "2.0", "id": 7, "method": "ping"])?["result"])
        // 新版协议带结构化内容。
        _ = send(["jsonrpc": "2.0", "id": 8, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]])
        let structured = try XCTUnwrap(send(["jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": ["name": "get_status"]])?["result"] as? [String: Any])
        XCTAssertEqual((structured["structuredContent"] as? [String: Any])?["value"] as? Int, 1)
    }

    func testSocketRoundTrip() throws {
        let path = NSTemporaryDirectory() + "ps-test-\(UUID().uuidString.prefix(6)).sock"
        let server = ControlSocketServer(path: path) { line in
            let request = JSONRPC.decode(line) ?? [:]
            let method = request["method"] as? String ?? ""
            if method == "fail" {
                return JSONRPC.encode(JSONRPC.error(id: request["id"], code: JSONRPC.permissionDenied, message: "权限不够"))
            }
            return JSONRPC.encode(JSONRPC.result(id: request["id"], ["echo": method, "client": request["client"] as? String ?? ""]))
        }
        try server.start()
        defer { server.stop() }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let result = try ControlSocketClient.call("get_status", client: "cli", path: path, timeout: 5)
        XCTAssertEqual(result["echo"] as? String, "get_status")
        XCTAssertEqual(result["client"] as? String, "cli")
        XCTAssertThrowsError(try ControlSocketClient.call("fail", client: "cli", path: path, timeout: 5)) { error in
            XCTAssertEqual((error as? ControlError)?.code, JSONRPC.permissionDenied)
        }
        // 几个并发的客户端。
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }
        let group = DispatchGroup()
        let answers = Counter()
        for index in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                if let result = try? ControlSocketClient.call("m\(index)", client: "cli", path: path, timeout: 5), result["echo"] as? String == "m\(index)" {
                    answers.increment()
                }
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(answers.count, 8)
        server.stop()
        XCTAssertThrowsError(try ControlSocketClient.call("x", client: "cli", path: path, timeout: 2)) { error in
            XCTAssertEqual((error as? ControlError)?.code, JSONRPC.notRunning)
        }
    }
}

final class CommandLineTests: XCTestCase {
    func testShouldHandle() {
        XCTAssertTrue(CommandLineTool.shouldHandle(["Proxi", "status"]))
        XCTAssertTrue(CommandLineTool.shouldHandle(["Proxi", "mcp"]))
        XCTAssertTrue(CommandLineTool.shouldHandle(["Proxi", "--help"]))
        // --json 写在子命令前面也是命令行，不能再打开一个图形界面（会抢走控制接口的套接字）。
        XCTAssertTrue(CommandLineTool.shouldHandle(["Proxi", "--json", "status"]))
        XCTAssertFalse(CommandLineTool.shouldHandle(["Proxi", "--json"]))
        XCTAssertFalse(CommandLineTool.shouldHandle(["Proxi"]))
        // 系统启动程序时可能带的参数不算命令。
        XCTAssertFalse(CommandLineTool.shouldHandle(["Proxi", "-psn_0_12345"]))
        XCTAssertFalse(CommandLineTool.shouldHandle(["Proxi", "-NSDocumentRevisionsDebugMode", "YES"]))
    }

    func testRequests() throws {
        func request(_ args: String...) throws -> (String, [String: Any])? {
            try CommandLineTool.request(for: args[0], Array(args.dropFirst()))
        }
        XCTAssertEqual(try request("status")?.0, "get_status")
        let use = try XCTUnwrap(try request("use", "公司", "代理"))
        XCTAssertEqual(use.0, "use_profile")
        XCTAssertEqual(use.1["profile"] as? String, "公司 代理")
        XCTAssertNil(try request("use"))
        XCTAssertEqual(try request("on", "Charles")?.1["profile"] as? String, "Charles")
        XCTAssertNil(try request("on")?.1["profile"])
        XCTAssertEqual(try request("test", "Charles")?.0, "test_profiles")
        XCTAssertEqual(try request("logs", "50")?.1["lines"] as? Int, 50)
        XCTAssertEqual(try request("call", "use_profile", #"{"profile":"Charles"}"#)?.1["profile"] as? String, "Charles")
        XCTAssertThrowsError(try request("call", "use_profile", "not json"))
        XCTAssertNil(try request("bogus"))
        // 以前版本的命令不再认。
        for command in ["node", "nodes", "rule", "sub", "share", "gateway", "import", "undo"] {
            XCTAssertFalse(CommandLineTool.commands.contains(command), command)
        }
        // 每个子命令对应的工具都在清单里。
        for command in ["status", "on", "off", "toggle", "profiles", "test", "logs"] {
            let name = try XCTUnwrap(try request(command)?.0, command)
            XCTAssertNotNil(ControlCatalog.tool(named: name), command)
        }
        XCTAssertNotNil(ControlCatalog.tool(named: try XCTUnwrap(try request("use", "x")?.0)))
    }
}
