import Foundation
import Security

/// 代理配置的密码存在这台 Mac 的钥匙串里：通用密码，服务是程序的标识，账户是配置的 id。
/// 不允许 iCloud 钥匙串同步；配置文件、iCloud 同步和导出里都只有「有没有密码」这个标记，
/// 别的 Mac 第一次开启这个配置时会请用户输入一次。
enum ProxyKeychain {
    static let service = "com.whrss9527.proxyswitch"

    private static func query(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecAttrSynchronizable as String: false,
        ]
    }

    /// 读出密码；没有保存过返回 nil。
    static func password(for id: UUID) -> String? {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
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
}
