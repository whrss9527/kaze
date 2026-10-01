import Foundation

/// 本机控制接口的一个参数。
struct ControlParameter {
    enum Kind: String {
        case string, integer, boolean
    }

    var name: String
    var kind: Kind
    var description: String
    var required: Bool = false
    var choices: [String]? = nil
}

/// 本机控制接口能做的一件事：命令行、MCP（AI 助手）和 URL 命令共用这份清单。
struct ControlTool {
    var name: String
    var title: String
    /// 给 AI 助手看的说明：做什么、什么时候用。
    var description: String
    var permission: ControlPermission
    var parameters: [ControlParameter] = []

    /// MCP 的 inputSchema（JSON Schema）。
    var inputSchema: [String: Any] {
        var properties: [String: Any] = [:]
        for parameter in parameters {
            var property: [String: Any] = ["type": parameter.kind.rawValue, "description": parameter.description]
            if let choices = parameter.choices {
                property["enum"] = choices
            }
            properties[parameter.name] = property
        }
        var schema: [String: Any] = ["type": "object", "properties": properties]
        let required = parameters.filter(\.required).map(\.name)
        if !required.isEmpty {
            schema["required"] = required
        }
        return schema
    }

    /// 会不会改动东西（MCP 的 annotations 里告诉 AI 助手）。
    var readOnly: Bool { permission == .readOnly }
}

/// 全部的工具。
enum ControlCatalog {
    static let tools: [ControlTool] = [
        // 查看
        ControlTool(name: "get_status", title: L("查看状态"), description: L("查看代理现在的状态：开没开、用的哪个配置、系统代理现在指向哪里。做任何操作前先看一下。"), permission: .readOnly),
        ControlTool(name: "list_profiles", title: L("代理配置"), description: L("列出所有代理配置（比如公司代理、内网网关、本机的调试代理），开启和切换时用配置名。"), permission: .readOnly),
        ControlTool(name: "get_logs", title: L("日志"), description: L("Proxi 最近的日志，排查问题用。"), permission: .readOnly, parameters: [
            ControlParameter(name: "lines", kind: .integer, description: L("多少行，默认 80")),
        ]),
        // 开关和切换
        ControlTool(name: "turn_on", title: L("开启代理"), description: L("开启代理。不写配置名时开上次用的配置。"), permission: .operate, parameters: [
            ControlParameter(name: "profile", kind: .string, description: L("配置名，比如「公司代理」")),
        ]),
        ControlTool(name: "use_profile", title: L("切换配置"), description: L("切换到某个代理配置并开启（已经开着别的配置时直接换过去）。"), permission: .operate, parameters: [
            ControlParameter(name: "profile", kind: .string, description: L("配置名（可以只写一部分，唯一匹配时生效）"), required: true),
        ]),
        ControlTool(name: "turn_off", title: L("关闭代理"), description: L("关闭代理：系统代理、终端环境变量、git 和 npm 的代理设置都清掉。"), permission: .operate),
        ControlTool(name: "toggle", title: L("开关代理"), description: L("开着就关，关着就开。"), permission: .operate),
        ControlTool(name: "test_profiles", title: L("测试连接"), description: L("经代理配置访问一次测试地址，看代理服务器能不能连上、要多久。不写配置名就测全部。"), permission: .operate, parameters: [
            ControlParameter(name: "profile", kind: .string, description: L("配置名")),
        ]),
    ]

    static func tool(named name: String) -> ControlTool? {
        tools.first { $0.name == name }
    }

    /// MCP 初始化时给 AI 助手的使用说明（我们定的规则），跟着界面语言。
    static var instructions: String { AppLanguage.isEnglish ? instructionsEnglish : instructionsChinese }

    // l10n-ignore：中文界面的说明，英文的在 instructionsEnglish。
    static let instructionsChinese = """
    Proxi 是 macOS 上给开发者用的代理开关：一键把系统代理、终端环境变量、git 和 npm 指向用户自己的代理服务器（公司代理、内网网关、Charles / Proxyman / mitmproxy 这类调试代理）。用这些工具时请遵守：
    1. 先用 get_status 看现在的状态，再决定做什么。
    2. 只做用户要求的事；开关代理、切换配置会立刻影响整台电脑的网络，做之前说清楚。
    3. 配置名可以只写一部分，但要能唯一确定是哪个；不确定时先 list_profiles。
    4. 连不上时用 test_profiles 看看代理服务器是不是在运行。
    """

    static let instructionsEnglish = """
    Proxi is a proxy switch for developers on macOS: one switch points the system proxy, Terminal environment variables, git and npm at a proxy server the user already runs (a corporate proxy, an intranet gateway, or a debugging proxy such as Charles, Proxyman or mitmproxy). When using these tools:
    1. Check the current state with get_status before deciding what to do.
    2. Only do what the user asked for. Turning the proxy on or off and switching profiles affect the whole computer's network immediately, so say so first.
    3. Profile names can be partial as long as they match exactly one profile; when unsure, call list_profiles first.
    4. When something can't connect, use test_profiles to see whether the proxy server is running.
    """
}

/// JSON-RPC 的一些小工具：本机控制接口和 MCP 都用 JSON-RPC 2.0，一行一条消息。
enum JSONRPC {
    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    /// 权限不够（本程序自定义）。
    static let permissionDenied = -32001
    /// Proxi 没在运行（本程序自定义）。
    static let notRunning = -32002

    static func request(id: Any, method: String, params: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
    }

    static func result(id: Any?, _ result: Any) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
    }

    static func error(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }

    /// 一行 JSON（结尾不带换行）。
    static func encode(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    static func decode(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// 给人看的 JSON。
    static func pretty(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object) || object is String || object is NSNumber else { return "\(object)" }
        if let text = object as? String { return text }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// 控制接口出错。
struct ControlError: LocalizedError {
    var code: Int
    var message: String

    var errorDescription: String? { message }

    static func invalid(_ message: String) -> ControlError { ControlError(code: JSONRPC.invalidParams, message: message) }
    static func failed(_ message: String) -> ControlError { ControlError(code: JSONRPC.internalError, message: message) }
}

/// 参数读取。
struct ControlParams {
    var values: [String: Any]

    init(_ values: [String: Any]) {
        self.values = values
    }

    func string(_ name: String) -> String? {
        if let text = values[name] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = values[name] as? NSNumber { return number.stringValue }
        return nil
    }

    func require(_ name: String) throws -> String {
        guard let value = string(name) else { throw ControlError.invalid(L("缺少参数 %@", name)) }
        return value
    }

    func int(_ name: String) -> Int? {
        if let number = values[name] as? NSNumber { return number.intValue }
        if let text = values[name] as? String { return Int(text) }
        return nil
    }

    func bool(_ name: String) -> Bool? {
        if let number = values[name] as? NSNumber { return number.boolValue }
        if let text = (values[name] as? String)?.lowercased() {
            if ["true", "yes", "on", "1", "开"].contains(text) { return true }  // l10n-ignore：参数里的写法
            if ["false", "no", "off", "0", "关"].contains(text) { return false }  // l10n-ignore：参数里的写法
        }
        return nil
    }
}
