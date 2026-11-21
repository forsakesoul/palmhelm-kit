import Foundation
import Testing
@testable import PalmhelmKit

// #21 S2 派发流程规则：旧 Bridge 识别、固定错误的恢复动作、连接代次核对与延迟响应。
@Suite struct IssueTaskFlowTests {
    struct Fixture: Error {}

    @Test func legacyOptions404MustSayUpgrade() {
        // 真实旧 Bridge 的 404 体：{"error":"not_found"}（bodyNotFound），options 路由上它表示没有该功能。
        let body = Data(#"{"error":"not_found"}"#.utf8)
        let err = IssueTaskError.failure(status: 404, body: body, optionsRoute: true)
        #expect(err.isUnsupportedBridge)
        #expect(IssueTaskFlow.classify(err) == .legacyBridge)
        #expect(IssueTaskRules.errorCopy(err).contains("升级"))
    }

    @Test func issueNotFoundIsNotMistakenForAnOldBridge() {
        let body = Data(#"{"error":"not_found"}"#.utf8)
        let err = IssueTaskError.failure(status: 404, body: body, optionsRoute: false)
        #expect(!err.isUnsupportedBridge)
        #expect(IssueTaskFlow.classify(err) == .refused(code: "not_found", recovery: .none))
        #expect(IssueTaskRules.errorCopy(err).contains("找不到这个 Issue"))
    }

    @Test func networkFailureIsUnknownNotRefused() {
        #expect(IssueTaskFlow.classify(URLError(.timedOut)) == .unknown)
        #expect(IssueTaskFlow.classify(BridgeError.decoding) == .unknown)
    }

    @Test func staleConnectionResultsAreDiscarded() {
        let ok: Result<Int, Error> = .success(1)
        if case .discarded = IssueTaskFlow.resolve(ok, started: IssueTaskScope(epoch: 3, draft: 0), current: IssueTaskScope(epoch: 4, draft: 0)) {} else { Issue.record("old-connection success must be discarded") }
        if case let .value(v) = IssueTaskFlow.resolve(ok, started: IssueTaskScope(epoch: 3, draft: 0), current: IssueTaskScope(epoch: 3, draft: 0)) { #expect(v == 1) } else { Issue.record("expected value") }
    }

    @Test func recoveryActionsFollowTheCode() {
        #expect(IssueTaskFlow.recovery(for: "source_changed") == .refreshDetail)
        #expect(IssueTaskFlow.recovery(for: "destination_changed") == .refreshOptions)
        #expect(IssueTaskFlow.recovery(for: "preview_changed") == .repreview)
        #expect(IssueTaskFlow.recovery(for: "content_blocked") == .none)
    }

    /// 延迟假传输：create 在途时连接切换，结果必须被丢弃。
    struct DelayedTransport: IssueTaskTransport {
        let delay: UInt64
        let createResult: Result<IssueTaskCreated, Error>
        func issueTaskOptions() async throws -> IssueTaskOptions { throw Fixture() }
        func issueTaskList(sourceId: String, page: Int) async throws -> IssueTaskListPage { throw Fixture() }
        func issueTaskDetail(sourceId: String, number: Int) async throws -> IssueTaskDetail { throw Fixture() }
        func issueTaskPreview(_ request: IssueTaskRequest) async throws -> IssueTaskPreview { throw Fixture() }
        func issueTaskCreate(_ request: IssueTaskRequest) async throws -> IssueTaskCreated {
            try await Task.sleep(nanoseconds: delay)
            return try createResult.get()
        }
    }

    @MainActor
    @Test func acceptedAfterConnectionChangeIsDiscardedAtTheSeam() async throws {
        var epoch = 1
        let transport = DelayedTransport(delay: 50_000_000, createResult: .success(IssueTaskCreated(accepted: true, eventKey: "api:d:u")))
        let request = IssueTaskRequest(targetId: "t", destinationVersion: "v", source: .manual(title: "x", description: "y", referenceUrl: nil), instructions: "", ackClosed: false, clientMsgId: "u", textDigest: "d")
        let start = epoch
        let task = Task { () -> Result<IssueTaskCreated, Error> in
            do { return .success(try await transport.issueTaskCreate(request)) } catch { return .failure(error) }
        }
        epoch = 2 // 在途时切换连接
        let result = await task.value
        let resolved = IssueTaskFlow.resolve(result, started: IssueTaskScope(epoch: start, draft: 0), current: IssueTaskScope(epoch: epoch, draft: 0))
        if case .discarded = resolved {} else { Issue.record("late success on the old connection must be discarded") }
    }

    @Test func unknownCreateResultSurfacesAsUnknownWithoutRefusing() async {
        let transport = DelayedTransport(delay: 0, createResult: .failure(URLError(.networkConnectionLost)))
        let request = IssueTaskRequest(targetId: "t", destinationVersion: "v", source: .manual(title: "x", description: "y", referenceUrl: nil), instructions: "", ackClosed: false, clientMsgId: "u", textDigest: "d")
        let result: Result<IssueTaskCreated, Error>
        do { result = .success(try await transport.issueTaskCreate(request)) } catch { result = .failure(error) }
        if case let .failed(f) = IssueTaskFlow.resolve(result, started: IssueTaskScope(epoch: 1, draft: 0), current: IssueTaskScope(epoch: 1, draft: 0)) {
            #expect(f == .unknown)
        } else {
            Issue.record("expected unknown")
        }
    }

    // MARK: A1-190 F1 / F2

    @Test func draftRevisionChangesOnContentOnly() {
        var d = IssueTaskDraft()
        let r0 = d.revision
        d.instructions = "改"
        #expect(d.revision == r0 + 1, "内容变化递增版本")
        d.setPreview(nil)
        #expect(d.revision == r0 + 1, "预览本身不是草稿内容")
        d.instructions = "改"
        #expect(d.revision == r0 + 1, "值未变化不递增")
    }

    @Test func readResultFromAnEditedDraftIsDiscarded() {
        let started = IssueTaskScope(epoch: 1, draft: 3)
        let ok: Result<Int, Error> = .success(7)
        if case .discarded = IssueTaskFlow.resolve(ok, started: started, current: IssueTaskScope(epoch: 1, draft: 4)) {} else { Issue.record("draft-changed result must be discarded") }
        if case .value = IssueTaskFlow.resolve(ok, started: started, current: started) {} else { Issue.record("unchanged scope must deliver") }
    }

    /// 请求的字节与字典顺序无关：按稳定顺序编码后逐字节相同，且与原对象语义相等。
    @MainActor
    @Test func replayUsesTheStoredRequestVerbatim() throws {
        let req = IssueTaskRequest(targetId: "t", destinationVersion: "v", source: .manual(title: "x", description: "y", referenceUrl: nil),
                                   instructions: "附", ackClosed: false, clientMsgId: "u", textDigest: "d")
        let pending = IssueTaskPendingSubmission(request: req, summary: "[任务] x", targetId: "t")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(pending.request) == encoder.encode(req))
        #expect(pending.request == req)
    }

    /// 重投经过提交的唯一入口：传输层收到的请求与保存的请求语义相等（不重建 UUID 或正文）。
    struct RecordingTransport: IssueTaskTransport {
        let box: Box
        final class Box: @unchecked Sendable { var received: [IssueTaskRequest] = [] }
        func issueTaskOptions() async throws -> IssueTaskOptions { throw Fixture() }
        func issueTaskList(sourceId: String, page: Int) async throws -> IssueTaskListPage { throw Fixture() }
        func issueTaskDetail(sourceId: String, number: Int) async throws -> IssueTaskDetail { throw Fixture() }
        func issueTaskPreview(_ request: IssueTaskRequest) async throws -> IssueTaskPreview { throw Fixture() }
        func issueTaskCreate(_ request: IssueTaskRequest) async throws -> IssueTaskCreated {
            box.received.append(request)
            return IssueTaskCreated(accepted: true, eventKey: "api:d:u")
        }
    }

    @Test func replayReachesTheTransportWithTheStoredRequest() async {
        let req = IssueTaskRequest(targetId: "t", destinationVersion: "v", source: .manual(title: "x", description: "y", referenceUrl: nil),
                                   instructions: "", ackClosed: false, clientMsgId: "u", textDigest: "d")
        let pending = IssueTaskPendingSubmission(request: req, summary: "[任务] x", targetId: "t")
        let box = RecordingTransport.Box()
        _ = await IssueTaskFlow.createOnce(RecordingTransport(box: box), pending.request)
        #expect(box.received == [req], "重投收到的请求必须与保存的请求相同")
    }

    // MARK: R1 最新选择

    @Test func onlyTheLatestSelectionIsAdopted() {
        var gate = IssueTaskSelectionGate()
        let first = gate.next()
        let second = gate.next()
        #expect(!gate.isLatest(first), "较早的选择不再采纳")
        #expect(gate.isLatest(second))
    }

    // MARK: A1-190 / A1-192 原探针（按修复后的 seam 改写）

    @Test func latePreviewMustNotReenableEditedDraft() {
        var d = IssueTaskDraft()
        d.source = .manual; d.targetId = "a"; d.destinationVersion = "v"; d.title = "first"; d.description = "body"
        let started = d.revision
        let sent = d.previewRequest()!
        d.title = "second" // 预览在途时编辑
        #expect(d.previewRequest() != sent)
        let preview = IssueTaskPreview(text: "[任务] first", textDigest: "d", destinationVersion: "v", sourceVersion: nil)
        let accepted = d.acceptPreview(preview, startedAt: started)
        #expect(!accepted, "晚到的预览不得重新挂到已编辑的草稿上")
        #expect(d.createRequest(clientMsgId: "u") == nil)
    }

    @Test func unknownRetryMustNotPairOldIdWithEditedContent() {
        var d = IssueTaskDraft()
        d.source = .manual; d.targetId = "a"; d.destinationVersion = "v"; d.title = "first"; d.description = "body"
        let preview = IssueTaskPreview(text: "[任务] first", textDigest: "d", destinationVersion: "v", sourceVersion: nil)
        d.acceptPreview(preview, startedAt: d.revision)
        let original = d.createRequest(clientMsgId: "u")!
        d.instructions = "edited" // 编辑后旧请求由 sheet 放弃；同一 UUID 不得搭配新正文
        #expect(d.createRequest(clientMsgId: "u") != original)
    }

    @Test func lastSelectedIssueMustWin() {
        var gate = IssueTaskSelectionGate()
        var d = IssueTaskDraft(); d.sourceId = "s"
        let first = gate.next()
        let second = gate.next()
        let a = IssueTaskDetail(number: 1, title: "first", state: "open", updatedAt: "u", url: "", body: "a", sourceVersion: "a")
        let b = IssueTaskDetail(number: 2, title: "last-click", state: "open", updatedAt: "u", url: "", body: "b", sourceVersion: "b")
        // 第二次点选的结果先回：采纳；第一次的结果后回：不得覆盖。
        if gate.isLatest(second) { d.issue = b }
        if gate.isLatest(first) { d.issue = a }
        #expect(d.issue?.number == 2)
    }
}
