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
    static let policyHelp = "去向：proxy（走节点）、direct（直连）、reject（拦截），或者策略组的名字"

    static let tools: [ControlTool] = [
        // 查看
        ControlTool(name: "get_status", title: "查看状态", description: "查看代理现在的状态：开没开、用的哪个配置、内置代理的节点和模式、局域网共享、出口 IP。做任何操作前先看一下。", permission: .readOnly),
        ControlTool(name: "list_profiles", title: "代理配置", description: "列出所有代理配置（内置代理、公司代理、别的代理软件等），开启时用配置名。", permission: .readOnly),
        ControlTool(name: "list_nodes", title: "节点", description: "列出内置代理的节点和延迟（毫秒，0 是超时），收藏的在前。", permission: .readOnly, parameters: [
            ControlParameter(name: "filter", kind: .string, description: "只列出名字里有这个词的节点"),
            ControlParameter(name: "limit", kind: .integer, description: "最多列出多少个，默认 200"),
        ]),
        ControlTool(name: "list_groups", title: "策略组", description: "列出策略组、它们现在用的成员和全部候选。", permission: .readOnly),
        ControlTool(name: "list_rules", title: "分流规则", description: "列出自定义规则、规则集和其余流量的去向。规则的匹配顺序：局域网直连 → 自定义规则 → 规则集（按顺序）→ 其余流量。", permission: .readOnly),
        ControlTool(name: "list_subscriptions", title: "订阅", description: "列出订阅、手动节点和它们的节点数、流量、到期时间。", permission: .readOnly),
        ControlTool(name: "list_connections", title: "连接", description: "列出现在开着的和最近的连接：谁访问了什么、走了哪个节点、命中了哪条规则。", permission: .readOnly, parameters: [
            ControlParameter(name: "filter", kind: .string, description: "按域名、程序、规则或节点筛选"),
            ControlParameter(name: "limit", kind: .integer, description: "最多列出多少条，默认 50"),
        ]),
        ControlTool(name: "get_traffic", title: "流量统计", description: "按节点、按程序和设备、按天累计的流量。", permission: .readOnly),
        ControlTool(name: "get_logs", title: "日志", description: "ProxySwitch 和内核最近的日志，排查问题用。", permission: .readOnly, parameters: [
            ControlParameter(name: "lines", kind: .integer, description: "多少行，默认 80"),
        ]),
        ControlTool(name: "diagnose_url", title: "网址诊断", description: "诊断一个网址为什么打不开：经内核访问一次，看命中了哪条规则、走了哪个出口、有没有出错，并给出结论。", permission: .readOnly, parameters: [
            ControlParameter(name: "url", kind: .string, description: "网址或域名，比如 https://www.youtube.com", required: true),
        ]),
        ControlTool(name: "export_config", title: "导出配置", description: "导出配置：describe 是 ProxySwitch 的配置描述（JSON，可以改了再用 import_config 导入）；backup 是完整备份；core 是生成的内核配置（YAML，去掉了密钥）。", permission: .readOnly, parameters: [
            ControlParameter(name: "format", kind: .string, description: "导出的格式，默认 describe", choices: ["describe", "backup", "core"]),
        ]),
        ControlTool(name: "preview_import", title: "预览导入", description: "预览导入会改动什么，不会真的改。内容可以是 ProxySwitch 的配置描述（JSON）、Clash / mihomo 的 YAML、Surge / 小火箭 / Quantumult X 的配置、节点链接或规则列表；也可以给网址。", permission: .readOnly, parameters: [
            ControlParameter(name: "content", kind: .string, description: "配置内容"),
            ControlParameter(name: "url", kind: .string, description: "配置的网址（给了 content 就不用）"),
        ]),
        ControlTool(name: "list_changes", title: "操作记录", description: "经这个接口做过的操作，最新的在前；能撤销的会标出来。", permission: .readOnly),
        // 日常操作
        ControlTool(name: "turn_on", title: "开启代理", description: "开启代理。不写配置名时开上次用的配置。", permission: .operate, parameters: [
            ControlParameter(name: "profile", kind: .string, description: "配置名，比如「节点代理」"),
        ]),
        ControlTool(name: "turn_off", title: "关闭代理", description: "关闭代理。", permission: .operate),
        ControlTool(name: "toggle", title: "开关代理", description: "开着就关，关着就开。", permission: .operate),
        ControlTool(name: "select_node", title: "切换节点", description: "给「节点」组选一个节点；auto 表示自动选择延迟最低的。", permission: .operate, parameters: [
            ControlParameter(name: "name", kind: .string, description: "节点名（可以只写一部分，唯一匹配时生效），或者 auto", required: true),
        ]),
        ControlTool(name: "select_group", title: "切换策略组", description: "给某个策略组选成员。", permission: .operate, parameters: [
            ControlParameter(name: "group", kind: .string, description: "策略组名", required: true),
            ControlParameter(name: "member", kind: .string, description: "成员名：节点、「节点」「自动选择」、DIRECT 或别的组", required: true),
        ]),
        ControlTool(name: "set_mode", title: "切换模式", description: "规则分流（rule）或全局代理（global）。", permission: .operate, parameters: [
            ControlParameter(name: "mode", kind: .string, description: "模式", required: true, choices: ["rule", "global"]),
        ]),
        ControlTool(name: "test_nodes", title: "测速", description: "测节点的延迟，返回每个节点的毫秒数（0 是超时）。", permission: .operate, parameters: [
            ControlParameter(name: "filter", kind: .string, description: "只测名字里有这个词的节点；不写就测全部"),
        ]),
        ControlTool(name: "check_services", title: "服务检测", description: "检测 Google、YouTube Premium、Netflix、ChatGPT、Claude、Gemini、GitHub、Telegram 经节点能不能用、服务看到的地区。不写节点时用现在的节点；写了节点时临时经它检测，不影响正在用的。", permission: .operate, parameters: [
            ControlParameter(name: "node", kind: .string, description: "节点名"),
        ]),
        ControlTool(name: "update_subscriptions", title: "更新订阅", description: "重新下载全部订阅。", permission: .operate),
        ControlTool(name: "update_rule_sets", title: "更新规则", description: "重新下载全部规则集。", permission: .operate),
        ControlTool(name: "close_connections", title: "断开连接", description: "断开一条连接（给 id）或者全部连接。", permission: .operate, parameters: [
            ControlParameter(name: "id", kind: .string, description: "连接的 id；不写就断开全部"),
        ]),
        ControlTool(name: "set_share", title: "局域网共享", description: "开关局域网共享（让 PS5、手机等设备把这台 Mac 当代理）。", permission: .operate, parameters: [
            ControlParameter(name: "enabled", kind: .boolean, description: "开还是关", required: true),
        ]),
        // 改配置
        ControlTool(name: "add_rule", title: "加规则", description: "加一条自定义规则（最先匹配）。同样的规则已经有了就改它的去向。", permission: .full, parameters: [
            ControlParameter(name: "value", kind: .string, description: "匹配的内容：域名、IP、应用路径、设备 IP、端口……", required: true),
            ControlParameter(name: "policy", kind: .string, description: policyHelp, required: true),
            ControlParameter(name: "type", kind: .string, description: "类型，默认 auto（域名或 IP 自动判断）", choices: CustomRuleKind.allCases.map(\.rawValue)),
        ]),
        ControlTool(name: "remove_rule", title: "删规则", description: "删掉自定义规则：按内容匹配（或者给 id）。", permission: .full, parameters: [
            ControlParameter(name: "value", kind: .string, description: "规则的内容"),
            ControlParameter(name: "id", kind: .string, description: "规则的 id"),
        ]),
        ControlTool(name: "set_final", title: "其余流量", description: "没被任何规则命中的流量往哪走；follow 表示跟随规则文件。", permission: .full, parameters: [
            ControlParameter(name: "policy", kind: .string, description: policyHelp + "，或者 follow", required: true),
        ]),
        ControlTool(name: "add_subscription", title: "加订阅", description: "加一条机场订阅。", permission: .full, parameters: [
            ControlParameter(name: "url", kind: .string, description: "订阅地址", required: true),
            ControlParameter(name: "name", kind: .string, description: "名字"),
        ]),
        ControlTool(name: "remove_subscription", title: "删订阅", description: "删掉一条订阅（按名字或地址）。", permission: .full, parameters: [
            ControlParameter(name: "name", kind: .string, description: "订阅的名字或地址", required: true),
        ]),
        ControlTool(name: "add_nodes", title: "加节点", description: "加手动节点：分享链接（ss://、vmess://、vless://、trojan://、hysteria2://、tuic:// 等），一行一条，或者整段 base64。", permission: .full, parameters: [
            ControlParameter(name: "links", kind: .string, description: "节点链接", required: true),
        ]),
        ControlTool(name: "add_rule_set", title: "加规则集", description: "加一个规则集：给网址，或者给规则库里的名字（比如「广告拦截」「Netflix」「OpenAI」）。", permission: .full, parameters: [
            ControlParameter(name: "url", kind: .string, description: "规则列表的网址"),
            ControlParameter(name: "library", kind: .string, description: "规则库里的名字"),
            ControlParameter(name: "policy", kind: .string, description: policyHelp),
            ControlParameter(name: "name", kind: .string, description: "名字"),
        ]),
        ControlTool(name: "remove_rule_set", title: "删规则集", description: "删掉一个规则集（按名字或网址）。", permission: .full, parameters: [
            ControlParameter(name: "name", kind: .string, description: "规则集的名字或网址", required: true),
        ]),
        ControlTool(name: "add_group", title: "加策略组", description: "加一个策略组，给某类流量单独选节点；再用 add_rule 把流量指到它。", permission: .full, parameters: [
            ControlParameter(name: "name", kind: .string, description: "组名", required: true),
            ControlParameter(name: "type", kind: .string, description: "类型，默认 select", choices: ["select", "url-test", "fallback", "load-balance"]),
            ControlParameter(name: "filter", kind: .string, description: "节点名筛选（正则，不区分大小写），比如 港|HK"),
            ControlParameter(name: "exclude", kind: .string, description: "排除的节点（正则）"),
        ]),
        ControlTool(name: "remove_group", title: "删策略组", description: "删掉一个策略组，指向它的规则改成走节点。", permission: .full, parameters: [
            ControlParameter(name: "name", kind: .string, description: "组名", required: true),
        ]),
        ControlTool(name: "import_config", title: "导入配置", description: "导入配置并生效（先用 preview_import 看看会改什么）。merge 加进现有设置、同名的更新；replace 用导入的内容替换同类设置。复杂的改动（DNS、Hosts、策略组的高级选项、按网络切换……）都可以写成 ProxySwitch 的配置描述 JSON 导入。", permission: .full, parameters: [
            ControlParameter(name: "content", kind: .string, description: "配置内容"),
            ControlParameter(name: "url", kind: .string, description: "配置的网址"),
            ControlParameter(name: "mode", kind: .string, description: "默认 merge", choices: ["merge", "replace"]),
        ]),
        ControlTool(name: "undo", title: "撤销", description: "撤销经这个接口做的最近一次配置改动。", permission: .full),
    ]

    static func tool(named name: String) -> ControlTool? {
        tools.first { $0.name == name }
    }

    /// MCP 初始化时给 AI 助手的使用说明（我们定的规则）。
    static let instructions = """
    ProxySwitch 是 macOS 上的代理开关，内置 mihomo 内核。用这些工具时请遵守：
    1. 先用 get_status 看现在的状态，再决定做什么。
    2. 只做用户要求的事；开关代理、切节点这类操作会立刻影响整台电脑的网络，做之前说清楚。
    3. 改配置（add_*、remove_*、import_config）前先说明要改什么；复杂的改动先用 preview_import 预览，确认后再用 import_config。
    4. 每次改配置都会记在操作记录里，用 undo 可以撤销最近一次；改错了先撤销再重来。
    5. 网站打不开时先用 diagnose_url 看命中了哪条规则、走了哪个出口，再决定加规则还是换节点。
    6. 规则的去向写 proxy（走节点）、direct（直连）、reject（拦截）或者策略组的名字。
    7. 节点名可以只写一部分，但要能唯一确定是哪个；不确定时先 list_nodes。
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
    /// ProxySwitch 没在运行（本程序自定义）。
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
        guard let value = string(name) else { throw ControlError.invalid("缺少参数 \(name)") }
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
            if ["true", "yes", "on", "1", "开"].contains(text) { return true }
            if ["false", "no", "off", "0", "关"].contains(text) { return false }
        }
        return nil
    }
}
