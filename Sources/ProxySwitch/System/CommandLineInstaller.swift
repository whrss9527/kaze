import Foundation

/// 安装命令行工具：在 /usr/local/bin 放一个 proxyswitch 脚本，转给程序里的可执行文件（程序更新后路径不变，一直能用）。
enum CommandLineInstaller {
    static let path = "/usr/local/bin/proxyswitch"

    /// 程序里的可执行文件。
    static var executablePath: String {
        Bundle.main.executablePath ?? "/Applications/ProxySwitch.app/Contents/MacOS/ProxySwitch"
    }

    static var script: String {
        "#!/bin/sh\n# ProxySwitch 的命令行工具：proxyswitch help 看用法。\nexec \(Shell.shellQuote(executablePath)) \"$@\"\n"
    }

    /// 已经装好、而且指向现在这个程序。
    static var isInstalled: Bool {
        (try? String(contentsOfFile: path, encoding: .utf8))?.contains(executablePath) ?? false
    }

    /// 装上；/usr/local/bin 不能直接写时请求管理员权限。
    static func install() async throws {
        let directory = (path as NSString).deletingLastPathComponent
        if FileManager.default.isWritableFile(atPath: directory) {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return
        }
        let encoded = Data(script.utf8).base64EncodedString()
        let command = "mkdir -p \(Shell.shellQuote(directory)) && echo \(encoded) | /usr/bin/base64 -D > \(Shell.shellQuote(path)) && chmod 755 \(Shell.shellQuote(path))"
        try await runAsAdmin(command)
    }

    static func uninstall() async throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            try await runAsAdmin("rm -f \(Shell.shellQuote(path))")
        }
    }

    /// 请求管理员权限运行一条 shell 命令（系统会弹出输入密码的窗口）。
    static func runAsAdmin(_ command: String, failure: String = "没有装上") async throws {
        let script = "do shell script \(Shell.appleScriptString(command)) with administrator privileges"
        let result = try await Shell.run("/usr/bin/osascript", ["-e", script], timeout: 180)
        guard result.succeeded else {
            let output = result.trimmedOutput
            throw ControlError.failed(output.contains("-128") ? "取消了" : "\(failure)：\(output)")
        }
    }

    /// 给 AI 助手（MCP 客户端）的配置。
    static var mcpConfig: String {
        """
        {
          "mcpServers": {
            "proxyswitch": {
              "command": "\(executablePath)",
              "args": ["mcp"]
            }
          }
        }
        """
    }

    /// 用命令添加 MCP 服务器的客户端（比如 Claude Code）。
    static var mcpCommand: String {
        "claude mcp add proxyswitch -- \(Shell.shellQuote(executablePath)) mcp"
    }
}
