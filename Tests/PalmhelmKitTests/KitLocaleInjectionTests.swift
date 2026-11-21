import Testing
import Foundation
@testable import PalmhelmKit

/// 显式语言注入的对照：同一 key 在 zh-Hans 与 en 下取到各自的译文，且不依赖宿主语言。
@Suite struct KitLocaleInjectionTests {
    private static let zh = Locale(identifier: "zh-Hans")
    private static let en = Locale(identifier: "en")

    @Test func plainKeyFollowsInjectedLocale() {
        KitL10n.$locale.withValue(Self.zh) { #expect(KitL10n.string("处理中") == "处理中") }
        KitL10n.$locale.withValue(Self.en) { #expect(KitL10n.string("处理中") == "In progress") }
    }

    @Test func formatKeyFollowsInjectedLocale() {
        KitL10n.$locale.withValue(Self.zh) { #expect(KitL10n.format("队列第 %lld 位", 2) == "队列第 2 位") }
        KitL10n.$locale.withValue(Self.en) { #expect(KitL10n.format("队列第 %lld 位", 2) == "Queue position 2") }
    }

    @Test func percentLiteralIsEscapedInBothLocales() {
        KitL10n.$locale.withValue(Self.zh) { #expect(KitL10n.format("已用 %lld%%", 42) == "已用 42%") }
        KitL10n.$locale.withValue(Self.en) { #expect(KitL10n.format("已用 %lld%%", 42) == "42% used") }
    }

    @Test func idKeyUsesDefaultValueOnlyWhenNoTranslation() {
        KitL10n.$locale.withValue(Self.en) {
            #expect(KitL10n.string("kit.sending.short", default: "发送中") == "Sending")
        }
    }

    /// 生产属性与字典入口：每次访问按当前语言求值（不在 static let 初始化时固化）。
    @Test func productPropertiesFollowInjectedLocaleOnEachAccess() {
        KitL10n.$locale.withValue(Self.zh) {
            #expect(ApprovalContextCopy.causeTitle == "起因")
            #expect(TranscriptCopy.unavailableCopy(reason: "no_session").title == "这个窗格还没有会话记录")
            #expect(InputCopy.keyLabels["space"] == "空格")
            #expect(ApprovalText.candidateDisplayPrefix == "候选：")
            #expect(ApprovalText.displayLabel("候选：proj") == "候选：proj")
        }
        KitL10n.$locale.withValue(Self.en) {
            #expect(ApprovalContextCopy.causeTitle == "Cause")
            #expect(TranscriptCopy.unavailableCopy(reason: "no_session").title == "This pane has no session record yet")
            #expect(ApprovalText.candidateDisplayPrefix == "Candidates: ")
            #expect(ApprovalText.displayLabel("候选：proj") == "Candidates: proj")
        }
    }

    /// 协议常量不随语言变化：候选前缀用于解析，中英文下都必须是 Bridge 输出的固定值。
    @Test func protocolPrefixIsLocaleIndependent() {
        KitL10n.$locale.withValue(Self.en) {
            #expect(ApprovalText.candidatePrefix == "候选：")
            #expect(ApprovalText.projectName(ofLabel: "候选：proj") == "proj")
        }
        KitL10n.$locale.withValue(Self.zh) {
            #expect(ApprovalText.projectName(ofLabel: "候选：proj") == "proj")
        }
    }

    /// #116：数量为 1 时用单数（plural variations），含多占位符的 substitutions；0 与多个用复数；中文不变。
    @Test func englishPluralFormsFollowTheCount() {
        KitL10n.$locale.withValue(Self.en) {
            #expect(KitL10n.format("%lld 字", 1) == "1 character")
            #expect(KitL10n.format("%lld 字", 2) == "2 characters")
            #expect(KitL10n.format("%lld 字", 0) == "0 characters")
            #expect(KitL10n.format("有 %lld 条待答，在「等待」页处理", 1) == "1 pending answer. Handle it on the Waiting page.")
            #expect(KitL10n.format("有 %lld 条待答，在「等待」页处理", 3) == "3 pending answers. Handle them on the Waiting page.")
            #expect(KitL10n.format("%@ · 替换 %lld 处", "a.txt", 1) == "a.txt · 1 replacement")
            #expect(KitL10n.format("%@ · 替换 %lld 处", "a.txt", 4) == "a.txt · 4 replacements")
            #expect(KitL10n.format("正在补齐用量记录 %@（已读完 %lld / %lld 个文件）", "x", 1, 1) == "Filling in usage records x (1 of 1 file read)")
            #expect(KitL10n.format("正在补齐用量记录 %@（已读完 %lld / %lld 个文件）", "x", 1, 5) == "Filling in usage records x (1 of 5 files read)")
        }
        KitL10n.$locale.withValue(Self.zh) { #expect(KitL10n.format("%lld 字", 1) == "1 字") }
    }
}
