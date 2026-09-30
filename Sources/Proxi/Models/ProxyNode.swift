import Foundation

/// 内置代理里的一个节点（从内核读到的）。
struct ProxyNode: Identifiable, Equatable, Hashable {
    var name: String
    var type: String
    /// nil 没测过；0 测试失败。
    var delay: Int?
    /// 来源的名字：订阅名，或者「手动节点」。
    var subscription: String
    /// 来源：订阅的 id，手动节点是 ManualNode.sourceID。
    var source: UUID?
    /// 内核里的节点来源名（sub-xxxx、manual）。
    var provider: String = ""

    var id: String { name }

    var delayText: String {
        guard let delay else { return "" }
        return delay > 0 ? "\(delay) ms" : L("超时")
    }

    /// 从名字认出来的地区。
    var region: NodeRegion? { NodeRegion.detect(name) }

    /// 协议的显示名：ss → SS、vmess → VMess……
    var typeTitle: String { NodeQuery.typeTitle(type) }
}

/// 节点所在的地区：从节点名里的国旗、中文名、英文名和两个字母的代码认出来。
struct NodeRegion: Identifiable, Hashable {
    /// 两个字母的代码，比如 HK。
    let code: String
    let name: String
    /// 匹配节点名的正则（不区分大小写），也用来按地区建策略组。
    let pattern: String

    var id: String { code }

    var flag: String {
        var flag = ""
        for scalar in code.uppercased().unicodeScalars {
            guard let indicator = UnicodeScalar(0x1F1E6 + scalar.value - 65) else { return "" }
            flag.unicodeScalars.append(indicator)
        }
        return flag
    }

    var title: String { "\(flag) \(name)" }

    /// 两个字母的代码前后不能挨着字母（RUSSIA 里的 US 不算）。
    private static func code(_ letters: String) -> String { "(?<![A-Za-z])\(letters)(?![A-Za-z])" }

    private static func make(_ code: String, _ name: String, _ words: [String], codes: [String]) -> NodeRegion {
        let flag = NodeRegion(code: code, name: name, pattern: "").flag
        let parts = [flag] + words + codes.map(Self.code)
        return NodeRegion(code: code, name: name, pattern: parts.joined(separator: "|"))
    }

    /// 常见的地区；顺序就是认的顺序。
    static let all: [NodeRegion] = [
        make("HK", L("香港"), ["香港", "Hong ?Kong", "港"], codes: ["HK", "HKG"]),  // l10n-ignore：匹配节点名的关键词
        make("MO", L("澳门"), ["澳门", "澳門", "Macao", "Macau"], codes: ["MO"]),  // l10n-ignore：匹配节点名的关键词
        make("TW", L("台湾"), ["台湾", "臺灣", "台北", "新北", "彰化", "Taiwan"], codes: ["TW", "TWN"]),  // l10n-ignore：匹配节点名的关键词
        make("JP", L("日本"), ["日本", "东京", "東京", "大阪", "埼玉", "Japan", "Tokyo", "Osaka"], codes: ["JP", "JPN"]),  // l10n-ignore：匹配节点名的关键词
        make("KR", L("韩国"), ["韩国", "韓國", "首尔", "首爾", "春川", "Korea", "Seoul"], codes: ["KR", "KOR"]),  // l10n-ignore：匹配节点名的关键词
        make("SG", L("新加坡"), ["新加坡", "狮城", "獅城", "Singapore"], codes: ["SG", "SGP"]),  // l10n-ignore：匹配节点名的关键词
        make("US", L("美国"), ["美国", "美國", "美西", "美东", "洛杉矶", "硅谷", "圣何塞", "纽约", "西雅图", "芝加哥", "达拉斯", "凤凰城", "United States", "America", "Los Angeles", "San Jose", "Seattle"], codes: ["US", "USA"]),  // l10n-ignore：匹配节点名的关键词
        make("CA", L("加拿大"), ["加拿大", "多伦多", "温哥华", "Canada", "Toronto"], codes: ["CA", "CAN"]),  // l10n-ignore：匹配节点名的关键词
        make("GB", L("英国"), ["英国", "英國", "伦敦", "倫敦", "United Kingdom", "Britain", "England", "London"], codes: ["UK", "GB", "GBR"]),  // l10n-ignore：匹配节点名的关键词
        make("DE", L("德国"), ["德国", "德國", "法兰克福", "Germany", "Frankfurt"], codes: ["DE", "DEU"]),  // l10n-ignore：匹配节点名的关键词
        make("FR", L("法国"), ["法国", "法國", "巴黎", "France", "Paris"], codes: ["FR", "FRA"]),  // l10n-ignore：匹配节点名的关键词
        make("NL", L("荷兰"), ["荷兰", "荷蘭", "阿姆斯特丹", "Netherlands", "Amsterdam"], codes: ["NL", "NLD"]),  // l10n-ignore：匹配节点名的关键词
        make("RU", L("俄罗斯"), ["俄罗斯", "俄羅斯", "莫斯科", "Russia", "Moscow"], codes: ["RU", "RUS"]),  // l10n-ignore：匹配节点名的关键词
        make("TR", L("土耳其"), ["土耳其", "伊斯坦布尔", "Turkey", "Türkiye", "Istanbul"], codes: ["TR", "TUR"]),  // l10n-ignore：匹配节点名的关键词
        make("IN", L("印度"), ["印度", "孟买", "India", "Mumbai"], codes: ["IN", "IND"]),  // l10n-ignore：匹配节点名的关键词
        make("AU", L("澳大利亚"), ["澳大利亚", "澳洲", "悉尼", "墨尔本", "Australia", "Sydney"], codes: ["AU", "AUS"]),  // l10n-ignore：匹配节点名的关键词
        make("MY", L("马来西亚"), ["马来西亚", "馬來西亞", "吉隆坡", "Malaysia"], codes: ["MY", "MYS"]),  // l10n-ignore：匹配节点名的关键词
        make("TH", L("泰国"), ["泰国", "泰國", "曼谷", "Thailand", "Bangkok"], codes: ["TH", "THA"]),  // l10n-ignore：匹配节点名的关键词
        make("VN", L("越南"), ["越南", "胡志明", "Vietnam", "Viet Nam"], codes: ["VN", "VNM"]),  // l10n-ignore：匹配节点名的关键词
        make("PH", L("菲律宾"), ["菲律宾", "菲律賓", "马尼拉", "Philippines", "Manila"], codes: ["PH", "PHL"]),  // l10n-ignore：匹配节点名的关键词
        make("ID", L("印尼"), ["印尼", "印度尼西亚", "雅加达", "Indonesia", "Jakarta"], codes: ["IDN"]),  // l10n-ignore：匹配节点名的关键词
        make("AR", L("阿根廷"), ["阿根廷", "Argentina"], codes: ["AR", "ARG"]),  // l10n-ignore：匹配节点名的关键词
        make("BR", L("巴西"), ["巴西", "Brazil", "São Paulo"], codes: ["BR", "BRA"]),  // l10n-ignore：匹配节点名的关键词
    ]

