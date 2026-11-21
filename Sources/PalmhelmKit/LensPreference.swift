import Foundation

/// 视角偏好与推荐（§8）：按机器（bridge id）记住所选视角、上次结构签名与被忽略的签名；
/// 推荐只在首次见到这台机器或结构签名变化时给一次，不自动切换。两端共用，UserDefaults 持久化。
public final class LensPreferenceStore: @unchecked Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public var lens: ThreadLens?
        public var lastSignature: String?
        public var ignoredSignature: String?
        public init() {}
    }

    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()
    private var cache: [String: Entry]

    public init(defaults: UserDefaults = .standard, storageKey: String = "palmhelm.lensPreference.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        cache = defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    public func entry(_ bridge: String) -> Entry { lock.withLock { cache[bridge] ?? Entry() } }
    public func setLens(_ bridge: String, _ lens: ThreadLens) { update(bridge) { $0.lens = lens } }
    public func ignore(_ bridge: String, signature: String) { update(bridge) { $0.ignoredSignature = signature; $0.lastSignature = signature } }
    public func noteSignature(_ bridge: String, _ signature: String) { update(bridge) { $0.lastSignature = signature } }

    private func update(_ bridge: String, _ f: (inout Entry) -> Void) {
        lock.withLock {
            var e = cache[bridge] ?? Entry(); f(&e); cache[bridge] = e
            if let d = try? JSONEncoder().encode(cache) { defaults.set(d, forKey: storageKey) }
        }
    }

    /// 是否该显示推荐横幅：推荐视角 ≠ 当前视角，且这个签名既没被忽略、也不是上次已提示过的签名。
    public static func shouldRecommend(current: ThreadLens, recommended: ThreadLens, signature: String, entry: Entry) -> Bool {
        recommended != current && entry.ignoredSignature != signature && entry.lastSignature != signature
    }

    public static func bannerText(_ lens: ThreadLens) -> String { KitL10n.format("这批对话更像按「%@」组织的", lens.label) }
}
