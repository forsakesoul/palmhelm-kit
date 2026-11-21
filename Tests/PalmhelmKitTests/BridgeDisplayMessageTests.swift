import Foundation
import Testing
@testable import PalmhelmKit

@Suite struct BridgeDisplayMessageTests {
    private func en<T>(_ b: () -> T) -> T { KitL10n.$locale.withValue(Locale(identifier: "en"), operation: b) }
    private func zh<T>(_ b: () -> T) -> T { KitL10n.$locale.withValue(Locale(identifier: "zh-Hans"), operation: b) }
    private func item(_ json: String) throws -> HistoryItem {
        try JSONDecoder().decode(HistoryItem.self, from: Data(#"{"seq":1,"uuid":"nblocked:x","text":"原文","kind":"text","displayMessage":\#(json)}"#.utf8))
    }
    private func sample(_ sig: String) -> [String: DisplayMessage.Param] {
        var p: [String: DisplayMessage.Param] = [:]
        for raw in sig.split(separator: ",") {
            let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
            var name = parts[0]; if name.hasSuffix("?") { name.removeLast() }
            let spec = parts.count > 1 ? parts[1] : "t"
            switch spec.first! {
            case "n": p[name] = .count(name.hasPrefix("reverified") ? 1 : 3)
            case "l": p[name] = .lines([["kind": .text("claude"), "agent": .text("w1")], ["kind": .text("codex"), "agent": .text("w2")]])
            case "e":
                let g = String(spec.dropFirst(2))
                p[name] = .text(g == "pausedNote" ? "1" : ["queueReason": "paused", "steerReason": "terminal_changed", "notVerified": "drift"][g]!)
            default: p[name] = .text("login-page")
            }
        }
        return p
    }

    @Test func everyKeyRendersEnglishWithNoUnfilledTokenAndChineseTemplateMatches() {
        for (key, sig) in BridgeDisplayMessage.signatures where key != "watch.activity" { // watch.activity 的 lines 形状不同，见 WatchActivityTests 与 fixture
            let m = DisplayMessage(key: key, params: sample(sig))
            let e = en { BridgeDisplayMessage.text(m) }
            #expect(e != nil && !(e ?? "").contains("{") && !(e ?? "").isEmpty, "\(key): \(e ?? "nil")")
            let z = zh { BridgeDisplayMessage.text(m) }
            #expect(z != nil && !(z ?? "").contains("{"), "\(key) zh")
            #expect(e != z, "\(key) en == zh")
        }
    }

    @Test func canonicalChineseMatchesBridgeBytes() {
        func z(_ k: String, _ p: [String: DisplayMessage.Param]) -> String? { zh { BridgeDisplayMessage.text(DisplayMessage(key: k, params: p)) } }
        #expect(z("native.blocked", ["target": .text("login-page")]) == "[login-page] agent 正在等待审批或回答问题，请到终端处理（Bridge 不会代答）。")
        #expect(z("native.blocked_reminder", ["target": .text("t"), "minutes": .count(5), "name": .text("n")]) == "[t] agent 等待审批或回答已超过 5 分钟，仍未处理。请到终端处理；若要放弃这条命令，发「重置占用 n」。")
        #expect(z("native.unknown.generic", ["target": .text("t")]) == "[t] 这条命令的状态未知，已暂停该目标，未自动重发。确认后可发「重置占用 项目名」。")
        #expect(z("routing.expired", ["target": .text("t")]) == "[t] 接续确认已过期，原消息未执行，请重新发送。")
        #expect(z("inbox.withdrawn", [:]) == "已撤回，未发出。")
    }

    @Test func englishStatesKeepTheirConsequences() {
        func e(_ k: String, _ p: [String: DisplayMessage.Param] = [:]) -> String { en { BridgeDisplayMessage.text(DisplayMessage(key: k, params: p)) } ?? "nil" }
        #expect(e("native.unknown.timeout", ["target": .text("t")]).contains("unknown"))
        #expect(e("native.unknown.generic", ["target": .text("t")]).contains("nothing was resent"))
        #expect(e("native.unknown.generic", ["target": .text("t")]).contains("重置占用 项目名"))
        #expect(e("native.steer.not_sent", ["target": .text("t"), "reason": .text("terminal_changed")]).contains("will not be resent"))
        #expect(!e("native.steer.delivered_unverified").contains("Completed"))
        #expect(e("inbox.rejected.target_changed", ["name": .text("app")]).contains("切换到 app"))
        #expect(e("inbox.rejected.target_changed").contains("切换到 目标名"))
        #expect(e("native.hold.identity").contains("page"))
        #expect(e("native.busy.single", ["target": .text("t"), "summary": .text("编译")]).contains("(screen summary; source unverified)"))
    }

    @Test func placeholdersAreLocalizedAndNamesAreData() {
        let m = DisplayMessage(key: "routing.expired", params: ["target": .placeholder("unnamed")])
        #expect(en { BridgeDisplayMessage.text(m) } == "[Unnamed session] The continuation confirmation expired. The original message was not run; send it again.")
        let real = DisplayMessage(key: "routing.expired", params: ["target": .text("未命名会话")])
        #expect(en { BridgeDisplayMessage.text(real) }?.hasPrefix("[未命名会话]") == true)
    }

    @Test func invalidMessagesFallBack() {
        func e(_ m: DisplayMessage) -> String? { en { BridgeDisplayMessage.text(m) } }
        #expect(e(DisplayMessage(key: "nope", params: [:])) == nil)
        #expect(e(DisplayMessage(key: "native.blocked", params: [:])) == nil)
        #expect(e(DisplayMessage(key: "native.blocked", params: ["target": .count(1)])) == nil)
        #expect(e(DisplayMessage(key: "native.blocked", params: ["target": .text("a\nb")])) == nil)
        #expect(e(DisplayMessage(key: "native.blocked", params: ["target": .text(String(repeating: "x", count: 201))])) == nil)
        #expect(e(DisplayMessage(key: "native.blocked_reminder", params: ["target": .text("t"), "minutes": .count(-1), "name": .text("n")])) == nil)
        #expect(e(DisplayMessage(key: "native.blocked_reminder", params: ["target": .text("t"), "minutes": .count(1_000_001), "name": .text("n")])) == nil)
        #expect(e(DisplayMessage(key: "native.steer.not_sent", params: ["target": .text("t"), "reason": .text("made_up")])) == nil)
        #expect(e(DisplayMessage(key: "routing.expired", params: ["target": .placeholder("bogus")])) == nil)
    }

    @Test func decodingIsLenientAndRendersViaHistoryItem() throws {
        let ok = try item(#"{"key":"native.blocked","params":{"target":"login-page"}}"#)
        #expect(en { ok.localizedDisplayMessage }?.hasPrefix("[login-page] The agent is waiting") == true)
        #expect(zh { ok.localizedDisplayMessage } == nil) // 中文走原文
        for bad in [#""x""#, "42", "[]", #"{"params":{}}"#, #"{"key":1}"#, "null", #"{"key":"native.blocked","params":"x"}"#, #"{"key":"native.blocked","params":{"target":{"placeholder":"a","x":"b"}}}"#] {
            let it = try item(bad)
            #expect(en { it.localizedDisplayMessage } == nil, "\(bad)")
            #expect(it.text == "原文")
        }
        #expect(try JSONDecoder().decode(HistoryItem.self, from: Data(#"{"seq":1,"uuid":"u","text":"t","kind":"text"}"#.utf8)).displayMessage == nil)
    }

    @Test func candidatesAndSwitchedAreComposed() {
        let c = DisplayMessage(key: "routing.candidates", params: ["target": .text("app"), "lines": .lines([["kind": .text("claude"), "agent": .text("w1")], ["kind": .text("codex"), "agent": .text("w2")]])])
        #expect(en { BridgeDisplayMessage.text(c) } == "[app] A new session was detected. Confirm the target to continue (valid for 10 minutes):\n1. claude / w1\n2. codex / w2\nReply \"选 1\".")
        let tooMany = DisplayMessage(key: "routing.candidates", params: ["target": .text("app"), "lines": .lines(Array(repeating: ["kind": .text("k"), "agent": .text("a")], count: 9))])
        #expect(en { BridgeDisplayMessage.text(tooMany) } == nil)
        func sw(_ p: [String: DisplayMessage.Param]) -> String? { en { BridgeDisplayMessage.text(DisplayMessage(key: "inbox.switched", params: ["id": .text("t1"), "rev": .count(4)].merging(p) { $1 })) } }
        #expect(sw([:]) == "Target t1 is now at revision 4.")
        #expect(sw(["reverified": .count(1)]) == "Target t1 is now at revision 4. Target identity re-verified.")
        #expect(sw(["reverified": .count(1), "reverifiedPaused": .count(1)])?.hasSuffix("older unsent messages were paused and not resent.") == true)
        #expect(sw(["swapped": .text("app"), "swappedPaused": .count(2)]) == "Target t1 is now at revision 4. Switched to app; 2 older messages were paused and not resent.")
        #expect(sw(["reverified": .count(1), "swapped": .text("app")]) == "Target t1 is now at revision 4. Target identity re-verified. Switched to app.")
        #expect(sw(["reverifiedPaused": .count(1)]) == nil)       // 暂停说明必须伴随重新核验
        #expect(sw(["swappedPaused": .count(1)]) == nil)           // 计数必须伴随 swapped
        #expect(en { BridgeDisplayMessage.text(DisplayMessage(key: "inbox.switched", params: [:])) } == nil)
    }
}

@Suite struct DisplayMessageRoundTripTests {
    @Test func historyItemSurvivesEncodeDecode() throws {
        let src = #"{"seq":1,"uuid":"nblocked:x","text":"原文","kind":"text","displayMessage":{"key":"routing.candidates","params":{"target":{"placeholder":"unnamed"},"lines":[{"kind":"claude","agent":"w1"}]}},"displaySpans":[{"startUTF16":0,"endUTF16":2,"key":"hidden"}]}"#
        let a = try JSONDecoder().decode(HistoryItem.self, from: Data(src.utf8))
        let b = try JSONDecoder().decode(HistoryItem.self, from: try JSONEncoder().encode(a))
        #expect(a.displayMessage?.value != nil)
        #expect(a == b)
        let counts = try JSONDecoder().decode(HistoryItem.self, from: Data(#"{"seq":2,"uuid":"u","text":"t","kind":"text","displayMessage":{"key":"native.busy.multi","params":{"target":"t","count":3,"summary":"s"}}}"#.utf8))
        let c2 = try JSONDecoder().decode(HistoryItem.self, from: try JSONEncoder().encode(counts))
        #expect(counts == c2)
        #expect(KitL10n.$locale.withValue(Locale(identifier: "en")) { c2.localizedDisplayMessage } == KitL10n.$locale.withValue(Locale(identifier: "en")) { counts.localizedDisplayMessage })
        // 无有效值（畸形）写 null，再读仍是无值
        let bad = try JSONDecoder().decode(HistoryItem.self, from: Data(#"{"seq":3,"uuid":"u","text":"t","kind":"text","displayMessage":"x"}"#.utf8))
        #expect(try JSONDecoder().decode(HistoryItem.self, from: try JSONEncoder().encode(bad)).displayMessage?.value == nil)
    }
}


@Suite struct DisplayMessageStrictnessTests {
    private func en<T>(_ b: () -> T) -> T { KitL10n.$locale.withValue(Locale(identifier: "en"), operation: b) }
    private func item(_ json: String) throws -> HistoryItem {
        try JSONDecoder().decode(HistoryItem.self, from: Data(#"{"seq":1,"uuid":"u","text":"原文","kind":"text","displayMessage":\#(json)}"#.utf8))
    }

    @Test func illegalParamShapeOrExtraParamFallsBackOnlyThatItem() throws {
        let bad: [String] = [
            #"{"key":"native.hold.identity","params":{"name":true}}"#,                       // 布尔
            #"{"key":"native.hold.identity","params":{"name":{"placeholder":"hidden","x":"y"}}}"#,
            #"{"key":"native.released_uncertain","params":{"unexpected":"x"}}"#,              // 签名外参数
            #"{"key":"native.blocked","params":{"target":"t","extra":1}}"#,
            #"{"key":"inbox.switched","params":{"id":"a","rev":1,"junk":1}}"#,
        ]
        for j in bad { #expect(en { try! item(j).localizedDisplayMessage } == nil, "\(j)") }
        // 相邻合法条目不受影响
        #expect(en { try! item(#"{"key":"native.blocked","params":{"target":"t"}}"#).localizedDisplayMessage } != nil)
        let page = try JSONDecoder().decode([HistoryItem].self, from: Data(#"[{"seq":1,"uuid":"u","text":"a","kind":"text","displayMessage":{"key":"native.hold.identity","params":{"name":true}}},{"seq":2,"uuid":"u","text":"b","kind":"text","displayMessage":{"key":"native.blocked","params":{"target":"x"}}}]"#.utf8))
        #expect(en { page[0].localizedDisplayMessage } == nil && en { page[1].localizedDisplayMessage } != nil)
    }

    @Test func parametersAreInsertedLiterallyNeverReinterpreted() {
        func e(_ k: String, _ p: [String: DisplayMessage.Param]) -> String { en { BridgeDisplayMessage.text(DisplayMessage(key: k, params: p)) } ?? "nil" }
        let out = e("native.busy.single", ["target": .text("app"), "summary": .text("literal {target} and {summary} 😀 {")])
        #expect(out.contains("Currently doing: literal {target} and {summary} 😀 { (screen summary; source unverified)"))
        #expect(out.hasPrefix("[app] The target is busy"))
        #expect(e("native.blocked", ["target": .text("{count}{name}")]).hasPrefix("[{count}{name}] "))
    }

    @Test func summaryAllowsSixHundredBytesOtherTextOnlyTwoHundred() {
        func e(_ k: String, _ p: [String: DisplayMessage.Param]) -> String? { en { BridgeDisplayMessage.text(DisplayMessage(key: k, params: p)) } }
        #expect(e("native.busy.single", ["target": .text("t"), "summary": .text(String(repeating: "a", count: 600))]) != nil)
        #expect(e("native.busy.single", ["target": .text("t"), "summary": .text(String(repeating: "a", count: 601))]) == nil)
        #expect(e("native.blocked", ["target": .text(String(repeating: "a", count: 201))]) == nil)
    }
}


@Suite struct WatchActivityTests {
    private func en(_ p: [String: DisplayMessage.Param]) -> String? { KitL10n.$locale.withValue(Locale(identifier: "en")) { BridgeDisplayMessage.text(DisplayMessage(key: "watch.activity", params: p)) } }
    private func row(_ role: String, _ name: String, _ event: String, from: String? = nil, to: String? = nil) -> [String: DisplayMessage.Param] {
        var r: [String: DisplayMessage.Param] = ["role": .text(role), "name": .text(name), "event": .text(event)]
        if let from { r["from"] = .text(from) }; if let to { r["to"] = .text(to) }
        return r
    }
    @Test func rendersEveryEventAndKeepsNamesLiteral() {
        let out = en(["group": .text("alpha"), "lines": .lines([row("owner", "alpha_design", "appeared"), row("worker", "alpha_execute", "state_changed", from: "working", to: "ready"),
            row("advisor", "alpha_advisor", "left_group"), row("owner", "x", "disappeared"), row("owner", "x", "identity_changed"), row("owner", "x", "new_completion")])])
        #expect(out == "**[Group alpha]**\n- Owner · alpha\\_design: appeared\n- Worker · alpha\\_execute: working → ready for input\n- Advisor · alpha\\_advisor: left the group (name changed)\n- Owner · x: disappeared\n- Owner · x: observed identity changed (rediscovered)\n- Owner · x: new completion activity\nRole activity (Herdr sampling, not business status)")
    }
    @Test func invalidShapesFallBack() {
        let g: DisplayMessage.Param = .text("a")
        #expect(en(["group": g, "lines": .lines([])]) == nil)
        #expect(en(["group": g, "lines": .lines(Array(repeating: row("owner", "x", "appeared"), count: 13))]) == nil)
        #expect(en(["group": g, "lines": .lines([row("boss", "x", "appeared")])]) == nil)
        #expect(en(["group": g, "lines": .lines([row("owner", "x", "state_changed", from: "working")])]) == nil)
        #expect(en(["group": g, "lines": .lines([row("owner", "x", "appeared", from: "working", to: "ready")])]) == nil) // from/to 只属于 state_changed
        #expect(en(["group": g, "lines": .lines(Array(repeating: row("owner", "x", "appeared"), count: 12))]) != nil)
    }
}
