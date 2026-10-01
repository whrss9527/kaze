import Foundation

/// 命令行：直接运行程序里的二进制并带上子命令（`… status`、`… node <名字>`），不启动图形界面。
/// 经代理引擎自己的本机控制接口操作正在运行的代理引擎；它没在运行时先在后台把它打开。
/// `helper` 子命令是特权助手用的（安装、卸载、launchd 启动守护进程）。
enum CommandLineTool {
    static let commands: Set<String> = [
        "status", "nodes", "node", "groups", "group", "mode", "test", "check",
        "rules", "rule", "final", "subs", "sub", "add-nodes", "rulesets", "ruleset", "group-add", "group-remove",
        "import", "export", "connections", "traffic", "logs", "diagnose", "share", "tun", "gateway", "close", "undo", "history",
        "call", "tools", "helper", "help", "version",
    ]

    /// 带了认识的子命令时由命令行处理。
    static func shouldHandle(_ arguments: [String]) -> Bool {
        guard arguments.count > 1 else { return false }
        let first = arguments[1]
        return commands.contains(first) || ["-h", "--help", "--version"].contains(first)
    }

    static func run(_ arguments: [String]) -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        var args = Array(arguments.dropFirst())
        let json = args.contains("--json")
        let replace = args.contains("--replace")
        let preview = args.contains("--preview")
        var type: String?
        if let index = args.firstIndex(of: "--type"), index + 1 < args.count {
            type = args[index + 1]
            args.removeSubrange(index...(index + 1))
        }
        args.removeAll { ["--json", "--replace", "--preview"].contains($0) }
        guard let command = args.first else {
            print(help)
            return 0
        }
        let rest = Array(args.dropFirst())
        do {
            switch command {
            case "help", "-h", "--help":
                print(help)
                return 0
            case "version", "--version":
                print("Proxi Engine \(UpdateChecker.currentVersion)")
                return 0
            case "tools":
                for tool in ControlCatalog.tools {
                    print(L("%@（%@，%@）：%@", tool.name, tool.title, tool.permission.title, tool.description))
                }
                return 0
            case "helper":
                // 装、卸特权助手要 root，不经正在运行的程序。内核的位置由程序用 --core 传进来（root 的数据目录不是用户的）。
                return HelperCommand.run(rest, appVersion: UpdateChecker.currentVersion, executable: Bundle.main.executablePath ?? CommandLine.arguments[0], bundledCore: CoreBinary.installedPath)
            default:
                guard let (method, params) = try request(for: command, rest, type: type, replace: replace, preview: preview) else {
                    printError(L("用法不对。\n\n") + help)
                    return 2
                }
                let result = try callLaunching(method, params: params, client: "cli")
                if json {
                    print(JSONRPC.pretty(result))
                } else {
                    printHuman(method, result)
                }
                return 0
            }
        } catch let error as ControlError {
            printError(error.message)
            return error.code == JSONRPC.permissionDenied ? 3 : 1
        } catch {
            printError(error.localizedDescription)
            return 1
        }
    }

    // MARK: - 子命令 → 工具

    static func request(for command: String, _ rest: [String], type: String?, replace: Bool, preview: Bool) throws -> (String, [String: Any])? {
        let joined = rest.joined(separator: " ")
        var params: [String: Any] = [:]
        /// 至少要有 count 个参数。
        func need(_ count: Int) -> Bool { rest.count >= count }
        switch command {
        case "status": return ("get_status", params)
        case "nodes":
            if !rest.isEmpty { params["filter"] = joined }
            return ("list_nodes", params)
        case "node":
            guard need(1) else { return nil }
            params["name"] = joined
            return ("select_node", params)
        case "groups": return ("list_groups", params)
        case "group":
            guard need(2) else { return nil }
            params["group"] = rest[0]
            params["member"] = rest.dropFirst().joined(separator: " ")
            return ("select_group", params)
        case "mode":
            guard rest.count == 1 else { return nil }
            params["mode"] = rest[0]
            return ("set_mode", params)
        case "test":
            if !rest.isEmpty { params["filter"] = joined }
            return ("test_nodes", params)
        case "check":
            guard need(1) else { return nil }
            params["url"] = rest[0]
            if rest.count > 1 { params["node"] = rest.dropFirst().joined(separator: " ") }
            return ("check_url", params)
        case "rules", "rulesets": return ("list_rules", params)
        case "rule":
            guard let action = rest.first else { return nil }
            if action == "add", need(3) {
                params["value"] = rest[1]
                params["policy"] = rest[2...].joined(separator: " ")
                if let type { params["type"] = type }
                return ("add_rule", params)
            }
            if action == "remove", need(2) {
                params["value"] = rest[1...].joined(separator: " ")
                return ("remove_rule", params)
            }
            return nil
        case "final":
            guard need(1) else { return nil }
            params["policy"] = joined
            return ("set_final", params)
        case "subs": return ("list_subscriptions", params)
        case "sub":
            guard let action = rest.first else { return nil }
            if action == "add", need(2) {
                params["url"] = rest[1]
                if rest.count > 2 { params["name"] = rest[2...].joined(separator: " ") }
                return ("add_subscription", params)
            }
            if action == "remove", need(2) {
                params["name"] = rest[1...].joined(separator: " ")
                return ("remove_subscription", params)
            }
            if action == "update" { return ("update_subscriptions", params) }
            return nil
        case "add-nodes":
            params["links"] = rest.isEmpty || rest == ["-"] ? readStandardInput() : rest.joined(separator: "\n")
            return ("add_nodes", params)
        case "ruleset":
            guard let action = rest.first else { return nil }
            if action == "add", need(2) {
                if rest[1].contains("://") {
                    params["url"] = rest[1]
                } else {
                    params["library"] = rest[1]
                }
                if rest.count > 2 { params["policy"] = rest[2...].joined(separator: " ") }
                return ("add_rule_set", params)
            }
            if action == "remove", need(2) {
                params["name"] = rest[1...].joined(separator: " ")
                return ("remove_rule_set", params)
            }
            if action == "update" { return ("update_rule_sets", params) }
            return nil
        case "group-add":
            guard let name = rest.first else { return nil }
            params["name"] = name
            if rest.count > 1 { params["type"] = rest[1] }
            if rest.count > 2 { params["filter"] = rest[2...].joined(separator: " ") }
            return ("add_group", params)
        case "group-remove":
            guard need(1) else { return nil }
            params["name"] = joined
            return ("remove_group", params)
        case "import":
            guard let source = rest.first else { return nil }
            let path = (source as NSString).expandingTildeInPath
            if source == "-" {
                params["content"] = readStandardInput()
            } else if FileManager.default.fileExists(atPath: path) {
                params["content"] = try String(contentsOfFile: path, encoding: .utf8)
            } else {
                params["url"] = source
            }
            if preview { return ("preview_import", params) }
            params["mode"] = replace ? "replace" : "merge"
            return ("import_config", params)
        case "export":
            params["format"] = rest.first ?? "describe"
            return ("export_config", params)
        case "connections":
            if !rest.isEmpty { params["filter"] = joined }
            return ("list_connections", params)
        case "traffic": return ("get_traffic", params)
        case "logs":
            if let lines = rest.first.flatMap({ Int($0) }) { params["lines"] = lines }
            return ("get_logs", params)
        case "diagnose":
            guard need(1) else { return nil }
            params["url"] = rest[0]
            return ("diagnose_url", params)
        case "share", "tun", "gateway":
            guard let value = rest.first?.lowercased(), ["on", "off"].contains(value) else { return nil }
            params["enabled"] = value == "on"
            return (["share": "set_share", "tun": "set_tun", "gateway": "set_gateway"][command] ?? "set_share", params)
        case "close":
            if let id = rest.first { params["id"] = id }
            return ("close_connections", params)
        case "undo": return ("undo", params)
        case "history": return ("list_changes", params)
        case "call":
            guard let name = rest.first else { return nil }
            if rest.count > 1 {
                let text = rest[1...].joined(separator: " ")
                guard let data = text.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ControlError.invalid(L("参数要是 JSON 对象，比如 '{\"name\":\"node-1\"}'"))
                }
                params = object
            }
            return (name, params)
        default:
            return nil
        }
    }

    // MARK: - 调用

    /// 调用工具；Proxi 没在运行时在后台打开它，等控制接口起来再调。
    static func callLaunching(_ method: String, params: [String: Any], client: String) throws -> [String: Any] {
        do {
            return try ControlSocketClient.call(method, params: params, client: client)
        } catch let error as ControlError where error.code == JSONRPC.notRunning {
            guard launchApp() else { throw error }
            for _ in 0..<60 {
                Thread.sleep(forTimeInterval: 0.25)
                if FileManager.default.fileExists(atPath: UnixSocket.defaultPath) {
                    do {
                        return try ControlSocketClient.call(method, params: params, client: client)
                    } catch let retry as ControlError where retry.code == JSONRPC.notRunning {
                        continue
                    }
                }
            }
            throw error
        }
    }

    /// 在后台打开代理引擎（不抢焦点）。
    static func launchApp() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            process.arguments = ["-g", bundle.path]
        } else {
            process.arguments = ["-g", "-b", AppInfo.bundleIdentifier]
        }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - 输出

    static func printHuman(_ method: String, _ result: [String: Any]) {
        if let text = result["text"] as? String {
            print(text)
        }
        func rows(_ key: String) -> [[String: Any]] { (result[key] as? [[String: Any]]) ?? [] }
        switch method {
        case "list_nodes":
            for node in rows("nodes") {
                let delay = (node["delay"] as? Int).map { $0 > 0 ? "\($0) ms" : L("超时") } ?? ""
                let mark = (node["inUse"] as? Bool) == true ? "●" : ((node["favorite"] as? Bool) == true ? "★" : " ")
                print("\(mark) \(node["name"] ?? "")  \(delay)  \(node["source"] ?? "")")
            }
        case "list_groups":
            for group in rows("groups") {
                print(L("%@（%@）→ %@", group["name"] ?? "", group["type"] ?? "", group["now"] ?? ""))
            }
        case "list_rules":
            for rule in rows("customRules") {
                print("\((rule["enabled"] as? Bool) == false ? "○" : "●") [\(rule["type"] ?? "")] \(rule["value"] ?? "") → \(rule["policy"] ?? "")")
            }
            for set in rows("ruleSets") {
                print(L("%@ 规则集 %@ → %@", (set["enabled"] as? Bool) == false ? "○" : "●", set["name"] ?? "", set["policy"] ?? ""))
            }
            print(L("其余流量 → %@", result["final"] ?? ""))
        case "list_subscriptions":
            for sub in rows("subscriptions") {
                print(L("%@ %@  %@  %@", (sub["enabled"] as? Bool) == false ? "○" : "●", sub["name"] ?? "", sub["nodes"].map { L("%@ 个节点", $0) } ?? "", sub["usage"] ?? ""))
            }
            for node in rows("manualNodes") {
                print(L("  手动 %@  %@", node["name"] ?? "", node["server"] ?? ""))
            }
        case "list_connections":
            for connection in rows("active") {
                print("\(connection["target"] ?? "")  \(connection["source"] ?? "")  → \(connection["route"] ?? "")  \(connection["rule"] ?? "")")
            }
        case "test_nodes":
            for item in rows("delays").prefix(40) {
                let delay = (item["delay"] as? Int) ?? 0
                print(L("%@\t%@", delay > 0 ? "\(delay) ms" : L("超时"), item["name"] ?? ""))
            }
        case "check_url":
            for item in rows("results") {
                print(L("%@ %@：%@", (item["available"] as? Bool) == true ? "✓" : "✗", item["service"] ?? "", item["result"] ?? ""))
            }
        case "diagnose_url":
            for check in rows("checks") {
                print(L("· %@：%@", check["title"] ?? "", check["result"] ?? ""))
            }
        case "export_config":
            if let content = result["content"] as? String {
                print(content)
            }
        case "preview_import", "import_config":
            for line in (result["changes"] as? [String]) ?? [] {
                print("· \(line)")
            }
            for warning in (result["warnings"] as? [String]) ?? [] {
                print("! \(warning)")
            }
        case "list_changes":
            for change in rows("changes") {
                let undo = (change["undone"] as? Bool) == true ? L("（已撤销）") : ((change["canUndo"] as? Bool) == true ? L("（可撤销）") : "")
                print("\(change["date"] ?? "")  \(change["client"] ?? "")  \(change["summary"] ?? "")\(undo)")
            }
        case "get_logs":
            print((result["app"] as? String) ?? "")
            print(L("----- 内核 -----"))
            print((result["core"] as? String) ?? "")
        case "get_traffic":
            for item in rows("byNode").prefix(10) {
                print("\(item["name"] ?? "")  \(item["text"] ?? "")")
            }
        default:
            break
        }
    }

    static func printError(_ message: String) {
        FileHandle.standardError.write(Data((L("代理引擎：") + message + "\n").utf8))
    }

    static func readStandardInput() -> String {
        String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }

    static var help: String { AppLanguage.isEnglish ? helpEnglish : helpChinese }

    // l10n-ignore：中文界面的用法说明，英文的在 helpEnglish。
    static let helpChinese = """
    用法：<代理引擎程序> <命令> [参数] [--json]

    查看
      status                    代理引擎现在的状态
      nodes [关键词]            节点和延迟
      groups                    策略组
      rules                     分流规则
      subs                      订阅和手动节点
      connections [关键词]      连接
      traffic                   流量统计
      logs [行数]               日志
      history                   操作记录

    操作
      node <节点名|auto>        切换节点（名字可以只写一部分）
      group <组名> <成员>       切换策略组
      mode <rule|global>        切换模式
      test [关键词]             测速
      check <网址> [节点名]     经节点访问一个你指定的网址，看能不能打开
      diagnose <网址>           诊断网址为什么打不开
      share <on|off>            局域网共享
      tun <on|off>              增强模式（要先装特权助手）
      gateway <on|off>          网关模式（设备把路由器和 DNS 设成这台 Mac）
      close [连接 id]           断开连接（不写就断开全部）

    改配置（每次改动都可以 undo 撤销）
      rule add <内容> <去向> [--type 类型]    加规则，去向是 proxy、direct、reject 或策略组名
      rule remove <内容>
      final <去向|follow>                     其余流量
      sub add <地址> [名字] / sub remove <名字> / sub update
      add-nodes <链接...>                     加节点（不写链接就从标准输入读）
      ruleset add <网址|规则库名> [去向] / ruleset remove <名字> / ruleset update
      group-add <组名> [类型] [筛选] / group-remove <组名>
      import <文件|网址|-> [--replace] [--preview]
      export [describe|backup|core]
      undo

    其他
      tools                     全部工具
      call <工具> ['{"参数":"值"}']
      helper <install|uninstall|status>  特权助手（安装、卸载要 sudo）
      version

    代理引擎没在运行时会自动在后台打开。开关代理在 Proxi 里用「代理引擎」这个配置。
    """

    static let helpEnglish = """
    Usage: <engine app binary> <command> [arguments] [--json]

    View
      status                    Current engine status
      nodes [keyword]           Nodes and latency
      groups                    Policy groups
      rules                     Routing rules
      subs                      Subscriptions and manual nodes
      connections [keyword]     Connections
      traffic                   Traffic statistics
      logs [lines]              Logs
      history                   Change history

    Control
      node <name|auto>          Switch node (part of the name is enough)
      group <group> <member>    Switch a policy group
      mode <rule|global>        Switch mode
      test [keyword]            Test latency
      check <url> [node]        Open a URL of your choice through a node and see whether it loads
      diagnose <url>            Find out why a website won't open
      share <on|off>            LAN sharing
      tun <on|off>              Enhanced mode (install the privileged helper first)
      gateway <on|off>          Gateway mode (devices set their router and DNS to this Mac)
      close [connection id]     Close connections (all of them if no id is given)

    Change settings (every change can be reverted with undo)
      rule add <value> <target> [--type type]  Add a rule; target is proxy, direct, reject or a group name
      rule remove <value>
      final <target|follow>                    Everything else
      sub add <url> [name] / sub remove <name> / sub update
      add-nodes <links...>                     Add nodes (reads standard input when no links are given)
      ruleset add <url|library name> [target] / ruleset remove <name> / ruleset update
      group-add <name> [type] [filter] / group-remove <name>
      import <file|url|-> [--replace] [--preview]
      export [describe|backup|core]
      undo

    Other
      tools                     All tools
      call <tool> ['{"param":"value"}']
      helper <install|uninstall|status>  Privileged helper (install and uninstall need sudo)
      version

    The engine is opened in the background when it isn't running. Turn the proxy on in Proxi with the "Proxy Engine" profile.
    """
}
