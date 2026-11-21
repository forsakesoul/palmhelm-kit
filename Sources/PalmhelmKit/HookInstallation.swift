import Foundation

public enum HookProvider: String, Sendable, CaseIterable, Hashable {
    case claude, codex
    public var title: String { self == .claude ? KitL10n.string("Claude Code 审批") : KitL10n.string("Codex 审批") }
}

/// Bridge 固定分类的故障文案（只读显示，不回显路径或原文）。未知分类返回 nil。
public enum HookFailureCopy {
    public static func text(for reason: String) -> String? {
        switch reason {
        case "launch_failed": KitL10n.string("上次启动失败")
        case "runtime_publish_failed": KitL10n.string("上次运行程序准备失败")
        case "config_symlink_unsafe": KitL10n.string("Claude 配置文件类型或位置不安全")
        case "config_permissions": KitL10n.string("Claude 配置文件的权限不安全（别人可写或不是你的文件）")
        case "config_unreadable": KitL10n.string("读不了 Claude 配置文件")
        case "update_failed": KitL10n.string("启动时自动更新失败")
        default: nil
        }
    }
}

public struct HookLaunchFailure: Codable, Sendable, Equatable {
    public var reason: String
    public var at: Int
    public init(reason: String, at: Int) { self.reason = reason; self.at = at }
    public var validDate: Date? {
        guard HookFailureCopy.text(for: reason) != nil, at > 0, at <= 8_640_000_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: Double(at) / 1000)
    }
}

/// GET 返回 503 hook_status_unreadable：配置不可读，installed 未知。不是成功，也不是未安装；体里的故障原样带出。
public struct HookStatusUnreadable: Error, Sendable, Equatable {
    public let lastFailure: HookLaunchFailure?
    public init(lastFailure: HookLaunchFailure?) { self.lastFailure = lastFailure }
}

/// 托管钩子当前指向哪里（#108，仅 Claude；Bridge 不透出目录或命令）。`unreported` = 旧 Bridge 没有该字段，不是 current。
public enum HookOwnership: Sendable, Equatable { case unreported, none, current, other, unknown }

/// Installed means the managed definition exists; it is not evidence of client trust or activation.
public struct HookInstallation: Codable, Sendable, Equatable {
    public var installed: Bool
    public var trust: String
    public var stale: Bool?
    public var lastFailure: HookLaunchFailure?
    /// none | current | other | unknown（原始值；缺字段 = 旧 Bridge）。
    public var managedLocation: String?
    /// 不透明的配置版本（64 位小写十六进制）：条件修复时原样回传，Bridge 在写入前复核。
    public var configVersion: String?
    public init(installed: Bool, trust: String, stale: Bool? = nil, lastFailure: HookLaunchFailure? = nil, managedLocation: String? = nil, configVersion: String? = nil) {
        self.installed = installed; self.trust = trust; self.stale = stale; self.lastFailure = lastFailure
        self.managedLocation = managedLocation; self.configVersion = configVersion
    }

    /// 未知枚举值按 unknown 处理（不能当 current）。
    public var ownership: HookOwnership {
        switch managedLocation {
        case nil: .unreported
        case "none": .none
        case "current": .current
        case "other": .other
        default: .unknown
        }
    }

    /// 带版本确认的版本值只接受有界 64 位小写十六进制，其余视为没有。
    public var confirmableVersion: String? {
        guard let v = configVersion, v.utf8.count == 64, v.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return v
    }
}

public struct HookInstallResult: Codable, Sendable, Equatable {
    public var ok: Bool
    public var error: String?
    public init(ok: Bool, error: String? = nil) { self.ok = ok; self.error = error }
}

public func decodeHookInstallResult(status: Int, data: Data) -> HookInstallResult {
    if (200...299).contains(status) {
        guard let result = try? JSONDecoder().decode(HookInstallResult.self, from: data), result.ok, result.error == nil else {
            return HookInstallResult(ok: false, error: "invalid_response")
        }
        return result
    }
    struct Failure: Decodable { let error: String }
    let error = (try? JSONDecoder().decode(Failure.self, from: data))?.error
    let safe = error.flatMap { value in
        value.count <= 64 && !value.isEmpty && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 } ? value : nil
    }
    return HookInstallResult(ok: false, error: safe ?? "http_\(status)")
}
