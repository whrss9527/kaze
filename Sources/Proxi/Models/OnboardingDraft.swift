import Foundation

/// 新手引导里填的内容，拼成第一套代理配置。
struct OnboardingDraft: Equatable {
    var kind: ProxyKind = .http
    /// 「主机:端口」，或者整段地址（socks5://user:pass@host:port）；PAC 时是 PAC 地址。
    var address = ""
    /// 空着时按地址起名（见 suggestedName）。
    var name = ""
    var username = ""
    var password = ""
    var targets: Set<ProxyTarget> = Set(ProxyTarget.allCases)

    struct Problem: LocalizedError, Equatable {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// 粘贴或者自动检测来的整段地址：带了类型就跟着换，带了用户名和密码就填到登录里。
    mutating func absorbAddress() {
        guard kind != .pac, let parsed = ProxyAddress.parse(address) else { return }
        if let parsedKind = parsed.kind {
            kind = parsedKind
        }
        if !parsed.username.isEmpty {
            username = parsed.username
            if let parsedPassword = parsed.password {
                password = parsedPassword
            }
        }
    }

    /// 拼出来的配置，和要存进钥匙串的密码（不用登录时是空的）；填得不对时抛出说明。
    func build(color: String, existingNames: [String]) throws -> (profile: Profile, password: String) {
        var profile = Profile(name: "", color: color, kind: kind)
        var user = username.trimmingCharacters(in: .whitespaces)
        var secret = password
        switch kind {
        case .pac:
            profile.pacURL = address.trimmingCharacters(in: .whitespacesAndNewlines)
            profile.targets = [.system]
            user = ""
        case .http, .socks5:
            guard let parsed = ProxyAddress.parse(address) else {
                throw Problem(L("请填写代理服务器的地址，比如 proxy.corp.example:3128"))
            }
            guard let port = parsed.port else {
                throw Problem(L("地址里要带端口，比如 %@:3128", parsed.host))
            }
            if let parsedKind = parsed.kind {
                profile.kind = parsedKind
            }
            profile.host = parsed.host
            profile.port = port
            if !parsed.username.isEmpty {
                user = parsed.username
                if let parsedPassword = parsed.password {
                    secret = parsedPassword
                }
            }
            profile.targets = targets
        }
        profile.username = user
        if user.isEmpty {
            secret = ""
        }
        let typed = name.trimmingCharacters(in: .whitespaces)
        profile.name = Self.unique(typed.isEmpty ? Self.suggestedName(for: profile) : typed, existingNames)
        if let problem = profile.validate() {
            throw Problem(problem)
        }
        return (profile, secret)
    }

    /// 没写名称时的名字：本机的代理叫「本机代理 端口」，别的用主机名；PAC 用网址里的主机名。
    static func suggestedName(for profile: Profile) -> String {
        switch profile.kind {
        case .pac:
            return URL(string: profile.pacURL)?.host ?? L("PAC 脚本")
        case .http, .socks5:
            if ["127.0.0.1", "localhost", "::1"].contains(profile.host.lowercased()) {
                return L("本机代理 %@", profile.port)
            }
            return profile.host
        }
    }

    /// 和已有的配置重名时在后面加上 2、3……
    static func unique(_ base: String, _ existingNames: [String]) -> String {
        var name = base
        var index = 1
        while existingNames.contains(name) {
            index += 1
            name = "\(base) \(index)"
        }
        return name
    }
}
