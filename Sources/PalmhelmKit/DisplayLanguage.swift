import Foundation
import Observation

/// 用户在设置里选的 App 语言。rawValue 是稳定存储值（不是显示标签）。
public enum AppLanguageChoice: String, CaseIterable, Sendable {
    case system
    case zhHans = "zh-Hans"
    case en

    /// 缺值或未知值回“跟随系统”。
    public init(stored raw: String?) { self = raw.flatMap(Self.init(rawValue:)) ?? .system }
}

/// 一次解析的结果：资源语言（选 lproj）与格式 locale（月份/星期文字用资源语言，地区/日历/时区/12-24h 取系统）。
public struct ResolvedLanguage: Equatable, Sendable {
    public static let supported = ["en", "zh-Hans"]
    public let resourceLanguage: String
    public let formattingLocale: Locale

    /// 纯解析：测试注入系统首选语言与系统 locale，不依赖宿主。`.system` 按受支持资源匹配（含系统每 App 语言覆盖，已体现在 preferred 里），无匹配回 en。
    public static func resolve(_ choice: AppLanguageChoice, preferredLanguages: [String], systemLocale: Locale) -> ResolvedLanguage {
        let resource: String
        switch choice {
        case .zhHans: resource = "zh-Hans"
        case .en: resource = "en"
        case .system: resource = Bundle.preferredLocalizations(from: supported, forPreferences: preferredLanguages).first ?? "en"
        }
        var parts = Locale.Components(locale: systemLocale)
        // 只换语言与文字脚本，保留系统 locale 里的地区（zh-Hans_US 仍是美国地区）。
        let lang = Locale.Language.Components(identifier: resource)
        parts.languageComponents.languageCode = lang.languageCode
        parts.languageComponents.script = lang.script
        return ResolvedLanguage(resourceLanguage: resource, formattingLocale: Locale(components: parts))
    }
}

/// 进程级显示语言：Kit 查表（KitL10n）与两端 App 的 String(localized:) 垫片读同一份快照；
/// SwiftUI body 里读 `state` 会登记 Observation 依赖，语言改变时只重算读过它的视图（不重建根树）。
/// 只存低频的 choice/context，不放业务状态；不读系统时钟、不轮询。
public final class DisplayLanguage: Observable, @unchecked Sendable {
    public struct State: Equatable, Sendable {
        public var choice: AppLanguageChoice
        public var context: ResolvedLanguage
    }

    public static let storageKey = "palmhelm.language"
    public static let shared = DisplayLanguage()

    private let registrar = ObservationRegistrar()
    private let lock = NSLock()
    private var _state: State
    private var defaults: UserDefaults?
    private let systemProvider: @Sendable () -> (preferred: [String], locale: Locale)

    public init(defaults: UserDefaults? = nil,
                systemProvider: @escaping @Sendable () -> (preferred: [String], locale: Locale) = { (Locale.preferredLanguages, Locale.autoupdatingCurrent) }) {
        self.defaults = defaults
        self.systemProvider = systemProvider
        let choice = AppLanguageChoice(stored: defaults?.string(forKey: Self.storageKey))
        let sys = systemProvider()
        _state = State(choice: choice, context: .resolve(choice, preferredLanguages: sys.preferred, systemLocale: sys.locale))
    }

    public var state: State {
        registrar.access(self, keyPath: \.state)
        return lock.withLock { _state }
    }
    public var choice: AppLanguageChoice { state.choice }
    public var context: ResolvedLanguage { state.context }

    /// 写入串行化：attach/select/refresh 各自是“读 choice → 持久化 → 解析 → 比较 → 发布”的完整事务，
    /// 必须整体有序（否则旧 refresh 捕获的 choice 会在新 select 之后覆盖它）。递归锁：Observation 的 onChange 回调同步触发，回调里再 select 不应死锁。
    /// 读（state）只走 `lock` 取不可变快照，不受写事务阻塞。
    private let writer = NSRecursiveLock()

    /// App 启动、显示任何界面之前调用一次：接上各端自己的 UserDefaults（Mac 用 AppDefaults.standard 以尊重 testhost 隔离），读回已保存的选择。
    public func attach(defaults: UserDefaults) {
        writer.withLock {
            lock.withLock { self.defaults = defaults }
            request(AppLanguageChoice(stored: defaults.string(forKey: Self.storageKey)))
        }
    }

    /// 用户选择：先持久化，再一次性发布 choice + context（视图同轮拿到一致事实）。同值不发布。
    public func select(_ choice: AppLanguageChoice) {
        writer.withLock {
            lock.withLock { defaults }?.set(choice.rawValue, forKey: Self.storageKey)
            request(choice)
        }
    }

    /// 系统语言/地区可能变了（回前台、NSLocale.currentLocaleDidChangeNotification）：在事务内读取当前 choice 重新解析，context 不变则不发布。
    public func refresh() {
        writer.withLock { guard !publishing else { return } // 重入的 refresh 不排队：外层发布本就用最新系统语言解析，排队旧 choice 会盖掉回调里的选择
            request(lock.withLock { _state.choice }) }
    }

    // 发布有定序：onChange 回调同步触发，回调里再 select 会重入；内层请求排队，等外层发布写完再处理，
    // 最后一次请求获胜，发布与持久化因此一致。writer 持有期间才读写这两个字段，无需另加锁。
    private var publishing = false
    private var queued: AppLanguageChoice?

    private func request(_ choice: AppLanguageChoice) {
        guard !publishing else { queued = choice; return }
        publishing = true
        defer { publishing = false }
        var next: AppLanguageChoice? = choice
        while let c = next { queued = nil; publish(choice: c); next = queued }
    }

    private func publish(choice: AppLanguageChoice) {
        let sys = systemProvider()
        let next = State(choice: choice, context: .resolve(choice, preferredLanguages: sys.preferred, systemLocale: sys.locale))
        guard lock.withLock({ _state != next }) else { return }
        registrar.withMutation(of: self, keyPath: \.state) { lock.withLock { _state = next } }
    }
}

/// 缓存在状态里的 App 自产文案：存“怎么生成”，到显示时再求值，语言切换即时生效（不清状态、不伪造新错误）。
/// 求值发生在读取处（SwiftUI body 内会登记 DisplayLanguage 依赖）；闭包只能捕获值，不要捕获可变状态。
public struct LocalizedText: Equatable {
    private let make: () -> String
    public init(_ make: @autoclosure @escaping () -> String) { self.make = make }
    public init(build make: @escaping () -> String) { self.make = make }
    public var value: String { make() }
    /// 比较当前语言下的文字，供 Equatable 状态判断。
    public static func == (a: Self, b: Self) -> Bool { a.value == b.value }
}