    private static let expressions: [(NodeRegion, NSRegularExpression)] = all.compactMap { region in
        (try? NSRegularExpression(pattern: region.pattern, options: [.caseInsensitive])).map { (region, $0) }
    }

    static func detect(_ name: String) -> NodeRegion? {
        let range = NSRange(name.startIndex..., in: name)
        return expressions.first { $0.1.firstMatch(in: name, range: range) != nil }?.0
    }

    static func named(_ code: String) -> NodeRegion? {
        all.first { $0.code.caseInsensitiveCompare(code) == .orderedSame }
    }
}

/// 节点列表的条件：来源、地区、协议、只看能用的、只看收藏的、关键词和排序。收藏的节点总在最前面。
struct NodeQuery: Equatable {
    /// 「其他地区」：认不出地区的节点。
    static let otherRegion = "other"

    var text: String = ""
    /// 只看某个来源（订阅的 id，手动节点是 ManualNode.sourceID）。
    var source: UUID?
    /// 只看某个地区（代码），或者 otherRegion。
    var region: String?
    /// 只看某种协议（小写）。
    var type: String?
    /// 只看测过且能通的。
    var onlyAvailable = false
    /// 只看收藏的。
    var onlyFavorites = false
    var sort: NodeSort = .original

    init(sort: NodeSort = .original) {
        self.sort = sort
    }

