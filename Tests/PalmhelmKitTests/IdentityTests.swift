import XCTest
@testable import PalmhelmKit

final class IdentityTests: XCTestCase {
    private func target(_ project: String = "remote-herdr-bridge", agent: String? = "task_b373_design", kind: String? = "claude", status: String? = nil,
                        topic: String? = nil, role: String? = "design", group: String? = "b373", ws: String? = "Palmhelm", tab: String? = "编组", pane: String? = "w1P:p1T") -> TargetSummary {
        TargetSummary(projectName: project, online: true, targetId: "target:\(project)", agentName: agent, kind: kind, status: status,
                      topic: topic.map { TargetTopic(text: $0, source: "title") }, role: role, groupShort: group,
                      location: TargetLocation(workspace: ws, tab: tab, pane: pane))
    }

    func testTitleFallsBackFromTopicToTabToWorkspace() {
        XCTAssertEqual(ThreadIdentity.title(target(topic: "统计图配色")), "统计图配色")
        XCTAssertEqual(ThreadIdentity.title(target(topic: "  ")), "编组", "空主题退回标签名")
        XCTAssertEqual(ThreadIdentity.title(target(tab: "Claude Code")), "Palmhelm · remote-herdr-bridge", "通用标签名跳过")
        XCTAssertEqual(ThreadIdentity.title(target(ws: nil, tab: "fish")), "remote-herdr-bridge")
        XCTAssertEqual(ThreadIdentity.title(TargetSummary(projectName: "docs")), "docs", "旧 Bridge 只有项目名")
    }

    func testLineUsesRoleThenNonGenericNameAndSkipsUnnamed() {
        XCTAssertEqual(ThreadIdentity.line(target()), "Claude · 设计 b373 · remote-herdr-bridge")
        XCTAssertEqual(ThreadIdentity.line(target(agent: "reviewer", role: nil)), "Claude · reviewer · remote-herdr-bridge")
        XCTAssertEqual(ThreadIdentity.line(target(agent: nil, kind: "codex", role: nil)), "Codex · remote-herdr-bridge", "未命名 agent 只剩种类与项目")
        XCTAssertEqual(ThreadIdentity.line(target(agent: "claude", role: nil)), "Claude · remote-herdr-bridge", "通用名不当名字")
        XCTAssertEqual(ThreadIdentity.line(TargetSummary(projectName: "docs")), "docs")
    }

    private func conv(_ project: String = "docs", agent: String? = nil, role: String? = nil, topic: String? = nil, repo: String? = nil,
                      tab: String? = nil, pane: String? = nil) -> TargetSummary {
        TargetSummary(projectName: project, online: true, targetId: "target:\(project)", agentName: agent,
                      topic: topic.map { TargetTopic(text: $0, source: "lastUser") }, role: role,
                      location: TargetLocation(workspace: nil, tab: tab, pane: pane),
                      repo: repo.map { TargetRepo(name: $0, branch: "main") })
    }

    func testConversationTitleUsesIdentityNotTopic() {
        XCTAssertEqual(ThreadIdentity.conversationTitle(conv(role: "design", topic: "修复滚动", repo: "palmhelm")), "设计 · palmhelm")
        XCTAssertEqual(ThreadIdentity.conversationTitle(conv(role: "execute", repo: "palmhelm")), "执行 · palmhelm")
        XCTAssertEqual(ThreadIdentity.conversationTitle(conv(agent: "reviewer", repo: "palmhelm")), "reviewer · palmhelm")
        XCTAssertEqual(ThreadIdentity.conversationTitle(conv(agent: "task_000000000000_execute2", repo: "palmhelm", tab: "Claude Code", pane: "w4V:p5")), "窗格 p5 · palmhelm", "自动名与通用标签跳过，退到窗格")
        XCTAssertEqual(ThreadIdentity.conversationTitle(conv(agent: "claude", repo: "palmhelm", tab: "编组")), "编组 · palmhelm")
        XCTAssertEqual(ThreadIdentity.conversationTitle(conv("docs")), "docs", "旧 Bridge 只有项目名")
        XCTAssertEqual(ThreadIdentity.conversationTitle(conv("task_000000000000_design", role: "design")), "设计", "自动任务名不当项目")
        XCTAssertEqual(ThreadIdentity.conversationTitle(conv("docs", agent: " docs ", repo: nil)), "docs", "完全相同只显示一次")
        XCTAssertEqual(ThreadIdentity.conversationTitle(nil), ScreenCopy.tabChat)
        XCTAssertEqual(ThreadIdentity.conversationTitle(conv("  ", repo: "  ")), ScreenCopy.tabChat, "全空白退回“对话”")
    }

