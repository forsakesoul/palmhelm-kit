import Foundation
#if canImport(SwiftUI)
import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// 工作中的呼吸点：Core Animation 在图层上循环（合成在 GPU 上完成）。
/// 原先的 SwiftUI repeatForever 会让宿主视图每帧求值，实测每个常驻动画约占 6–7% CPU（O1-337）；
/// 图层动画的 CPU 为 0。视觉与原 ActivityDot 工作态一致：scale 1 ↔ 1.25、opacity 1 ↔ 0.6，easeInOut 1.2s 往返。
/// `breathing` 为 false 时（空闲、离线、减少动态效果）移除动画，图层静止。
public struct BreathingDot: View {
    let color: Color
    let size: CGFloat
    let breathing: Bool

    public init(color: Color, size: CGFloat, breathing: Bool) {
        self.color = color
        self.size = size
        self.breathing = breathing
    }

    public var body: some View {
        BreathingDotRepresentable(color: color, breathing: breathing)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// 图层上的呼吸动画（两端共用的动画参数与添加 / 移除逻辑）。
enum BreathingAnimation {
    static let scaleKey = "palmhelm.breath.scale"
    static let opacityKey = "palmhelm.breath.opacity"
    static let duration: CFTimeInterval = 1.2

    static func attach(to layer: CALayer) {
        guard layer.animation(forKey: scaleKey) == nil else { return }
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 1.25
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1.0
        opacity.toValue = 0.6
        for a in [scale, opacity] {
            a.duration = duration
            a.autoreverses = true
            a.repeatCount = .infinity
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        }
        layer.add(scale, forKey: scaleKey)
        layer.add(opacity, forKey: opacityKey)
    }

    static func detach(from layer: CALayer) {
        layer.removeAnimation(forKey: scaleKey)
        layer.removeAnimation(forKey: opacityKey)
    }
}

#if os(macOS)
private struct BreathingDotRepresentable: NSViewRepresentable {
    let color: Color
    let breathing: Bool
    func makeNSView(context: Context) -> BreathingLayerNSView { BreathingLayerNSView() }
    func updateNSView(_ view: BreathingLayerNSView, context: Context) { view.configure(color: NSColor(color), breathing: breathing) }
    static func dismantleNSView(_ view: BreathingLayerNSView, coordinator: ()) { view.stopBreathing() }
}

/// 呼吸点的宿主视图：一个圆形图层，动画挂在图层上。
final class BreathingLayerNSView: NSView {
    private let dot = CALayer()
    private var breathing = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(dot)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() {
        super.layout()
        dot.frame = bounds
        dot.cornerRadius = min(bounds.width, bounds.height) / 2
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }
    func configure(color: NSColor, breathing: Bool) {
        dot.backgroundColor = color.cgColor
        self.breathing = breathing
        apply()
    }
    /// 动画 / 图层被系统移除后（进出窗口）按状态重新挂上。
    var hasBreathingAnimation: Bool { dot.animation(forKey: BreathingAnimation.scaleKey) != nil }
    /// 离窗（列表滚出、页面切走）时必须摘除：不在窗口里的图层不应继续跑动画（O1-341 R1）。
    private func apply() {
        if breathing && window != nil { BreathingAnimation.attach(to: dot) } else { BreathingAnimation.detach(from: dot) }
    }
    func stopBreathing() { breathing = false; apply() }
}
#elseif canImport(UIKit)
private struct BreathingDotRepresentable: UIViewRepresentable {
    let color: Color
    let breathing: Bool
    func makeUIView(context: Context) -> BreathingLayerUIView { BreathingLayerUIView() }
    func updateUIView(_ view: BreathingLayerUIView, context: Context) { view.configure(color: UIColor(color), breathing: breathing) }
    static func dismantleUIView(_ view: BreathingLayerUIView, coordinator: ()) { view.stopBreathing() }
}

/// 呼吸点的宿主视图：一个圆形图层，动画挂在图层上。
final class BreathingLayerUIView: UIView {
    private let dot = CALayer()
    private var breathing = false
    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(dot)
    }
    required init?(coder: NSCoder) { nil }
    override func layoutSubviews() {
        super.layoutSubviews()
        dot.frame = bounds
        dot.cornerRadius = min(bounds.width, bounds.height) / 2
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        apply()
    }
    func configure(color: UIColor, breathing: Bool) {
        dot.backgroundColor = color.cgColor
        self.breathing = breathing
        apply()
    }
    var hasBreathingAnimation: Bool { dot.animation(forKey: BreathingAnimation.scaleKey) != nil }
    /// 离窗（列表滚出、页面切走）时必须摘除：不在窗口里的图层不应继续跑动画（O1-341 R1）。
    private func apply() {
        if breathing && window != nil { BreathingAnimation.attach(to: dot) } else { BreathingAnimation.detach(from: dot) }
    }
    func stopBreathing() { breathing = false; apply() }
}
#endif
#endif
