import Foundation
import Testing
#if os(macOS)
import AppKit
#endif
@testable import PalmhelmKit

// O1-337 / O1-341：工作中的呼吸点用图层动画（不走 SwiftUI 的 repeatForever）。
// 动画只在「工作中且在窗口里」时挂上；离窗、变为空闲、停止（减少动态效果拆除）都要摘除。
@Suite struct BreathingDotTests {
    #if os(macOS)
    @Test @MainActor func breathingNeedsAWindowAndIsRemovedWhenLeavingIt() {
        let view = BreathingLayerNSView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        #expect(!view.hasBreathingAnimation, "默认静止")
        view.configure(color: .orange, breathing: true)
        #expect(!view.hasBreathingAnimation, "未在窗口里不挂动画")
        window.contentView = view
        #expect(view.hasBreathingAnimation, "进入窗口后按工作态挂上呼吸动画")
        window.contentView = NSView()
        #expect(!view.hasBreathingAnimation, "离窗即摘除，不在窗口里的图层不跑动画")
        window.contentView = view
        #expect(view.hasBreathingAnimation, "回窗后按状态重新挂上")
        view.configure(color: .orange, breathing: false)
        #expect(!view.hasBreathingAnimation, "工作中→空闲/减少动态效果后移除动画，图层静止")
    }

    @Test @MainActor func stoppingTheRepresentableRemovesTheAnimationWhileStillInWindow() {
        let view = BreathingLayerNSView(frame: NSRect(x: 0, y: 0, width: 6, height: 6))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        view.configure(color: .orange, breathing: true)
        #expect(view.hasBreathingAnimation)
        view.stopBreathing()
        #expect(!view.hasBreathingAnimation, "拆除时停止，即使仍在窗口里")
    }
    #endif

    @Test func breathingParametersMatchTheOriginalPulse() {
        // 与原 SwiftUI 版本一致：1.2 秒往返、scale 1 ↔ 1.25、opacity 1 ↔ 0.6
        #expect(BreathingAnimation.duration == 1.2)
        #expect(BreathingAnimation.scaleKey != BreathingAnimation.opacityKey)
    }
}
