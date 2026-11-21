#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// 身份标识的颜色：角色色块固定（设计蓝 / 执行橙 / 顾问紫），状态胶囊按紧急度。两端共用，深浅模式共用一组中间明度。
public enum PalmhelmIdentityPalette {
    public static func role(_ r: AgentRole?) -> Color {
        switch r {
        case .design?: rgbColor(0x2F6FD6)
        case .execute?: rgbColor(0xC2410C)
        case .advisor?: rgbColor(0x6D4AC9)
        case nil: rgbColor(0x5C6873)
        }
    }

    /// 紧急度对应的语义角色（纯映射，便于测试）：工作中跟 accent，等你跟 warn，其余不随主题。
    public enum UrgencyRole: Sendable, Equatable { case accent, warn, unread, idle }
    public static func urgencyRole(_ u: Urgency) -> UrgencyRole {
        switch u {
        case .working: .accent
        case .waiting: .warn
        case .unread: .unread
        case .idle: .idle
        }
    }

    /// 状态胶囊的前景 / 背景（h10a K5）：工作中用注入的 accent（与 ActivityDot 同源），等你用 warn 底 + 深字（白字在 warn 上对比不足）。
    public static func urgency(_ u: Urgency, accent: Color = PalmhelmThemeTokens.tokens(.standard).color(\.accent)) -> (fg: Color, bg: Color) {
        switch urgencyRole(u) {
        case .warn: (adaptive(light: 0x1A1205, dark: 0x1A1205), PalmhelmSemanticColor.warn.color)
        case .accent: (accent, accent.opacity(0.18))
        case .unread: (adaptive(light: 0x2459B0, dark: 0x9CC2FF), rgbColor(0x2F6FD6).opacity(0.18))
        case .idle: (.secondary, Color.secondary.opacity(0.12))
        }
    }
}

extension PalmhelmIdentityPalette {
    /// 固定色值（0xRRGGBB）转 SwiftUI 颜色（身份色与未读色不随主题家族或图表索引变化）。
    static func rgbColor(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }

    /// 浅底深字 / 深底浅字：暗色下用浅前景，保证小字对比（A1-089 S2）。
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? rgb(dark) : rgb(light) })
        #elseif canImport(AppKit)
        Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? nsrgb(dark) : nsrgb(light) })
        #else
        rgbColor(light)
        #endif
    }
    #if canImport(UIKit)
    static func rgb(_ v: UInt32) -> UIColor { UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1) }
    #elseif canImport(AppKit)
    static func nsrgb(_ v: UInt32) -> NSColor { NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1) }
    #endif
}

/// 状态胶囊：「等你 / 完成未读 / 工作中 / 空闲」。
public struct UrgencyPill: View {
    let urgency: Urgency
    let accent: Color
    public init(_ urgency: Urgency, accent: Color = PalmhelmThemeTokens.tokens(.standard).color(\.accent)) { self.urgency = urgency; self.accent = accent }
    public var body: some View {
        let c = PalmhelmIdentityPalette.urgency(urgency, accent: accent)
        Text(urgency.label).font(.caption2.weight(.semibold)).foregroundStyle(c.fg)
            .padding(.horizontal, 7).padding(.vertical, 2).background(c.bg, in: Capsule())
    }
}

/// 角色色块：有角色写“设计 / 执行 / 顾问”，否则写种类首字母。
public struct RoleBadge: View {
    let target: TargetSummary?
    let size: CGFloat
    public init(_ target: TargetSummary?, size: CGFloat = 36) { self.target = target; self.size = size }
    public var body: some View {
        let role = target.flatMap(ThreadIdentity.role)
        let text = role?.label ?? (ThreadIdentity.kindLabel(target?.kind).map { String($0.prefix(2)) } ?? "·")
        Text(text).font(.system(size: size * 0.34, weight: .bold)).foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(PalmhelmIdentityPalette.role(role), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityLabel(role.map { KitL10n.format("角色 %@", $0.label) } ?? "agent")
    }
}
#endif
