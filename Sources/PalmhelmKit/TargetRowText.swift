import Foundation

/// 飞书消息目标列表的行文案（纯函数，只影响展示）。
public enum TargetRowText {
    /// 组内行标题：前缀恰为“<分组名>_”且剥掉后非空时省略该前缀，否则原样。
    public static func title(projectName: String, group: String?) -> String {
        guard let group, !group.isEmpty, projectName.hasPrefix(group + "_") else { return projectName }
        let rest = String(projectName.dropFirst(group.count + 1))
        return rest.isEmpty ? projectName : rest
    }

    /// 副标题：状态，加上与标题不同的 agent 名（与完整项目名或显示标题相同都算重复）。
    public static func subtitle(activity: String, agentName: String?, projectName: String, title: String) -> String {
        guard let agentName, !agentName.isEmpty, agentName != projectName, agentName != title else { return activity }
        return activity + " · " + agentName
    }
}
