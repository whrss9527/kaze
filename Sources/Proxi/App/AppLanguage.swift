import Foundation

/// 界面文字的翻译。
///
/// 代码里写的是中文原文，它同时是 `Resources/<语言>.lproj/Localizable.strings` 里的键；
/// 运行时按界面语言查 Proxi.app 里的翻译表，单元测试里没有翻译表，原样返回中文。
/// 带参数的文字用 `%@` 占位（按顺序），译文里可以用 `%1$@`、`%2$@` 调换顺序：
/// `L("开启 %@", name)`。参数一律按字符串插值的写法转成文字，所以数字的格式和原来一样。
///
/// 同一个中文在不同地方要译成不同的英文时，键后面加「‖」和说明，比如 `L("关闭‖按钮")`：
/// 中文界面和没有翻译表时只显示「‖」前面的部分。
///
/// 所有显示给用户的中文都要经过它（`Scripts/check-localization.py` 会检查），日志和内核配置里的名字不用；
/// SwiftUI 的 `Text("…")` 也写成 `Text(L("…"))`，不依赖 SwiftUI 自己的查表。
func L(_ key: String, _ arguments: Any...) -> String {
    var template = AppLanguage.bundle.localizedString(forKey: key, value: key, table: nil)
    if let mark = template.firstIndex(of: "‖") {
        template = String(template[..<mark])
    }
    guard !arguments.isEmpty else { return template }
    return AppLanguage.format(template, arguments.map { "\($0)" })
}

enum AppLanguage {
    /// 查翻译表的 bundle，就是 Proxi.app（命令行工具是同一个程序，也在 Proxi.app 里）。
    static let bundle = Bundle.main

    /// 界面用的是不是英文。启动后不变，只算一次。
    static let isEnglish: Bool =
        bundle.preferredLocalizations.first?.hasPrefix("en") == true
            && bundle.path(forResource: "Localizable", ofType: "strings") != nil

    /// 英文比中文长：有固定宽度的控件（下拉菜单、分段选择、标题列）在英文界面里用宽一些的尺寸。
    static func width(_ chinese: CGFloat, english: CGFloat) -> CGFloat {
        isEnglish ? english : chinese
    }

    /// 日期、数字和界面用同一种语言。
    static var locale: Locale {
        Locale(identifier: isEnglish ? "en" : "zh_CN")
    }

    /// 把 `%@` 和 `%1$@` 这样的占位换成参数；别的 `%` 原样保留（比如 `%.1f`、`50%`）。
    static func format(_ template: String, _ arguments: [String]) -> String {
        var output = ""
        var next = 0
        var rest = Substring(template)
        while let percent = rest.firstIndex(of: "%") {
            output += rest[..<percent]
            let after = rest[rest.index(after: percent)...]
            if after.hasPrefix("@") {
                output += next < arguments.count ? arguments[next] : ""
                next += 1
                rest = after.dropFirst()
                continue
            }
            let digits = after.prefix(while: \.isNumber)
            let tail = after.dropFirst(digits.count)
            if !digits.isEmpty, tail.hasPrefix("$@"), let position = Int(digits) {
                output += arguments.indices.contains(position - 1) ? arguments[position - 1] : ""
                rest = tail.dropFirst(2)
                continue
            }
            output += "%"
            rest = after
        }
        return output + rest
    }
}
