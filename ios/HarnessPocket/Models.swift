import Foundation

struct Conversation: Identifiable {
    let id: String
    var title: String
    var running: Bool
    var updatedAt: Double
    init(_ value: [String: Any]) {
        id = value["id"] as? String ?? ""
        title = value["title"] as? String ?? L10n.string("新しいチャット")
        running = value["running"] as? Bool ?? false
        updatedAt = value["updatedAt"] as? Double ?? 0
    }
}
struct Message: Identifiable, Equatable {
    let id: String
    let role: String
    let text: String
    let attachments: [MessageAttachment]
    let reasoning: String
    let title: String
    let result: String
    let seq: Int?
    let streaming: Bool
    let interrupted: Bool
    init(_ value: [String: Any]) {
        id = value["id"] as? String ?? UUID().uuidString
        role = value["role"] as? String ?? "assistant"
        text = value["text"] as? String ?? ""
        attachments = (value["attachments"] as? [[String: Any]] ?? []).map(MessageAttachment.init)
        reasoning = value["reasoning"] as? String ?? ""
        title = value["title"] as? String ?? L10n.string("ツール")
        result = value["result"] as? String ?? ""
        seq = value["seq"] as? Int
        streaming = value["streaming"] as? Bool ?? false
        interrupted = value["interrupted"] as? Bool ?? false
    }
}
struct QuestionItem: Identifiable {
    let id: String
    let question: String
    let detail: String
    let options: [String]
    let multiple: Bool
    init(_ value: [String: Any]) {
        id = value["id"] as? String ?? ""
        question = value["question"] as? String ?? ""
        detail = value["detail"] as? String ?? ""
        options = (value["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        multiple = value["multiSelect"] as? Bool ?? false
    }
}
struct Approval: Identifiable {
    let id: String
    let event: String
    let title: String
    let reason: String
    let questions: [QuestionItem]
    init(_ value: [String: Any]) {
        id = value["eventId"] as? String ?? ""
        event = value["event"] as? String ?? ""
        let request = value["request"] as? [String: Any] ?? [:]
        title = request["toolName"] as? String ?? L10n.string("確認があります")
        reason = request["reason"] as? String ?? ""
        questions = (request["questions"] as? [[String: Any]] ?? []).map(QuestionItem.init)
    }
}
struct ChatSnapshot {
    let id: String
    let title: String
    let messages: [Message]
    let approvals: [Approval]
    let running: Bool
    let hasMore: Bool
    let error: String?
    let endReason: String?
    let raw: [String: Any]
    init(_ value: [String: Any]) {
        raw = value
        id = value["id"] as? String ?? ""
        title = value["title"] as? String ?? L10n.string("新しいチャット")
        messages = (value["messages"] as? [[String: Any]] ?? []).map(Message.init)
        approvals = (value["approvals"] as? [[String: Any]] ?? []).map(Approval.init)
        running = value["running"] as? Bool ?? false
        hasMore = value["hasMore"] as? Bool ?? false
        error = value["error"] as? String
        endReason = value["endReason"] as? String
    }
}
struct ModelOption: Identifiable, Hashable {
    var id: String { provider + "|" + model }
    let provider: String
    let model: String
    let name: String
    let efforts: [String]
}
struct Workspace: Identifiable {
    let id: String
    let title: String
    let path: String
    init(_ value: [String: Any]) {
        id = value["workspaceId"] as? String ?? ""
        title = value["title"] as? String ?? ""
        path = value["path"] as? String ?? ""
    }
}
struct RemoteDirectory: Identifiable {
    var id: String { path }
    let name: String
    let path: String
    let hidden: Bool
    init(_ value: [String: Any]) {
        name = value["name"] as? String ?? ""
        path = value["path"] as? String ?? ""
        hidden = value["hidden"] as? Bool ?? false
    }
}
struct DirectoryListing {
    let path: String
    let home: String
    let entries: [RemoteDirectory]
    let crumbs: [RemoteDirectory]
    let truncated: Bool
    var parent: String? { crumbs.dropLast().last?.path }
    init(_ value: [String: Any]) {
        path = value["path"] as? String ?? ""
        home = value["home"] as? String ?? ""
        entries = (value["entries"] as? [[String: Any]] ?? []).map(RemoteDirectory.init)
        crumbs = (value["crumbs"] as? [[String: Any]] ?? []).map(RemoteDirectory.init)
        truncated = value["truncated"] as? Bool ?? false
    }
}
struct SettingsNamespace: Identifiable {
    var id: String { name }
    let name: String
    let revision: Int
    let applies: String
    let value: [String: Any]
    let schema: [String: Any]
    let secretPaths: [[String]]
    init(_ json: [String: Any]) {
        name = json["ns"] as? String ?? ""
        revision = json["revision"] as? Int ?? 0
        applies = json["applies"] as? String ?? "live"
        value = json["value"] as? [String: Any] ?? [:]
        schema = json["schema"] as? [String: Any] ?? [:]
        secretPaths = (json["secrets"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? [String] }
    }
    var displayName: String {
        ["agent-default-model": "既定のモデル", "subagent-model-selection": "サブエージェントのモデル", "llm-deepseek": "DeepSeek", "llm-pi-ai": "モデル接続・プロバイダ", "agent-loop": "回答・実行ループ", "agent-presets": "基本指示・プリセット", "permission": "権限と承認", "shell": "コマンド実行", "web-search-deepseek": "Web検索", "locale": "言語"][name].map(L10n.string) ?? name
    }
}
