import Foundation
import Security

/// 代理配置的密码存在这台 Mac 的登录钥匙串里：通用密码，服务是程序的标识，账户是配置的 id。
/// 用的是登录钥匙串（文件钥匙串），里面的项目不会经 iCloud 钥匙串同步（同步只针对另一种、标了可同步的项目，
/// 查询里写 kSecAttrSynchronizable 反而会转到那种钥匙串，没有开发者签名的程序用不了）；配置文件、iCloud 同步和导出里都只有「有没有密码」这个标记，
/// 别的 Mac 第一次开启这个配置时会请用户输入一次。
enum ProxyKeychain {
    static let service = "com.whrss9527.proxyswitch"

    private static func query(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    /// 读出密码；没有保存过返回 nil。allowUI 为 false 时不弹出系统的钥匙串对话框（命令行和 AI 助手调用时），读不到就算没有。
    static func password(for id: UUID, allowUI: Bool = true) -> String? {
        var request = query(id)
        request[kSecReturnData as String] = true
        // 登录钥匙串（文件钥匙串）的授权对话框只能用这个全局开关关掉，读完马上恢复。
        if !allowUI {
            _ = SecKeychainSetUserInteractionAllowed(false)
        }
        defer {
            if !allowUI { _ = SecKeychainSetUserInteractionAllowed(true) }
        }
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                Log.error("读钥匙串失败：\(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// 保存（已有的就更新）。
    static func set(_ password: String, for id: UUID) throws {
        let data = Data(password.utf8)
        let update = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError(status: update) }
        var item = query(id)
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = L("Proxi 代理密码")
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    static func delete(for id: UUID) {
        _ = SecItemDelete(query(id) as CFDictionary)
    }
}

struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        let detail = (SecCopyErrorMessageString(status, nil) as String?) ?? String(status)
        return L("钥匙串出错：%@", detail)
    }
}

/// 日志、诊断和报错里不能出现密码：网址里的「用户名:密码@」换成「用户名:***@」。
enum Redact {
    private static let userInfo = try! NSRegularExpression(pattern: "(://[^\\s:/@'\"]*):[^\\s@/'\"]*@")

    static func secrets(_ text: String) -> String {
        guard text.contains("@") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return userInfo.stringByReplacingMatches(in: text, range: range, withTemplate: "$1:***@")
    }

    /// 另外把知道的密码换成 ***：原样的（networksetup 的参数里就是原样的），以及写进网址、shell 单引号、AppleScript 字符串后的样子。
    /// 不到 3 个字的不换，免得把整段话换得看不懂。
    static func secrets(_ text: String, known: [String]) -> String {
        var result = text
        for secret in known where secret.count >= 3 {
            let shell = secret.replacingOccurrences(of: "'", with: "'\\''")
            let forms = Set([secret, Profile.escapeUserInfo(secret), shell, appleScriptEscaped(secret), appleScriptEscaped(shell)])
            // 长的先换：短的写法可能是长的一部分。
            for form in forms.sorted(by: { $0.count > $1.count }) {
                result = result.replacingOccurrences(of: form, with: "***")
            }
        }
        return secrets(result)
    }

    private static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
