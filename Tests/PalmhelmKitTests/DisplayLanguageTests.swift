import Testing
import Foundation
import Observation
@testable import PalmhelmKit

/// App 内语言选择：纯解析、持久化、发布规则，以及“选定语言必须选对 lproj、locale 参数不能替代”的 Foundation 前提。
@Suite struct DisplayLanguageTests {
    private static let usSystem = Locale(identifier: "en_US")
    private static let cnSystem = Locale(identifier: "zh_CN")

    @Test func unknownStoredValueFallsBackToSystem() {
        #expect(AppLanguageChoice(stored: nil) == .system)
        #expect(AppLanguageChoice(stored: "ja") == .system)
        #expect(AppLanguageChoice(stored: "跟随系统") == .system)
        #expect(AppLanguageChoice(stored: "zh-Hans") == .zhHans)
        #expect(AppLanguageChoice(stored: "en") == .en)
    }

    @Test func systemChoiceMatchesSupportedResourcesAndFallsBackToEnglish() {
        func r(_ p: [String]) -> String { ResolvedLanguage.resolve(.system, preferredLanguages: p, systemLocale: Self.usSystem).resourceLanguage }
        #expect(r(["zh-Hans-CN", "en-US"]) == "zh-Hans")
        #expect(r(["en-US"]) == "en")
        #expect(r(["fr-FR"]) == "en")
        #expect(r(["fr-FR", "zh-Hans-CN"]) == "zh-Hans")
    }

    @Test func manualChoiceIgnoresSystemLanguageButKeepsRegion() {
        let zhOnUS = ResolvedLanguage.resolve(.zhHans, preferredLanguages: ["en-US"], systemLocale: Self.usSystem)
        #expect(zhOnUS.resourceLanguage == "zh-Hans")
        #expect(zhOnUS.formattingLocale.language.languageCode?.identifier == "zh")
        #expect(zhOnUS.formattingLocale.region?.identifier == "US")
        let enOnCN = ResolvedLanguage.resolve(.en, preferredLanguages: ["zh-Hans-CN"], systemLocale: Self.cnSystem)
        #expect(enOnCN.resourceLanguage == "en")
        #expect(enOnCN.formattingLocale.language.languageCode?.identifier == "en")
        #expect(enOnCN.formattingLocale.region?.identifier == "CN")
    }

    @Test func formattingKeepsSystemHourCycleAndCalendar() {
        let sys = Locale(identifier: "en_US@hours=h23;calendar=buddhist")
        let r = ResolvedLanguage.resolve(.zhHans, preferredLanguages: ["en-US"], systemLocale: sys)
        #expect(r.formattingLocale.hourCycle == .zeroToTwentyThree)
        #expect(r.formattingLocale.calendar.identifier == .buddhist)
    }

