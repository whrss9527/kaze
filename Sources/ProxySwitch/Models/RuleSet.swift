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
        case .classical: return "完整规则"
        case .domain: return "域名列表"
        case .ipcidr: return "IP 段列表"
        }
    }
}

/// 一个分流规则集：一个远程（或本机、内置）的规则列表，加上它的去向。
///
/// 三种加载方式：内置的不用下载；`.list` / `.txt` / `.yaml` / `.mrs` 这类纯规则列表下载后交给内核的 rule-provider；
/// 小火箭 / Surge 的完整配置（`.conf` 等）由本程序转换后内联进规则里。
struct RuleSet: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String = "规则"
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
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "规则"
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        policy = try container.decodeIfPresent(RuleTarget.self, forKey: .policy)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        behavior = try container.decodeIfPresent(RuleSetBehavior.self, forKey: .behavior)
        converted = try container.decodeIfPresent(Bool.self, forKey: .converted)
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

    /// 内置：.cn 域名和国内 IP 直连（GEOIP 数据打包在程序里，不用下载）。
    static func chinaDirect() -> RuleSet {
        var set = RuleSet(name: "国内直连", url: chinaDirectURL, policy: .direct)
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
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return "规则" }
        let file = parsed.deletingPathExtension().lastPathComponent
        if !file.isEmpty, file != "/", !parsed.path.isEmpty, parsed.path != "/" {
            return file
        }
        return parsed.host ?? "规则"
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
            return trimmed == chinaDirectURL ? nil : "没有这个内置规则"
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return "规则地址要以 http:// 或 https:// 开头"
        }
        if scheme == "file" {
            return url.path.isEmpty ? "文件地址不对" : nil
        }
        guard ["http", "https"].contains(scheme), url.host != nil else {
            return "规则地址要以 http:// 或 https:// 开头"
        }
        return nil
    }
}

/// 常用的小火箭分流规则（johnshall/Shadowrocket-ADBlock-Rules-Forever）：完整配置，带自己的 FINAL。
enum RulePresets {
    struct Preset: Identifiable, Equatable {
        let name: String
        let file: String
        let detail: String

        var id: String { file }
        var url: String { RulePresets.base + file }
    }

    static let base = "https://raw.githubusercontent.com/johnshall/Shadowrocket-ADBlock-Rules-Forever/master/"

    static let all: [Preset] = [
        Preset(name: "黑名单", file: "sr_top500_banlist.conf", detail: "被墙的常用网站走节点，其余直连"),
        Preset(name: "黑名单 + 去广告", file: "sr_top500_banlist_ad.conf", detail: "黑名单，外加拦截广告和跟踪"),
        Preset(name: "白名单", file: "sr_top500_whitelist.conf", detail: "国内常用网站和国内 IP 直连，其余走节点"),
        Preset(name: "白名单 + 去广告", file: "sr_top500_whitelist_ad.conf", detail: "白名单，外加拦截广告和跟踪"),
        Preset(name: "国内 IP 直连", file: "sr_cnip.conf", detail: "只按 IP 归属分流：国内直连，国外走节点"),
        Preset(name: "国内 IP 直连 + 去广告", file: "sr_cnip_ad.conf", detail: "按 IP 归属分流，外加拦截广告"),
        Preset(name: "全部直连 + 去广告", file: "sr_direct_banad.conf", detail: "不走节点，只拦广告"),
        Preset(name: "全部走节点 + 去广告", file: "sr_proxy_banad.conf", detail: "全部走节点，外加拦截广告"),
    ]

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

/// 规则库：收录 blackmatrix7、MetaCubeX、ACL4SSR 和 johnshall 维护的常用规则，一键加进规则集。
/// 地址用 GitHub 的原始地址，下载时国内连不上会自动换 jsDelivr 镜像。
enum RuleLibrary {
    static let blackmatrix = "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/"
    static let metaGeo = "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/"
    static let acl4ssr = "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/"

    static let basics = "基础"
    static let ads = "去广告"
    static let services = "境外服务"
    static let ai = "AI"
    static let streaming = "流媒体"
    static let social = "社交与游戏"
    static let shadowrocket = "小火箭完整配置"

    static let all: [RuleLibraryEntry] = curated + RulePresets.all.map { preset in
        RuleLibraryEntry(name: preset.name, detail: preset.detail + "。完整配置，规则的去向和 FINAL 都按文件里写的", url: preset.url, policy: nil, behavior: nil, category: shadowrocket)
    }

