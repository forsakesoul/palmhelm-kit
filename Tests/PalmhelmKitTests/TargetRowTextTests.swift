import XCTest
@testable import PalmhelmKit

/// 飞书消息目标列表的行文案：标题去组前缀；副标题只留状态，不重复标题里已有的 agent 名。
final class TargetRowTextTests: XCTestCase {
    func testTitleDropsTheGroupPrefixOnlyWhenItEqualsTheGroupName() {
        XCTAssertEqual(TargetRowText.title(projectName: "task_000000000000_advisor", group: "task_000000000000"), "advisor")
        XCTAssertEqual(TargetRowText.title(projectName: "task_000000000000_execute2", group: "task_000000000000"), "execute2")
        // 前缀不等于分组名：原样
        XCTAssertEqual(TargetRowText.title(projectName: "task_other_design", group: "task_000000000000"), "task_other_design")
        XCTAssertEqual(TargetRowText.title(projectName: "task_000000000000", group: "task_000000000000"), "task_000000000000")
        XCTAssertEqual(TargetRowText.title(projectName: "task_000000000000_", group: "task_000000000000"), "task_000000000000_")
        // 无分组 / 空分组
        XCTAssertEqual(TargetRowText.title(projectName: "palmhelm", group: nil), "palmhelm")
        XCTAssertEqual(TargetRowText.title(projectName: "_x", group: ""), "_x")
        // 只剥一层
        XCTAssertEqual(TargetRowText.title(projectName: "g_g_design", group: "g"), "g_design")
    }

    func testSubtitleKeepsOnlyStatusWhenAgentNameRepeatsTheTitle() {
        XCTAssertEqual(TargetRowText.subtitle(activity: "空闲", agentName: "task_x_advisor", projectName: "task_x_advisor", title: "advisor"), "空闲")
        XCTAssertEqual(TargetRowText.subtitle(activity: "工作中 · 刚开始", agentName: "task_x_design", projectName: "task_x_design", title: "design"), "工作中 · 刚开始")
        // 与缩短后的标题相同也算重复
        XCTAssertEqual(TargetRowText.subtitle(activity: "空闲", agentName: "advisor", projectName: "task_x_advisor", title: "advisor"), "空闲")
        XCTAssertEqual(TargetRowText.subtitle(activity: "离线", agentName: nil, projectName: "p", title: "p"), "离线")
        XCTAssertEqual(TargetRowText.subtitle(activity: "空闲", agentName: "", projectName: "p", title: "p"), "空闲")
    }

    func testSubtitleKeepsADifferentAgentName() {
        XCTAssertEqual(TargetRowText.subtitle(activity: "空闲", agentName: "codex-1", projectName: "palmhelm", title: "palmhelm"), "空闲 · codex-1")
    }
}
