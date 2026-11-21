import Foundation
import Testing
@testable import PalmhelmKit

@Suite struct ActivityTests {
    @Test func offlineWinsWhenNotOnlineOrUnknown() {
        #expect(ThreadActivity.activity(online: false, status: .working, pending: 0) == .offline)
        #expect(ThreadActivity.activity(online: false, status: .blocked, pending: 2) == .offline)
        #expect(ThreadActivity.activity(online: nil, status: nil, pending: 0) == .offline)
        #expect(ThreadActivity.activity(online: nil, status: nil, pending: 3) == .offline)
    }

    @Test func waitingForPendingOrBlocked() {
        #expect(ThreadActivity.activity(online: true, status: .working, pending: 1) == .waiting)
        #expect(ThreadActivity.activity(online: true, status: .blocked, pending: 0) == .waiting)
        #expect(ThreadActivity.activity(online: true, status: nil, pending: 1) == .waiting)
    }

    @Test func workingOnlyWhenStatusWorking() {
        #expect(ThreadActivity.activity(online: true, status: .working, pending: 0) == .working)
        #expect(ThreadActivity.activity(online: nil, status: .working, pending: 0) == .working, "online 缺省但有状态：不当离线")
    }

    @Test func everythingElseIsIdle() {
        #expect(ThreadActivity.activity(online: true, status: .idle, pending: 0) == .idle)
        #expect(ThreadActivity.activity(online: true, status: .done, pending: 0) == .idle)
        #expect(ThreadActivity.activity(online: true, status: .unknown, pending: 0) == .idle)
        #expect(ThreadActivity.activity(online: true, status: nil, pending: 0) == .idle)
    }

    @Test func elapsedLabelBoundaries() {
        #expect(ThreadActivity.elapsedLabel(seconds: 0) == "刚开始")
        #expect(ThreadActivity.elapsedLabel(seconds: 59) == "刚开始")
        #expect(ThreadActivity.elapsedLabel(seconds: 60) == "1 分钟")
        #expect(ThreadActivity.elapsedLabel(seconds: 3599) == "59 分钟")
        #expect(ThreadActivity.elapsedLabel(seconds: 3600) == "1 小时")
        #expect(ThreadActivity.elapsedLabel(seconds: 3780) == "1 小时 3 分")
        #expect(ThreadActivity.elapsedLabel(seconds: 7200) == "2 小时")
        #expect(ThreadActivity.elapsedLabel(seconds: -5) == "刚开始", "负数（时钟回拨）不显示负时长")
    }

    @Test func workingLineFormat() {
        #expect(ThreadActivity.workingLine(seconds: 120) == "工作中 · 2 分钟")
        #expect(ThreadActivity.workingLine(seconds: 5) == "工作中 · 刚开始")
    }

    // F2：唯一文案映射；列表、chip、底部提示都由同一 ActivityKind 推导
    @Test func describeIsTheSingleTextMapping() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(ThreadActivity.describe(kind: .offline, since: now, now: now) == "离线", "离线覆盖工作中的时长")
        #expect(ThreadActivity.describe(kind: .waiting, since: now, now: now) == "等你", "等你覆盖工作中")
        #expect(ThreadActivity.describe(kind: .working, since: now.addingTimeInterval(-120), now: now) == "工作中 · 2 分钟")
        #expect(ThreadActivity.describe(kind: .working, since: nil, now: now) == "工作中")
        #expect(ThreadActivity.describe(kind: .idle, since: nil, now: now) == "空闲")
    }

    @Test func doneAndUnknownDescribeAsIdle() {
        let now = Date()
        for st: AgentStatus in [.done, .unknown] {
            let kind = ThreadActivity.activity(online: true, status: st, pending: 0)
            #expect(ThreadActivity.describe(kind: kind, since: nil, now: now) == "空闲", "\(st)")
        }
    }

    @Test func dotAndTextComeFromTheSameKind() {
        // 同一输入推出的点与文字必须一致：waiting 覆盖 working，offline 覆盖 working
        let now = Date(timeIntervalSince1970: 1)
        let waiting = ThreadActivity.activity(online: true, status: .working, pending: 1)
        #expect(waiting == .waiting && ThreadActivity.describe(kind: waiting, since: now, now: now) == "等你")
        let offline = ThreadActivity.activity(online: false, status: .working, pending: 0)
        #expect(offline == .offline && ThreadActivity.describe(kind: offline, since: now, now: now) == "离线")
    }

    @Test func approvalProjectNameStripsCandidatePrefixOnly() {
        #expect(ApprovalText.projectName(ofLabel: "候选：proj") == "proj")
        #expect(ApprovalText.projectName(ofLabel: "proj") == "proj")
        #expect(ApprovalText.projectName(ofLabel: "候选：") == "")
    }
}
