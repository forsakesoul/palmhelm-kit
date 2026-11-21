import Foundation

/// Kit 的界面文案查表。显式选 lproj（而不是 String(localized:bundle:) 的隐式解析），
/// 这样 CLI 测试宿主与应用宿主得到同一结果。语言优先级：`$locale`（测试/显式调用）> `DisplayLanguage.shared`（用户选择，默认跟随系统）。
public enum KitL10n {
    /// 测试或调用方可注入的语言；nil 表示使用 DisplayLanguage 的当前语言。
    @TaskLocal public static var locale: Locale? = nil

    /// 无格式参数的文案：key 为源语言（zh-Hans 原文）或稳定 ID；缺译文时回退 defaultValue（默认为 key）。
    public static func string(_ key: String, default defaultValue: String? = nil) -> String {
        table(current().resource).localizedString(forKey: key, value: defaultValue ?? key, table: nil)
    }

    /// 带插值的文案：fmt 为 catalog 的格式键（%@ / %lld），参数顺序与 Swift 插值一致。
    public static func format(_ fmt: String, _ args: CVarArg...) -> String {
        let (resource, loc) = current()
        return String(format: table(resource).localizedString(forKey: fmt, value: fmt, table: nil), locale: loc, arguments: args)
    }

    /// OS 语言范围（D2）：Watch、实时活动等由 OS 选语言的表面，其文案在 iPhone 上生成时也按系统语言，不跟手选偏好。
    public static func withSystemLanguage<T>(_ body: () throws -> T) rethrows -> T {
        try $locale.withValue(systemLocale(), operation: body)
    }
    public static func withSystemLanguage<T>(isolation: isolated (any Actor)? = #isolation, _ body: () async throws -> T) async rethrows -> T {
        try await $locale.withValue(systemLocale(), operation: body, isolation: isolation)
    }
    private static func systemLocale() -> Locale {
        ResolvedLanguage.resolve(.system, preferredLanguages: Locale.preferredLanguages, systemLocale: .autoupdatingCurrent).formattingLocale
    }

    /// 展示用日期/数字的 locale：资源语言文字 + 系统地区/日历/时区/12-24h。协议格式（en_US_POSIX）不用它。
    public static var formattingLocale: Locale { current().locale }

    /// 给 App 垫片用：`main` 里当前资源语言的 .lproj（没有则 main 本身），让 String(localized:bundle:) 取到所选语言。
    public static func appBundle(_ main: Bundle = .main) -> Bundle {
        lproj(in: main, language: current().resource) ?? main
    }

    /// App 的 `String(localized:)` 垫片转发到这里：在 Kit 内调用 Foundation 原版，避免垫片自递归。
    public static func localized(_ value: String.LocalizationValue, table: String?, bundle: Bundle?, comment: StaticString?) -> String {
        let (resource, loc) = current()
        let b = bundle ?? .main
        return String(localized: value, table: table, bundle: lproj(in: b, language: resource) ?? b, locale: loc, comment: comment)
    }

    /// 展示用日期时间（不改变日期代表的时刻）。
    public static func formatted(_ d: Date, date: Date.FormatStyle.DateStyle = .omitted, time: Date.FormatStyle.TimeStyle = .omitted) -> String {
        d.formatted(displayStyle(Date.FormatStyle(date: date, time: time)))
    }
    /// 展示用 FormatStyle 的唯一入口：只传 locale 时 FormatStyle 仍用公历，必须显式带上系统日历（小时周期随 locale）。
    /// 时区沿用 style 自身（默认当前时区；统计按响应时区的调用先设好 timeZone）。
    public static func displayStyle(_ style: Date.FormatStyle) -> Date.FormatStyle {
        let l = formattingLocale
        var s = style.locale(l)
        s.calendar = l.calendar
        return s
    }
    /// 展示用数字。
    public static func number<V: BinaryInteger>(_ v: V) -> String { v.formatted(IntegerFormatStyle<V>(locale: formattingLocale)) }
    public static func number(_ v: Double) -> String { v.formatted(FloatingPointFormatStyle<Double>(locale: formattingLocale)) }

    static var resourceLanguage: String { current().resource }
    /// 当前显示语言是中文（原文即 Bridge 的 canonical 中文，无需语义化）。
    public static var isChinese: Bool { current().resource.hasPrefix("zh") }

    /// 一次取齐“资源语言 + 格式 locale”：`$locale`（测试/OS 语言范围）优先，否则 DisplayLanguage 的同一份快照。
    private static func current() -> (resource: String, locale: Locale) {
        if let l = locale { return (l.identifier, l) }
        let c = DisplayLanguage.shared.context
        return (c.resourceLanguage, c.formattingLocale)
    }

    private static func table(_ language: String) -> Bundle {
        let bundle = Bundle.module
        return lproj(in: bundle, language: language) ?? bundle
    }

    /// 至多 bundle 数 × 语言数个条目，无需淘汰；命中后不再做语言匹配。
    private final class LprojCache: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Bundle] = [:]
        func get(_ k: String) -> Bundle? { lock.withLock { items[k] } }
        func set(_ k: String, _ v: Bundle) { lock.withLock { items[k] = v } }
    }
    private static let cache = LprojCache()
    private static func lproj(in bundle: Bundle, language: String) -> Bundle? {
        let key = "\(bundle.bundlePath)#\(language)"
        if let hit = cache.get(key) { return hit }
        let matched = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: [language]).first ?? "en"
        guard let path = bundle.path(forResource: matched, ofType: "lproj"), let t = Bundle(path: path) else { return nil }
        cache.set(key, t)
        return t
    }
}