    func testConversationTitleIgnoresTopicChangesButListTitleFollowsThem() {
        let a = conv(role: "design", topic: "第一件事", repo: "palmhelm")
        let b = conv(role: "design", topic: "完全不同的最新消息", repo: "palmhelm")
        XCTAssertEqual(ThreadIdentity.conversationTitle(a), ThreadIdentity.conversationTitle(b))
        XCTAssertNotEqual(ThreadIdentity.title(a), ThreadIdentity.title(b), "列表标题规则不变")
        XCTAssertEqual(ThreadIdentity.title(a), "第一件事")
    }

    func testConversationTitleTrimsRoleAndOnlyFiltersAsciiGeneratedNames() {
        XCTAssertEqual(ThreadIdentity.conversationTitle(conv(agent: "reviewer", role: " design ", repo: "docs")), "设计 · docs", "role 先 trim 再优先于 agent 名")
        XCTAssertEqual(ThreadIdentity.conversationTitle(conv("docs", agent: "task_ａｂｃｄｅｆ_execute")), "task_ａｂｃｄｅｆ_execute · docs", "全角十六进制不是自动名")
        XCTAssertFalse(ThreadIdentity.isGeneratedTaskName("task_ａｂｃｄｅｆ_execute"))
        XCTAssertFalse(ThreadIdentity.isGeneratedTaskName("task_０２１３７e_execute"))
    }

    func testGeneratedTaskNameIsMatchedWholeString() {
        XCTAssertTrue(ThreadIdentity.isGeneratedTaskName("task_000000000000_advisor"))
        XCTAssertTrue(ThreadIdentity.isGeneratedTaskName("task_000000000000_execute2"))
        XCTAssertFalse(ThreadIdentity.isGeneratedTaskName("task_notes"))
        XCTAssertFalse(ThreadIdentity.isGeneratedTaskName("my_task_000000000000_execute"))
        XCTAssertFalse(ThreadIdentity.isGeneratedTaskName("reviewer2"))
    }

    func testLocationShowsPanePartOnly() {
        XCTAssertEqual(ThreadIdentity.location(target()), "Palmhelm › 编组 · 窗格 p1T")
        XCTAssertEqual(ThreadIdentity.location(target(ws: nil, tab: nil, pane: nil)), nil)
    }

    func testThreadKeyIncludesBridge() {
        XCTAssertEqual(ThreadIdentity.key(bridgeId: "a1b2", targetId: "target:x"), "a1b2/target:x")
        XCTAssertEqual(ThreadIdentity.key(bridgeId: nil, targetId: "target:x"), "local/target:x")
    }

