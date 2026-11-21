import Foundation
import Testing
@testable import PalmhelmKit

/// 测试固定的中文环境：Kit 的文案按 locale 取值，断言中文时显式传入，不依赖运行机器的语言。
let zhHansLocale = Locale(identifier: "zh-Hans")

// #63 切片 ①：命令 reason 的三语文案（catalog 在包资源中）。ja 暂无译文，回退英文（O1-293）。
@Suite struct CommandCopyTests {
    @Test func chineseTextMatchesTheExistingCopy() {
        #expect(CommandCopy.text(.queueExpired, locale: zhHansLocale) == "已过期，未发出")
        #expect(CommandCopy.text(.queueExpiredUncertain, locale: zhHansLocale) == "停止后续排队，之前的结果待确认")
        #expect(CommandCopy.text(.withdrawn, locale: zhHansLocale) == "已撤回，未发出")
        #expect(CommandCopy.text(.merged, locale: zhHansLocale) == "已并入当前回合")
    }

    @Test func englishIsTheSourceText() {
        let en = Locale(identifier: "en")
        #expect(CommandCopy.text(.queueExpired, locale: en) == "Expired, not sent")
        #expect(CommandCopy.text(.queueExpiredUncertain, locale: en) == "Queueing stopped; earlier results unconfirmed")
        #expect(CommandCopy.text(.withdrawn, locale: en) == "Withdrawn, not sent")
        #expect(CommandCopy.text(.merged, locale: en) == "Merged into the current turn")
    }

    @Test func japaneseFallsBackToEnglishUntilATranslationExists() {
        #expect(CommandCopy.text(.withdrawn, locale: Locale(identifier: "ja")) == "Withdrawn, not sent")
    }

    @Test func everyReasonKeyIsInTheCatalogForBothSourceAndChinese() {
        #expect(CommandReason.allCases.count == 4)
        for reason in CommandReason.allCases {
            #expect(CommandCopy.text(reason, locale: zhHansLocale) != reason.rawValue)
        }
    }
}
