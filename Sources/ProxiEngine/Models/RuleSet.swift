import Foundation

/// 规则列表的类型，对应内核 rule-provider 的 behavior。
enum RuleSetBehavior: String, Codable, CaseIterable, Identifiable {
    /// 每行一条完整规则：DOMAIN-SUFFIX,x、IP-CIDR,y,no-resolve……
    case classical
    /// 只有域名：+.example.com、example.org。
    case domain
    /// 只有 IP 段。
    case ipcidr

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classical: return L("完整规则")
        case .domain: return L("域名列表")
        case .ipcidr: return L("IP 段列表")
        }
    }
}

/// 一个分流规则集：一个远程（或本机、内置）的规则列表，加上它的去向。
///
/// 三种加载方式：内置的不用下载；`.list` / `.txt` / `.yaml` / `.mrs` 这类纯规则列表下载后交给内核的 rule-provider；
/// 小火箭 / Surge 的完整配置（`.conf` 等）由本程序转换后内联进规则里。
struct RuleSet: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String = L("规则")
    /// http(s) 地址、本机的 file:// 文件，或者内置的 builtin://china-direct。
    var url: String = ""
    /// 去向；nil 表示按规则文件里自己写的策略（只对小火箭 / Surge 完整配置有意义，纯列表按走节点算）。
    var policy: RuleTarget?
    var enabled: Bool = true
    /// 规则列表的类型，下载时从内容检测；nil 时按地址猜。
    var behavior: RuleSetBehavior?
    /// 下载时发现它其实是完整配置（Clash 的 rules: 或者小火箭的 [Rule] 段），要转换后并入；nil 表示还没检测过。
    var converted: Bool?

    init(name: String, url: String, policy: RuleTarget?, behavior: RuleSetBehavior? = nil) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        self.policy = policy
        self.behavior = behavior
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, url, policy, enabled, behavior, converted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? L("规则")
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        policy = try container.decodeIfPresent(RuleTarget.self, forKey: .policy)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        behavior = try container.decodeIfPresent(RuleSetBehavior.self, forKey: .behavior)
        converted = try container.decodeIfPresent(Bool.self, forKey: .converted)
        if url == Self.chinaDirectURL, Self.legacyBuiltinNames.contains(name) {
            name = L("智能分流")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encodeIfPresent(policy, forKey: .policy)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(behavior, forKey: .behavior)
        try container.encodeIfPresent(converted, forKey: .converted)
    }

    // MARK: - 内置

    static let builtinScheme = "builtin://"
    static let chinaDirectURL = "builtin://china-direct"
    /// 内置规则集用固定的 id：默认配置里就有它，两台 Mac 上也是同一条。
    static let chinaDirectID = UUID(uuidString: "0B1E6C7A-0000-4000-8000-00000000C0DE")!

    /// 内置的规则集以前版本用过的默认名字（中文界面和英文界面的）：读旧配置时换成现在的名字，用户自己改过的不动。
    static let legacyBuiltinNames: Set<String> = ["国内直连", "China Direct"] // l10n-ignore

    /// 内置的「智能分流」：.cn 域名和 GEOIP 为 CN 的地址，默认直连（以前版本的默认规则，旧配置里还有；新配置不再默认加）。
    static func chinaDirect() -> RuleSet {
        var set = RuleSet(name: L("智能分流"), url: chinaDirectURL, policy: .direct)
        set.id = chinaDirectID
        return set
    }

    /// 旧版的单一规则来源变成规则集：内置的还是内置的；规则地址按文件自己的策略走，FINAL 也跟着文件。
    static func migrated(from source: RuleSource) -> [RuleSet] {
        switch source {
        case .chinaDirect:
            return [chinaDirect()]
        case .url(let url):
            return [RuleSet(name: RulePresets.preset(for: url)?.name ?? defaultName(for: url), url: url, policy: nil)]
        }
    }

    /// 没填名字时用地址里的文件名，没有文件名就用主机名。
    static func defaultName(for url: String) -> String {
        if let entry = RuleLibrary.entry(for: url) { return entry.name }
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return L("规则") }
        let file = parsed.deletingPathExtension().lastPathComponent
        if !file.isEmpty, file != "/", !parsed.path.isEmpty, parsed.path != "/" {
            return file
        }
        return parsed.host ?? L("规则")
    }

    // MARK: - 种类

    enum Kind: Equatable {
        /// 内置，直接生成规则。
        case builtin
        /// 下载后由本程序转换、内联进 rules（小火箭 / Surge 完整配置，或者认不出类型的地址）。
        case inline
        /// 下载后交给内核的 rule-provider 加载（纯规则列表）。
        case provider
    }

    static let providerExtensions: Set<String> = ["list", "txt", "text", "yaml", "yml", "mrs"]

    var isBuiltin: Bool { url.lowercased().hasPrefix(Self.builtinScheme) }

    /// 内核配置里 rule-provider 的名字，只用 ASCII。
    var providerName: String { "rs-" + id.uuidString.prefix(8).lowercased() }

    /// 地址里的文件扩展名（不含查询参数），小写。
    var fileExtension: String {
        let path = URL(string: url)?.path ?? url
        return (path as NSString).pathExtension.lowercased()
    }

    var kind: Kind {
        if isBuiltin { return .builtin }
        if converted == true { return .inline }
        return Self.providerExtensions.contains(fileExtension) ? .provider : .inline
    }

    /// 内核 rule-provider 的 format。
    var format: String {
        switch fileExtension {
        case "yaml", "yml": return "yaml"
        case "mrs": return "mrs"
        default: return "text"
        }
    }

    /// 存在内核目录里时用的后缀。
    var storedExtension: String {
        switch fileExtension {
        case "yaml", "yml": return "yaml"
        case "mrs": return "mrs"
        case "conf": return "conf"
        default: return "txt"
        }
    }

    /// 没检测过时按地址猜：带 geoip / ip 字样的是 IP 段；.mrs 只可能是域名或 IP 段；geosite、domain 字样的是域名；其余当完整规则。
    var guessedBehavior: RuleSetBehavior {
        let lowered = url.lowercased()
        let ipHints = ["geoip", "ipcidr", "ip-cidr", "_ip.", "/ip.", "-ip.", "cnip", "chinaip", "china_ip", "china-ip"]
        if ipHints.contains(where: { lowered.contains($0) }) { return .ipcidr }
        if fileExtension == "mrs" { return .domain }
        if ["geosite", "_domain", "-domain", "/domain."].contains(where: { lowered.contains($0) }) { return .domain }
        return .classical
    }

    var effectiveBehavior: RuleSetBehavior { behavior ?? guessedBehavior }

    /// 本机文件的路径（file:// 地址）。
    var filePath: String? {
        guard let parsed = URL(string: url), parsed.scheme?.lowercased() == "file" else { return nil }
        return parsed.path
    }

    /// 校验地址，返回问题；没问题返回 nil。
    static func validate(url text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix(builtinScheme) {
            return trimmed == chinaDirectURL ? nil : L("没有这个内置规则")
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return L("规则地址要以 http:// 或 https:// 开头")
        }
        if scheme == "file" {
            return url.path.isEmpty ? L("文件地址不对") : nil
        }
        guard ["http", "https"].contains(scheme), url.host != nil else {
            return L("规则地址要以 http:// 或 https:// 开头")
        }
        return nil
    }
}

