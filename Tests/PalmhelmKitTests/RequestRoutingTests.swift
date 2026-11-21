import Testing
@testable import PalmhelmKit

// h10a K2 / K4：请求卡类型映射（样式 A）与无目标条目的分类（表驱动）。
@Suite struct RequestRoutingTests {
    @Test func cardKindSymbolsLabelsAndTones() {
        let table: [(RequestCardKind, String, String, RequestCardTone)] = [
            (.approval, "hand.raised", "审批", .warn),
            (.question, "questionmark.bubble", "提问", .accent),
            (.plan, "list.bullet.clipboard", "计划", .accent),
            (.alert, "clock", "已超时 / 失败", .bad),
        ]
        for (kind, symbol, label, tone) in table {
            #expect(kind.symbolName == symbol)
            #expect(kind.label == label)
            #expect(kind.tone == tone)
        }
        #expect(RequestCardKind.allCases.count == 4)
    }

    @Test func badgesAreIndependentTexts() {
        #expect(RequestCardBadge.allCases.map(\.label) == ["离线", "只读", "推测归属"])
    }

    @Test func orphanRoutingTable() {
        let table: [(OrphanItem, OrphanRoute)] = [
            (.request(.approval), .pendingRequest),
            (.request(.question), .pendingRequest),
            (.request(.plan), .pendingRequest),
            (.alert, .alert),
            (.receipt("rejected:target_not_verified"), .alert),
            (.receipt("switched:proj@3（已切换）"), .drop),
            (.receipt("ack:key:p1"), .drop),
            (.receipt("queued:task:1"), .drop),
            (.receipt("配对成功"), .drop),
        ]
        for (item, route) in table { #expect(ThreadRouting.route(item) == route, "\(item)") }
    }
}
