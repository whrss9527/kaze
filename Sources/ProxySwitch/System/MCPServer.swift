import Foundation

/// MCP（Model Context Protocol）服务器：AI 助手启动 `ProxySwitch mcp`，经标准输入输出说 JSON-RPC，
/// 工具调用转给正在运行的 ProxySwitch（本机控制接口）。
final class MCPServer {
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// 调用工具：名字、参数 → 结果（里面的 text 是给人看的一句话）。出错时抛出。
    private let call: (String, [String: Any]) throws -> [String: Any]
    private let version: String
    private(set) var negotiatedVersion = MCPServer.supportedVersions[0]

    init(version: String, call: @escaping (String, [String: Any]) throws -> [String: Any]) {
        self.version = version
        self.call = call
    }

    /// 处理一行消息，返回要回的消息；通知（没有 id）不回。
    func handle(_ line: Data) -> [String: Any]? {
        guard let message = JSONRPC.decode(line) else {
            return JSONRPC.error(id: nil, code: JSONRPC.parseError, message: "不是正确的 JSON")
        }
        let id = message["id"]
        guard let method = message["method"] as? String else {
            // 客户端发来的回应（我们不发请求，忽略）。
            return nil
        }
        guard let id, !(id is NSNull) else { return nil }
        let params = (message["params"] as? [String: Any]) ?? [:]
        switch method {
        case "initialize":
            if let requested = params["protocolVersion"] as? String, MCPServer.supportedVersions.contains(requested) {
                negotiatedVersion = requested
            }
            return JSONRPC.result(id: id, [
                "protocolVersion": negotiatedVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "proxyswitch", "title": "ProxySwitch", "version": version],
                "instructions": ControlCatalog.instructions,
            ])
        case "ping":
            return JSONRPC.result(id: id, [String: Any]())
        case "tools/list":
            let tools = ControlCatalog.tools.map { tool -> [String: Any] in
                [
                    "name": tool.name,
                    "title": tool.title,
                    "description": tool.description,
                    "inputSchema": tool.inputSchema,
                    "annotations": [
                        "title": tool.title,
                        "readOnlyHint": tool.readOnly,
                        "destructiveHint": tool.name.hasPrefix("remove_") || tool.name == "import_config",
                        "openWorldHint": false,
                    ],
                ]
            }
            return JSONRPC.result(id: id, ["tools": tools])
        case "tools/call":
            guard let name = params["name"] as? String, ControlCatalog.tool(named: name) != nil else {
                return JSONRPC.error(id: id, code: JSONRPC.invalidParams, message: "没有这个工具")
            }
            let arguments = (params["arguments"] as? [String: Any]) ?? [:]
            do {
                let result = try call(name, arguments)
                return JSONRPC.result(id: id, toolResult(result, isError: false))
            } catch {
                // 工具本身出错按 MCP 的约定放在结果里（isError），让 AI 助手看得到原因。
                return JSONRPC.result(id: id, toolResult(["text": error.localizedDescription], isError: true))
            }
        case "resources/list":
            return JSONRPC.result(id: id, ["resources": [Any]()])
        case "resources/templates/list":
            return JSONRPC.result(id: id, ["resourceTemplates": [Any]()])
        case "prompts/list":
            return JSONRPC.result(id: id, ["prompts": [Any]()])
        default:
            return JSONRPC.error(id: id, code: JSONRPC.methodNotFound, message: "不支持 \(method)")
        }
    }

    /// 工具结果：一段文字（先是一句话，再是完整的 JSON），新版协议再带上结构化的内容。
    private func toolResult(_ result: [String: Any], isError: Bool) -> [String: Any] {
        var data = result
        let summary = (data.removeValue(forKey: "text") as? String) ?? (isError ? "出错了" : "完成")
        var text = summary
        if !data.isEmpty {
            text += "\n\n" + JSONRPC.pretty(data)
        }
        var output: [String: Any] = ["content": [["type": "text", "text": text]], "isError": isError]
        if negotiatedVersion >= "2025-06-18", !data.isEmpty, !isError {
            output["structuredContent"] = data
        }
        return output
    }

    /// 从标准输入读到结束为止。
    func run(input: () -> String? = { readLine(strippingNewline: true) }, output: (String) -> Void = { line in
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }) {
        while let line = input() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let response = handle(Data(trimmed.utf8)) {
                output(String(decoding: JSONRPC.encode(response), as: UTF8.self))
            }
        }
    }
}