/// 以前版本内置的完整配置预设。现在不再内置，只保留查找的接口（旧配置里的名字照常显示）。
enum RulePresets {
    struct Preset: Identifiable, Equatable {
        let name: String
        let url: String
        let detail: String

        var id: String { url }
    }

    static let all: [Preset] = []

    static func preset(for url: String) -> Preset? {
        all.first { $0.url == url }
    }
}

/// 规则库里的一条：常用的公开规则列表，一键加进规则集。
struct RuleLibraryEntry: Identifiable, Equatable {
    var name: String
    var detail: String
    var url: String
    /// 默认去向；nil 表示按文件自己的策略。
    var policy: RuleTarget?
    var behavior: RuleSetBehavior?
    var category: String

    var id: String { url }

    func makeRuleSet() -> RuleSet {
        if url == RuleSet.chinaDirectURL { return RuleSet.chinaDirect() }
        return RuleSet(name: name, url: url, policy: policy, behavior: behavior)
    }
}

/// 规则库：一些通用的公开规则列表，一键加进规则集。其余的规则列表自己填网址添加。
/// 地址用 GitHub 的原始地址，下载时连不上会自动换 jsDelivr 镜像。
enum RuleLibrary {
    static let metaGeo = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/"
    static let acl4ssr = "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/"

    static let ads = L("去广告")

    static let all: [RuleLibraryEntry] = [
        RuleLibraryEntry(name: L("广告与跟踪"), detail: L("geosite:category-ads-all，体积小、够用"), url: metaGeo + "geosite/category-ads-all.mrs", policy: .reject, behavior: .domain, category: ads),
        RuleLibraryEntry(name: L("广告（ACL4SSR）"), detail: L("常见广告域名"), url: acl4ssr + "BanAD.list", policy: .reject, behavior: .classical, category: ads),
        RuleLibraryEntry(name: L("应用内广告（ACL4SSR）"), detail: L("程序和应用里的广告、统计上报"), url: acl4ssr + "BanProgramAD.list", policy: .reject, behavior: .classical, category: ads),
    ]

    /// 分类，按出现顺序。
    static var categories: [String] {
        var seen = Set<String>()
        return all.map(\.category).filter { seen.insert($0).inserted }
    }

    static func entries(in category: String) -> [RuleLibraryEntry] {
        all.filter { $0.category == category }
    }

    static func entry(for url: String) -> RuleLibraryEntry? {
        all.first { $0.url == url }
    }

    /// 按名字找（不区分大小写），导入配置和 AI 助手按名字添加时用。
    static func entry(named name: String) -> RuleLibraryEntry? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return all.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
            ?? all.first { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }
}
