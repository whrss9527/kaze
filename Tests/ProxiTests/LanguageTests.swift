import XCTest
@testable import Proxi

final class LanguageTests: XCTestCase {
    func testReadsTheStoredChoice() {
        XCTAssertEqual(InterfaceLanguage(appleLanguages: nil), .system)
        XCTAssertEqual(InterfaceLanguage(appleLanguages: [String]()), .system)
        XCTAssertEqual(InterfaceLanguage(appleLanguages: ["en"]), .english)
        XCTAssertEqual(InterfaceLanguage(appleLanguages: ["en-US", "zh-Hans"]), .english)
        XCTAssertEqual(InterfaceLanguage(appleLanguages: ["zh-Hans"]), .simplifiedChinese)
        XCTAssertEqual(InterfaceLanguage(appleLanguages: ["zh-Hans-CN"]), .simplifiedChinese)
        XCTAssertEqual(InterfaceLanguage(appleLanguages: "en"), .english)
        // 系统设置里给 Proxi 单独选了别的语言：当作跟随系统。
        XCTAssertEqual(InterfaceLanguage(appleLanguages: ["fr"]), .system)
        XCTAssertEqual(InterfaceLanguage(appleLanguages: ["zh-Hant"]), .system)
        XCTAssertEqual(InterfaceLanguage(appleLanguages: 42), .system)
    }

    func testRoundTrip() {
        for language in InterfaceLanguage.allCases {
            XCTAssertEqual(InterfaceLanguage(appleLanguages: language.appleLanguages), language)
        }
        XCTAssertNil(InterfaceLanguage.system.appleLanguages)
        XCTAssertEqual(InterfaceLanguage.simplifiedChinese.appleLanguages, ["zh-Hans"])
    }

    func testLanguagesAreNamedInTheirOwnLanguage() {
        XCTAssertEqual(InterfaceLanguage.english.title, "English")
        XCTAssertEqual(InterfaceLanguage.simplifiedChinese.title, "简体中文")
        XCTAssertEqual(InterfaceLanguage.system.title, "跟随系统")
    }

    func testRelaunchArguments() {
        XCTAssertEqual(Relaunch.pidToWait(in: ["Proxi"] + Relaunch.arguments(waitingFor: 4321)), 4321)
        XCTAssertNil(Relaunch.pidToWait(in: ["Proxi"]))
        XCTAssertNil(Relaunch.pidToWait(in: ["Proxi", "--relaunch-after"]))
        XCTAssertNil(Relaunch.pidToWait(in: ["Proxi", "--relaunch-after", "x"]))
        XCTAssertNil(Relaunch.pidToWait(in: ["Proxi", "--relaunch-after", "0"]))
        // 带着等待参数启动的是界面，不是命令行。
        XCTAssertFalse(CommandLineTool.shouldHandle(["Proxi"] + Relaunch.arguments(waitingFor: 4321)))
    }

    func testFormatsPlaceholders() {
        XCTAssertEqual(AppLanguage.format("开启 %@", ["Clash"]), "开启 Clash")
        XCTAssertEqual(AppLanguage.format("No %2$@ named “%1$@”", ["HK", "node"]), "No node named “HK”")
        XCTAssertEqual(AppLanguage.format("%@ 秒，%.1f、50%", ["3"]), "3 秒，%.1f、50%")
        XCTAssertEqual(AppLanguage.format("%@ %@", ["a"]), "a ")
    }

    /// 测试里没有翻译表：界面文字原样是中文，数字照字符串插值的写法。
    func testFallsBackToChinese() {
        XCTAssertFalse(AppLanguage.isEnglish)
        XCTAssertEqual(L("设置…"), "设置…")
        XCTAssertEqual(L("%@ 个节点", 12), "12 个节点")
        XCTAssertEqual(L("节点 %@（%@）", "香港 01", "机场"), "节点 香港 01（机场）")
        // 「‖」后面是给翻译看的说明，中文里不显示。
        XCTAssertEqual(L("关闭‖按钮"), "关闭")
    }

    /// 内核配置里的名字不翻译，界面上换成界面语言（测试里是中文）。
    func testCoreNamesStayChineseInTheCoreConfig() {
        XCTAssertEqual(RuleConverter.proxyGroup, "节点")
        XCTAssertEqual(CoreConfigBuilder.autoGroup, "自动选择")
        XCTAssertEqual(CoreConfigBuilder.displayName("节点"), "节点")
        XCTAssertEqual(CoreConfigBuilder.displayName("前置·公司代理"), "前置·公司代理")
        XCTAssertEqual(CoreConfigBuilder.displayName("香港 01"), "香港 01")
        XCTAssertEqual(TrafficEntry(name: "设备 192.168.1.30", traffic: TrafficTotal()).displayName, "设备 192.168.1.30")
        XCTAssertEqual(TrafficEntry(name: "本机其他", traffic: TrafficTotal()).displayName, "本机其他")
    }

    func testExcludeProblemsMentionExclude() {
        XCTAssertEqual(PolicyGroup.validateFilter("(", exclude: true), "排除不是正确的正则表达式")
        XCTAssertEqual(PolicyGroup.validateFilter("(", exclude: false), "筛选不是正确的正则表达式")
        XCTAssertEqual(Subscription.validateOptions(filter: "", exclude: "a`b", prefix: ""), "排除里不能有反引号")
    }
}
