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
        XCTAssertEqual(AppLanguage.format("开启 %@", ["Charles"]), "开启 Charles")
        XCTAssertEqual(AppLanguage.format("No %2$@ named “%1$@”", ["Work", "profile"]), "No profile named “Work”")
        XCTAssertEqual(AppLanguage.format("%@ 秒，%.1f、50%", ["3"]), "3 秒，%.1f、50%")
        XCTAssertEqual(AppLanguage.format("%@ %@", ["a"]), "a ")
    }

    /// 测试里没有翻译表：界面文字原样是中文，数字照字符串插值的写法。
    func testFallsBackToChinese() {
        XCTAssertFalse(AppLanguage.isEnglish)
        XCTAssertEqual(L("设置…"), "设置…")
        XCTAssertEqual(L("%@ 个代理配置", 12), "12 个代理配置")
        XCTAssertEqual(L("已开启「%@」（%@）", "公司代理", "proxy.corp:3128"), "已开启「公司代理」（proxy.corp:3128）")
        // 「‖」后面是给翻译看的说明，中文里不显示。
        XCTAssertEqual(L("关闭‖按钮"), "关闭")
    }

}