    /// 有没有设了会筛掉节点的条件（排序不算）。
    var isFiltering: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || source != nil || region != nil || type != nil || onlyAvailable || onlyFavorites
    }

    mutating func reset() {
        let sort = self.sort
        self = NodeQuery(sort: sort)
    }

    /// 筛选再排序。
    func apply(_ nodes: [ProxyNode], favorites: [String]) -> [ProxyNode] {
        let favoriteSet = Set(favorites)
        let keyword = text.trimmingCharacters(in: .whitespaces)
        let filtered = nodes.filter { node in
            if !keyword.isEmpty && !node.name.localizedCaseInsensitiveContains(keyword) && !node.subscription.localizedCaseInsensitiveContains(keyword) { return false }
            if let source, node.source != source { return false }
            if let type, node.type.lowercased() != type { return false }
            if onlyAvailable && (node.delay ?? 0) <= 0 { return false }
            if onlyFavorites && !favoriteSet.contains(node.name) { return false }
            if let region {
                let detected = node.region?.code
                if region == NodeQuery.otherRegion ? detected != nil : detected != region { return false }
            }
            return true
        }
        return NodeQuery.sort(filtered, by: sort, favorites: favoriteSet)
    }

    static func sort(_ nodes: [ProxyNode], by sort: NodeSort, favorites: Set<String>) -> [ProxyNode] {
        let indexed = Array(nodes.enumerated())
        return indexed.sorted { lhs, rhs in
            let leftFavorite = favorites.contains(lhs.element.name)
            let rightFavorite = favorites.contains(rhs.element.name)
            if leftFavorite != rightFavorite { return leftFavorite }
            switch sort {
            case .original:
                break
            case .name:
                let order = lhs.element.name.localizedStandardCompare(rhs.element.name)
                if order != .orderedSame { return order == .orderedAscending }
            case .delay:
                // 能通的按延迟从低到高，超时的在后面，没测过的最后。
                let left = rank(lhs.element.delay)
                let right = rank(rhs.element.delay)
                if left != right { return left < right }
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func rank(_ delay: Int?) -> Int {
        guard let delay else { return Int.max }
        return delay > 0 ? delay : Int.max - 1
    }

    /// 一个地区和它的节点数；region 为 nil 是认不出地区的。
    struct RegionCount: Identifiable, Equatable {
        var region: NodeRegion?
        var count: Int

        var id: String { region?.code ?? NodeQuery.otherRegion }
    }

    /// 一种协议和它的节点数。
    struct TypeCount: Identifiable, Equatable {
        var type: String
        var count: Int

        var id: String { type }
    }

    /// 节点里出现过的地区（按常见顺序），认不出的归到最后的「其他」。
    static func regions(in nodes: [ProxyNode]) -> [RegionCount] {
        var counts: [String: Int] = [:]
        var other = 0
        for node in nodes {
            if let region = node.region {
                counts[region.code, default: 0] += 1
            } else {
                other += 1
            }
        }
        var result: [RegionCount] = NodeRegion.all.compactMap { region in
            counts[region.code].map { RegionCount(region: region, count: $0) }
        }
        if other > 0 {
            result.append(RegionCount(region: nil, count: other))
        }
        return result
    }

    /// 节点里出现过的协议，小写，按数量从多到少。
    static func types(in nodes: [ProxyNode]) -> [TypeCount] {
        var counts: [String: Int] = [:]
        for node in nodes {
            counts[node.type.lowercased(), default: 0] += 1
        }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { TypeCount(type: $0.key, count: $0.value) }
    }

    static func typeTitle(_ type: String) -> String {
        switch type.lowercased() {
        case "shadowsocks", "ss": return "SS"
        case "shadowsocksr", "ssr": return "SSR"
        case "vmess": return "VMess"
        case "vless": return "VLESS"
        case "trojan": return "Trojan"
        case "hysteria": return "Hysteria"
        case "hysteria2": return "Hysteria2"
        case "tuic": return "TUIC"
        case "wireguard": return "WireGuard"
        case "socks5": return "SOCKS5"
        case "http": return "HTTP"
        case "snell": return "Snell"
        case "anytls": return "AnyTLS"
        default: return type.isEmpty ? "?" : type.uppercased()
        }
    }

    /// 能不能变成策略组：协议和只看能用的不能带进去（内核的组只按名字筛选；自动选择本来就只用能通的）。
    var groupNotes: [String] {
        var notes: [String] = []
        if type != nil { notes.append(L("协议条件不会带进策略组")) }
        return notes
    }

    /// 按现在的条件建一个策略组：来源限定成选的订阅，地区和关键词变成节点名筛选，只看收藏时就是收藏的那几个。
    func makeGroup(name: String, kind: PolicyGroupKind, favorites: [String]) -> PolicyGroup {
        var parts: [String] = []
        if let region {
            if region == NodeQuery.otherRegion {
                // 其他地区：排除所有认得出的。
                parts.append("^(?!.*(?:" + NodeRegion.all.map(\.pattern).joined(separator: "|") + "))")
            } else if let known = NodeRegion.named(region) {
                parts.append("(?:" + known.pattern + ")")
            }
        }
        let keyword = text.trimmingCharacters(in: .whitespaces)
        if !keyword.isEmpty {
            parts.append(NSRegularExpression.escapedPattern(for: keyword))
        }
        if onlyFavorites && !favorites.isEmpty {
            parts.append("^(?:" + favorites.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")$")
        }
        let filter: String
        switch parts.count {
        case 0: filter = ""
        case 1: filter = parts[0]
        default: filter = parts.map { "(?=.*\($0))" }.joined()
        }
        var group = PolicyGroup(name: name, kind: kind, filter: filter)
        if let source {
            group.sources = [source]
        }
        return group
    }

    /// 按条件建组时默认的名字：地区 + 自动，或者订阅名 + 自动。
    func suggestedGroupName(sourceName: String?) -> String {
        var name = ""
        if let region, let known = NodeRegion.named(region) {
            name = known.name
        } else if let sourceName {
            name = sourceName
        } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
            name = text.trimmingCharacters(in: .whitespaces)
        } else if onlyFavorites {
            name = L("收藏")
        }
        let suffixLength = L("%@自动", "").count
        let base = String((name.isEmpty ? L("筛选") : name).prefix(PolicyGroup.maxNameLength - suffixLength))
        return L("%@自动", base)
    }
}
