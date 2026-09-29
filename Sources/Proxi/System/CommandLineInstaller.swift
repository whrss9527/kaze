import Foundation

/// 安装命令行工具：在 /usr/local/bin 放一个 proxi 脚本，转给程序里的可执行文件（程序更新后路径不变，一直能用）。
/// 改名前装的 proxyswitch 留着，也转给现在的程序，脚本和快捷指令里用着的照样能用。
enum CommandLineInstaller {
    static let path = "/usr/local/bin/proxi"
    /// 改名前的命令。
    static let legacyPath = "/usr/local/bin/proxyswitch"

    static var directory: String { (path as NSString).deletingLastPathComponent }

    /// 程序里的可执行文件。
    static var executablePath: String {
        Bundle.main.executablePath ?? "/Applications/Proxi.app/Contents/MacOS/Proxi"
    }

    static var script: String { script(for: executablePath) }

    static func script(for executable: String) -> String {
        "#!/bin/sh\n# Proxi 的命令行工具：proxi help 看用法。\nexec \(Shell.shellQuote(executable)) \"$@\"\n"
    }

    /// 是不是这个程序装的脚本（改名前装的也算）。别的程序的同名文件不碰。
    static func isOurScript(_ text: String) -> Bool {
        text.hasPrefix("#!/bin/sh") && text.contains("的命令行工具") && text.contains("/Contents/MacOS/")
    }

    /// 脚本转给的程序：exec 后面那个（单引号括起来的）路径。
    static func target(of text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("exec ") }) else { return nil }
        var result = ""
        var quoted = false
        var escaped = false
        for character in line.dropFirst(5) {
            if escaped {
                result.append(character)
                escaped = false
            } else if quoted {
                if character == "'" {
                    quoted = false
                } else {
                    result.append(character)
                }
            } else if character == "'" {
                quoted = true
            } else if character == "\\" {
                escaped = true
            } else if character == " " {
                break
            } else {
                result.append(character)
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func contents(_ file: String) -> String? {
        try? String(contentsOfFile: file, encoding: .utf8)
    }

    /// 已经装好、而且指向现在这个程序。
    static var isInstalled: Bool {
        contents(path)?.contains(executablePath) ?? false
    }

    /// 改名前装的 proxyswitch 还在，而且指向现在这个程序。
    static var legacyInstalled: Bool {
        contents(legacyPath)?.contains(executablePath) ?? false
    }

    /// 装过、但转给的程序已经不在了（比如改名前装的 proxyswitch 还指着 ProxySwitch.app）：要更新。
    static var needsUpdate: Bool {
        [path, legacyPath].contains { file in
            guard let text = contents(file), isOurScript(text), let target = target(of: text) else { return false }
            return target != executablePath && !FileManager.default.isExecutableFile(atPath: target)
        }
    }

    /// 要写的脚本：proxi，以及装过的 proxyswitch。
    private static func targets() throws -> [String] {
        var files = [path]
        if let text = contents(legacyPath), isOurScript(text) {
            files.append(legacyPath)
        }
        if let text = contents(path), !isOurScript(text) {
            throw ControlError.failed("\(path) 是别的程序的文件，没有覆盖")
        }
        return files
    }

    /// 装上（装过 proxyswitch 的一起改好）；/usr/local/bin 不能直接写时请求管理员权限。
    static func install() async throws {
        let files = try targets()
        if FileManager.default.isWritableFile(atPath: directory) {
            try write(files)
            return
        }
        let encoded = Data(script.utf8).base64EncodedString()
        let writes = files.map { "echo \(encoded) | /usr/bin/base64 -D > \(Shell.shellQuote($0)) && chmod 755 \(Shell.shellQuote($0))" }
        try await runAsAdmin("mkdir -p \(Shell.shellQuote(directory)) && " + writes.joined(separator: " && "))
    }

    private static func write(_ files: [String]) throws {
        for file in files {
            try script.write(toFile: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file)
        }
    }

    /// 启动时：装过的脚本转给的程序已经不在了（程序改了名），不用管理员密码就能改时直接改好；改不了的在「自动化」页提示。
    static func repairIfPossible() {
        guard needsUpdate, FileManager.default.isWritableFile(atPath: directory), let files = try? targets() else { return }
        do {
            try write(files)
            Log.info("命令行工具已改为转给 \(executablePath)")
        } catch {
            Log.error("命令行工具没能改好：\(error.localizedDescription)")
        }
    }

    /// 卸载 proxi，以及改名前装的 proxyswitch。
    static func uninstall() async throws {
        let files = [path, legacyPath].filter { contents($0).map(isOurScript) ?? false }
        guard !files.isEmpty else { return }
        do {
            for file in files {
                try FileManager.default.removeItem(atPath: file)
            }
        } catch {
            try await runAsAdmin("rm -f " + files.map(Shell.shellQuote).joined(separator: " "))
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
            "proxi": {
              "command": "\(executablePath)",
              "args": ["mcp"]
            }
          }
        }
        """
    }

    /// 用命令添加 MCP 服务器的客户端（比如 Claude Code）。
    static var mcpCommand: String {
        "claude mcp add proxi -- \(Shell.shellQuote(executablePath)) mcp"
    }
}
