import Foundation
import Testing
@testable import PalmhelmKit

// h10a K5：工作中跟 accent，等你跟 warn；等你胶囊的深字在 warn 底上 ≥ 4.5:1。
@Suite struct UrgencyRoleTests {
    @Test func workingFollowsAccentAndWaitingFollowsWarn() {
        #expect(PalmhelmIdentityPalette.urgencyRole(.working) == .accent)
        #expect(PalmhelmIdentityPalette.urgencyRole(.waiting) == .warn)
        #expect(PalmhelmIdentityPalette.urgencyRole(.unread) == .unread)
        #expect(PalmhelmIdentityPalette.urgencyRole(.idle) == .idle)
    }

    @Test func waitingPillTextIsReadableOnWarn() {
        func lum(_ v: UInt32) -> Double {
            func lin(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(Double((v >> 16) & 0xFF) / 255) + 0.7152 * lin(Double((v >> 8) & 0xFF) / 255) + 0.0722 * lin(Double(v & 0xFF) / 255)
        }
        let (a, b) = (lum(0x1A1205), lum(PalmhelmSemanticColor.warn.light))
        #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5)
    }
}