    func testStateDecodesNewFieldsAndOldStateStillDecodes() throws {
        let json = #"""
        {"bridge":{"id":"0123456789abcdef","name":"mac","version":"1","dispatch":true},
         "spaces":[{"workspace":"Palmhelm","agentlessTabCount":1}],
         "binding":null,"occupancy":"idle","targets":[{"id":"target:p","projectName":"p","agentName":null,"group":null,"online":true,
          "kind":"codex","status":"working","topic":{"text":"t","source":"lastUser"},"role":"advisor","groupShort":"b373",
          "location":{"workspace":"Palmhelm","tab":"编组","pane":"w1P:p1W"}}],
         "history":{"highWater":0,"items":[]},"device":{"id":"d","name":"n","paused":false,"permission":"readonly"}}
        """#
        let s = try JSONDecoder().decode(BridgeState.self, from: Data(json.utf8))
        XCTAssertEqual(s.bridge?.id, "0123456789abcdef")
        XCTAssertEqual(s.spaces, [SpaceInfo(workspace: "Palmhelm", agentlessTabCount: 1)])
        XCTAssertEqual(s.targets.first?.topic?.source, "lastUser")
        XCTAssertEqual(s.targets.first?.location?.pane, "w1P:p1W")
        XCTAssertEqual(s.device?.canControl, false)
        let old = #"{"binding":null,"occupancy":"idle","targets":[{"projectName":"p"}],"history":{"highWater":0,"items":[]},"device":{"id":"d","name":"n","paused":false}}"#
        let o = try JSONDecoder().decode(BridgeState.self, from: Data(old.utf8))
        XCTAssertNil(o.bridge)
        XCTAssertEqual(o.device?.canControl, true, "旧 Bridge 没有权限字段按 control")
    }

    func testTargetsEventDecodes() {
        let f = SSEFrame(id: nil, event: "targets", data: #"{"targets":[{"projectName":"p","id":"target:p","status":"blocked"}],"spaces":[]}"#)
        XCTAssertEqual(BridgeEventDecoder.decode(f), .targets([TargetSummary(projectName: "p", targetId: "target:p", status: "blocked")], spaces: []))
    }
}

final class LensTests: XCTestCase {
    private func item(_ key: String, ws: String?, tab: String? = nil, role: String? = nil, status: String? = nil, last: Int = 0, pending: Int = 0, unread: Bool = false, pinned: Bool = false) -> LensInput {
        let t = TargetSummary(projectName: key, targetId: key, status: status, role: role, location: TargetLocation(workspace: ws, tab: tab))
        return LensInput(key: key, target: t, title: key, lastActivity: last, pendingApprovals: pending, unread: unread, pinned: pinned)
    }

    func testSpacesGroupByWorkspaceWithStableRoleOrderAndFooter() {
        let items = [
            item("adv", ws: "Palmhelm", role: "advisor", last: 9),
            item("solo", ws: "docs", status: "working"),
            item("des", ws: "Palmhelm", role: "design", last: 1, pending: 1),
            item("exe", ws: "Palmhelm", role: "execute", last: 5),
            item("sys", ws: nil),
        ]
        let s = LensGrouping.sections(.spaces, items, spaces: [SpaceInfo(workspace: "Palmhelm", agentlessTabCount: 2)])
        XCTAssertEqual(s.map(\.title), ["docs", "Palmhelm", LensGrouping.otherSpace], "按名字固定排序，“其他”在最后")
        XCTAssertEqual(s[1].keys, ["des", "exe", "adv"], "组内按 设计 → 执行 → 顾问，不按最近活动")
        XCTAssertEqual(s[1].urgency, .waiting, "组的胶囊取组内最紧急")
        XCTAssertEqual(s[1].footer, "另有 2 个标签没有 agent")
        XCTAssertNil(s[0].footer)
    }

    // h10a K1：收件箱只含等你与工作中；未读与空闲不出现，段内钉住在前。
    func testInboxOrdersByUrgencyPinnedFirstAndHidesUnreadAndIdle() {
        let items = [
            item("old-unread", ws: nil, last: 3, unread: true),
            item("pinned-unread", ws: nil, last: 1, unread: true, pinned: true),
            item("blocked", ws: nil, status: "blocked"),
            item("work", ws: nil, status: "working", unread: true),
            item("quiet", ws: nil, status: "idle"),
        ]
        let s = LensGrouping.sections(.inbox, items)
        XCTAssertEqual(s.map(\.urgency), [.waiting, .working])
        XCTAssertEqual(s[0].keys, ["blocked"])
        XCTAssertEqual(s[1].keys, ["work"])
        XCTAssertFalse(s.contains { $0.keys.contains("quiet") || $0.keys.contains("old-unread") || $0.keys.contains("pinned-unread") })
    }

    func testMarksAreDevicesOwnAndSurviveReload() {
        let d = UserDefaults(suiteName: "palmhelm.test.PalmhelmKit")!
        let key = "marks.\(UUID().uuidString)"
        defer { d.removeObject(forKey: key) }
        let store = ThreadMarkStore(defaults: d, storageKey: key)
        XCTAssertTrue(store.marks("k").isUnread(lastActivity: 1))
        store.markSeen("k", through: 5)
        XCTAssertFalse(store.marks("k").isUnread(lastActivity: 5))
        XCTAssertTrue(store.marks("k").isUnread(lastActivity: 6))
        store.markUnread("k"); store.setPinned("k", true)
        let reloaded = ThreadMarkStore(defaults: d, storageKey: key)
        XCTAssertTrue(reloaded.marks("k").isUnread(lastActivity: 5))
        XCTAssertTrue(reloaded.marks("k").pinned)
        reloaded.markSeen("k", through: 2)
        XCTAssertEqual(reloaded.marks("k").seen, 5, "已看位置不倒退")
        XCTAssertFalse(reloaded.marks("k").markedUnread)
    }
}

// A1-089 回归
final class IdentityReviewRegressionTests: XCTestCase {
    func testRealWorkspaceNamedOtherIsNotMergedWithMissingWorkspace() {
        let named = LensInput(key: "named", target: TargetSummary(projectName: "p", targetId: "named", location: TargetLocation(workspace: "其他")), title: "n", lastActivity: 1)
        let none = LensInput(key: "system", target: nil, title: "系统", lastActivity: 2)
        let s = LensGrouping.sections(.spaces, [named, none], spaces: [SpaceInfo(workspace: "其他", agentlessTabCount: 3)])
        XCTAssertEqual(s.count, 2, "真实工作区“其他”与缺工作区分两组")
        XCTAssertEqual(s.first { $0.keys == ["named"] }?.footer, "另有 3 个标签没有 agent")
        XCTAssertNil(s.first { $0.keys == ["system"] }?.footer)
    }

    func testSpacesKeepEachTabTogetherBeforeRoleOrder() {
        func it(_ k: String, _ tab: String, _ role: String) -> LensInput {
            LensInput(key: k, target: TargetSummary(projectName: k, targetId: k, role: role, location: TargetLocation(workspace: "W", tab: tab)), title: k, lastActivity: 0)
        }
        let s = LensGrouping.sections(.spaces, [it("b-des", "B", "design"), it("a-exe", "A", "execute"), it("a-des", "A", "design"), it("b-adv", "B", "advisor")])
        XCTAssertEqual(s.first?.keys, ["a-des", "a-exe", "b-des", "b-adv"], "同一标签的编组排在一起")
    }

    func testTiesBreakByKeyRegardlessOfInputOrder() {
        let a = LensInput(key: "a", target: nil, title: "同名", lastActivity: 5), b = LensInput(key: "b", target: nil, title: "同名", lastActivity: 5)
        for lens in ThreadLens.allCases {
            XCTAssertEqual(LensGrouping.sections(lens, [b, a]).flatMap(\.keys), LensGrouping.sections(lens, [a, b]).flatMap(\.keys), "\(lens)")
        }
    }

    func testBaselineSeedsOnlyOncePerBridge() {
        let d = UserDefaults(suiteName: "palmhelm.test.PalmhelmKit")!
        let key = "marks.\(UUID().uuidString)"
        defer {
            d.removeObject(forKey: key)
            d.removeObject(forKey: key + ".baseline.m1")
            d.removeObject(forKey: key + ".baseline.m2")
        }
        let store = ThreadMarkStore(defaults: d, storageKey: key)
        store.seedBaselineIfNeeded(bridge: "m1", [(key: "old", lastActivity: 9)])
        XCTAssertFalse(store.marks("old").isUnread(lastActivity: 9), "装上新版本前的旧线程算已看")
        // 之后经事件流来了新线程 B，用户没打开；再次刷新不应把它当成已读
        store.seedBaselineIfNeeded(bridge: "m1", [(key: "old", lastActivity: 9), (key: "new", lastActivity: 12)])
        XCTAssertTrue(store.marks("new").isUnread(lastActivity: 12))
        // 另一台 Mac 各自建立一次基线
        store.seedBaselineIfNeeded(bridge: "m2", [(key: "m2/x", lastActivity: 3)])
        XCTAssertFalse(store.marks("m2/x").isUnread(lastActivity: 3))
    }

    func testRevealEncodesTargetIdExactlyOnce() async throws {
        final class Capture: URLProtocol, @unchecked Sendable {
            nonisolated(unsafe) static var paths: [String] = []
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                Capture.paths.append(request.url!.absoluteString)
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("{}".utf8)); client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [Capture.self]
        for (id, want) in [("target:demo space", "target:demo%20space"), ("target:demo/path", "target:demo%2Fpath"), ("target:设计", "target:%E8%AE%BE%E8%AE%A1")] {
            let c = BridgeClient(endpoint: BridgeEndpoint(host: "127.0.0.1", port: 1), token: "t", session: URLSession(configuration: cfg))
            let r = try await c.reveal(targetId: id)
            XCTAssertEqual(r, .ok)
            XCTAssertEqual(Capture.paths.last, "http://127.0.0.1:1/v1/targets/\(want)/reveal")
            XCTAssertEqual(Capture.paths.last!.components(separatedBy: "/v1/targets/")[1].replacingOccurrences(of: "/reveal", with: "").removingPercentEncoding, id, "服务端单次解码还原原 id")
        }
    }
}