    @Test func formattedDatesUseSelectedLanguageText() {
        let d = Date(timeIntervalSince1970: 1_792_843_200) // 2026-10-24 12:00 UTC，任一时区都在 10 月
        let en = ResolvedLanguage.resolve(.en, preferredLanguages: ["zh-Hans"], systemLocale: Self.cnSystem).formattingLocale
        let zh = ResolvedLanguage.resolve(.zhHans, preferredLanguages: ["en"], systemLocale: Self.usSystem).formattingLocale
        KitL10n.$locale.withValue(en) { #expect(KitL10n.formatted(d, date: .abbreviated).contains("Oct")) }
        KitL10n.$locale.withValue(zh) { #expect(KitL10n.formatted(d, date: .abbreviated).contains("10月")) }
        KitL10n.$locale.withValue(zh) { #expect(KitL10n.number(1234567) == "1,234,567") } // 美国地区的分组保留
        KitL10n.$locale.withValue(Locale(identifier: "en_DE")) { #expect(KitL10n.number(1234567) == "1.234.567") }
    }

    /// A1 M-F2：只传 locale 时 FormatStyle 仍用公历；共同入口必须显式用系统日历与小时周期。比的是真实输出，不是 Locale 属性。
    @Test func formattedOutputKeepsSystemCalendarAndHourCycle() {
        let d = Date(timeIntervalSince1970: 1_700_000_000) // 公历 2023-11-14，佛历 2566
        let sys = Locale(identifier: "en_US@calendar=buddhist;hours=h23")
        for choice in [AppLanguageChoice.en, .zhHans] {
            let l = ResolvedLanguage.resolve(choice, preferredLanguages: ["en-US"], systemLocale: sys).formattingLocale
            KitL10n.$locale.withValue(l) {
                #expect(KitL10n.formatted(d, date: .numeric).contains("2566"), "\(choice) 日期应是佛历")
                let t = KitL10n.formatted(d, time: .shortened)
                let dl = SendTimingCopy.deadlineDate(1_700_000_000_000)
                #expect(!dl.contains("PM") && !dl.contains("下午"), "deadlineDate 也应 24 小时：\(dl)")
                #expect(!t.contains("AM") && !t.contains("PM") && !t.contains("上午") && !t.contains("下午"), "\(choice) 应保持 24 小时：\(t)")
            }
        }
        let gregorian = ResolvedLanguage.resolve(.en, preferredLanguages: ["en-US"], systemLocale: Locale(identifier: "en_US")).formattingLocale
        KitL10n.$locale.withValue(gregorian) { #expect(KitL10n.formatted(d, date: .numeric).contains("2023")) }
    }

    @Test func choiceIsPersistedAndReadBack() throws {
        let suite = "palmhelm.test.lang.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sys: @Sendable () -> (preferred: [String], locale: Locale) = { (["en-US"], Locale(identifier: "en_US")) }
        let a = DisplayLanguage(defaults: defaults, systemProvider: sys)
        #expect(a.choice == .system)
        a.select(.zhHans)
        #expect(defaults.string(forKey: DisplayLanguage.storageKey) == "zh-Hans")
        let b = DisplayLanguage(defaults: defaults, systemProvider: sys)
        #expect(b.choice == .zhHans && b.context.resourceLanguage == "zh-Hans")
        let c = DisplayLanguage(defaults: nil, systemProvider: sys)
        c.attach(defaults: defaults)
        #expect(c.choice == .zhHans, "shared 单例经 attach 读回保存值")
        c.select(.en)
        #expect(defaults.string(forKey: DisplayLanguage.storageKey) == "en")
        defaults.set("klingon", forKey: DisplayLanguage.storageKey)
        #expect(DisplayLanguage(defaults: defaults, systemProvider: sys).choice == .system)
    }

    @Test func publishesOnlyWhenContextActuallyChanges() {
        final class Box: @unchecked Sendable { let l = NSLock(); var langs = ["en-US"]
            var snapshot: [String] { l.withLock { langs } }; func set(_ v: [String]) { l.withLock { langs = v } } }
        let box = Box()
        let model = DisplayLanguage(defaults: nil, systemProvider: { (box.snapshot, Locale(identifier: "en_US")) })
        final class Counter: @unchecked Sendable { var n = 0 }
        let c = Counter()
        func watch() { withObservationTracking { _ = model.state } onChange: { c.n += 1 } }

        watch(); model.select(.system); model.refresh()
        #expect(c.n == 0, "同值与系统未变：不发布")
        model.select(.zhHans)
        #expect(c.n == 1 && model.context.resourceLanguage == "zh-Hans")
        watch(); box.set(["fr"]); model.refresh()
        #expect(c.n == 1, "手动语言下系统语言变化：context 不变，不发布")
        model.select(.system) // en → 解析为 en（fr 无匹配）
        watch(); box.set(["zh-Hans-CN"]); model.refresh()
        #expect(c.n == 3 && model.context.resourceLanguage == "zh-Hans", "跟随系统时系统语言变化：发布一次")
    }

    /// Foundation 前提（A2 F0 探针转单测）：String(localized:locale:) 不会改变查表 bundle；必须显式取所选语言的 lproj。
    @Test func selectedLanguageBundleIsRequiredLocaleParameterCannotReplaceIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("palmhelm-lang-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        for (lang, text) in [("en", "Hello"), ("zh-Hans", "你好")] {
            let dir = root.appendingPathComponent("\(lang).lproj")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "\"hi\" = \"\(text)\";".write(to: dir.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        }
        let parent = try #require(Bundle(url: root))
        // 父 bundle + 显式 locale：仍按宿主语言取（这里宿主偏好不含 zh-Hans 时是英文）——locale 参数不能替代 lproj 选择
        let viaLocaleOnly = String(localized: "hi", bundle: Bundle(path: parent.path(forResource: "en", ofType: "lproj")!)!, locale: Locale(identifier: "zh-Hans"))
        #expect(viaLocaleOnly == "Hello")
        KitL10n.$locale.withValue(Locale(identifier: "zh-Hans")) {
            #expect(String(localized: "hi", bundle: KitL10n.appBundle(parent)) == "你好")
            #expect(KitL10n.localized("hi", table: nil, bundle: parent, comment: nil) == "你好")
        }
        KitL10n.$locale.withValue(Locale(identifier: "en")) {
            #expect(String(localized: "hi", bundle: KitL10n.appBundle(parent)) == "Hello")
            #expect(KitL10n.localized("hi", table: nil, bundle: parent, comment: nil) == "Hello")
        }
    }

    /// D2：OS 语言范围不受手选影响——即使进程级选择不同，范围内取系统语言；范围外不变。
    @Test func systemLanguageScopeOverridesTheProcessSelection() async {
        let inside = KitL10n.withSystemLanguage { KitL10n.resourceLanguage }
        let expected = ResolvedLanguage.resolve(.system, preferredLanguages: Locale.preferredLanguages, systemLocale: .autoupdatingCurrent).formattingLocale.identifier
        #expect(inside == expected)
        let asyncInside = await KitL10n.withSystemLanguage { await Task.yield(); return KitL10n.resourceLanguage }
        #expect(asyncInside == expected)
    }

    @Test func kitFormattingLocaleDefaultsToDisplayLanguage() {
        #expect(KitL10n.formattingLocale == DisplayLanguage.shared.context.formattingLocale)
    }
}

/// A2-002 R5：旧 refresh 在 systemProvider 里暂停时，并发 select 不能被它之后覆盖（持久化与发布必须一致）。
@Suite struct DisplayLanguageConcurrencyTests {
    final class Gate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let l = NSLock(); var armed = false
        func arm() { l.withLock { armed = true } }
        /// 第一次被调用时暂停（模拟 refresh 已捕获状态、正在读系统语言）
        func hit() { let fire = l.withLock { () -> Bool in defer { armed = false }; return armed }
            if fire { entered.signal(); release.wait() } }
    }

    @Test func staleRefreshCannotOverwriteConcurrentSelect() throws {
        let suite = "palmhelm.test.race.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = Gate()
        let model = DisplayLanguage(defaults: defaults, systemProvider: { gate.hit(); return (["en-US"], Locale(identifier: "en_US")) })
        model.select(.system)
        gate.arm()
        let refresher = Thread { model.refresh() }
        refresher.start()
        gate.entered.wait() // refresh 已在事务里、停在读系统语言
        let selected = DispatchSemaphore(value: 0)
        let selector = Thread { model.select(.zhHans); selected.signal() }
        selector.start()
        Thread.sleep(forTimeInterval: 0.05) // 让 select 有机会越过（修复前会直接写盘并发布）
        gate.release.signal()
        selected.wait()
        for _ in 0..<100 where refresher.isExecuting { Thread.sleep(forTimeInterval: 0.01) }
        #expect(defaults.string(forKey: DisplayLanguage.storageKey) == "zh-Hans")
        #expect(model.choice == .zhHans && model.context.resourceLanguage == "zh-Hans", "发布值必须等于持久化的选择")
    }
}

/// A2-003 R5-a：onChange 回调里重入 select 时，以最后一次选择为准，发布与持久化一致。
@Suite struct DisplayLanguageReentrancyTests {
    @Test func selectInsideOnChangeWinsOverTheOuterPublish() throws {
        let suite = "palmhelm.test.reenter.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DisplayLanguage(defaults: defaults, systemProvider: { (["en-US"], Locale(identifier: "en_US")) })
        model.select(.system)
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        withObservationTracking { _ = model.state } onChange: { if !once.done { once.done = true; model.select(.zhHans) } }
        model.select(.en)
        #expect(defaults.string(forKey: DisplayLanguage.storageKey) == "zh-Hans")
        #expect(model.choice == .zhHans && model.context.resourceLanguage == "zh-Hans", "发布值必须等于最后一次（回调内）的选择")
    }
}