    static let curated: [RuleLibraryEntry] = [
        RuleLibraryEntry(name: "国内直连", detail: ".cn 域名和国内 IP 直连，内置，不用下载", url: RuleSet.chinaDirectURL, policy: .direct, behavior: nil, category: basics),
        RuleLibraryEntry(name: "国内域名", detail: "MetaCubeX 整理的国内域名（geosite:cn），比按 .cn 后缀判断全得多", url: metaGeo + "geosite/cn.mrs", policy: .direct, behavior: .domain, category: basics),
        RuleLibraryEntry(name: "被墙网站", detail: "已知被屏蔽的网站（geosite:gfw）", url: metaGeo + "geosite/gfw.mrs", policy: .proxy, behavior: .domain, category: basics),
        RuleLibraryEntry(name: "境外常用网站", detail: "geosite:geolocation-!cn，国外常用网站都走节点", url: metaGeo + "geosite/geolocation-!cn.mrs", policy: .proxy, behavior: .domain, category: basics),
        RuleLibraryEntry(name: "广告与跟踪", detail: "geosite:category-ads-all，体积小、够用", url: metaGeo + "geosite/category-ads-all.mrs", policy: .reject, behavior: .domain, category: ads),
        RuleLibraryEntry(name: "广告（ACL4SSR）", detail: "常见广告域名", url: acl4ssr + "BanAD.list", policy: .reject, behavior: .classical, category: ads),
        RuleLibraryEntry(name: "应用内广告（ACL4SSR）", detail: "程序和应用里的广告、统计上报", url: acl4ssr + "BanProgramAD.list", policy: .reject, behavior: .classical, category: ads),
        RuleLibraryEntry(name: "Apple", detail: "苹果的服务，一般直连更快", url: blackmatrix + "Apple/Apple.list", policy: .direct, behavior: .classical, category: services),
        RuleLibraryEntry(name: "Microsoft", detail: "微软的服务", url: blackmatrix + "Microsoft/Microsoft.list", policy: .direct, behavior: .classical, category: services),
        RuleLibraryEntry(name: "Google", detail: "Google 全家", url: blackmatrix + "Google/Google.list", policy: .proxy, behavior: .classical, category: services),
        RuleLibraryEntry(name: "GitHub", detail: "GitHub 及其静态资源", url: blackmatrix + "GitHub/GitHub.list", policy: .proxy, behavior: .classical, category: services),
        RuleLibraryEntry(name: "Telegram", detail: "Telegram 的域名和 IP 段", url: blackmatrix + "Telegram/Telegram.list", policy: .proxy, behavior: .classical, category: social),
        RuleLibraryEntry(name: "Twitter / X", detail: "", url: blackmatrix + "Twitter/Twitter.list", policy: .proxy, behavior: .classical, category: social),
        RuleLibraryEntry(name: "PayPal", detail: "", url: blackmatrix + "PayPal/PayPal.list", policy: .proxy, behavior: .classical, category: services),
        RuleLibraryEntry(name: "OpenAI / ChatGPT", detail: "", url: blackmatrix + "OpenAI/OpenAI.list", policy: .proxy, behavior: .classical, category: ai),
        RuleLibraryEntry(name: "Claude", detail: "", url: blackmatrix + "Claude/Claude.list", policy: .proxy, behavior: .classical, category: ai),
        RuleLibraryEntry(name: "Gemini", detail: "", url: blackmatrix + "Gemini/Gemini.list", policy: .proxy, behavior: .classical, category: ai),
        RuleLibraryEntry(name: "YouTube", detail: "", url: blackmatrix + "YouTube/YouTube.list", policy: .proxy, behavior: .classical, category: streaming),
        RuleLibraryEntry(name: "Netflix", detail: "", url: blackmatrix + "Netflix/Netflix.list", policy: .proxy, behavior: .classical, category: streaming),
        RuleLibraryEntry(name: "Disney+", detail: "", url: blackmatrix + "Disney/Disney.list", policy: .proxy, behavior: .classical, category: streaming),
        RuleLibraryEntry(name: "Spotify", detail: "", url: blackmatrix + "Spotify/Spotify.list", policy: .proxy, behavior: .classical, category: streaming),
        RuleLibraryEntry(name: "TikTok", detail: "", url: blackmatrix + "TikTok/TikTok.list", policy: .proxy, behavior: .classical, category: streaming),
        RuleLibraryEntry(name: "哔哩哔哩", detail: "国内直连", url: blackmatrix + "BiliBili/BiliBili.list", policy: .direct, behavior: .classical, category: streaming),
        RuleLibraryEntry(name: "Steam", detail: "商店和下载，一般直连", url: blackmatrix + "Steam/Steam.list", policy: .direct, behavior: .classical, category: social),
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
}
