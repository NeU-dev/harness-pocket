import SwiftUI

struct PermissionSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var currentConversation = true
    @State private var saving = false
    @State private var localError: String?
    private var namespace: SettingsNamespace? { model.namespaces.first { $0.name == "permission" } }
    private var current: String {
        if currentConversation, let permissions = model.chat?.raw["permissions"] as? [String: Any] { return permissions["currentValue"] as? String ?? "" }
        return namespace?.value["defaultPreset"] as? String ?? ""
    }
    private var options: [String] {
        if currentConversation, let permissions = model.chat?.raw["permissions"] as? [String: Any] { return (permissions["options"] as? [[String: Any]] ?? []).compactMap { $0["value"] as? String }.filter { $0 != "custom" } }
        guard let schema = namespace?.schema, let refs = schema["refs"] as? [String: [String: Any]], let uid = schema["uid"] else { return [] }
        let root = refs[String(describing: uid)] ?? [:]
        guard let property = (root["dict"] as? [String: Any])?["defaultPreset"], let node = refs[String(describing: property)] else { return [] }
        let choices = (node["list"] as? [Any] ?? []).compactMap { refs[String(describing: $0)] }
        return (choices.isEmpty ? [node] : choices).compactMap { $0["value"] as? String }
    }
    var body: some View {
        Form {
            if model.chat != nil {
                Picker("適用先", selection: $currentConversation) { Text("この会話").tag(true); Text("新しい会話の既定値").tag(false) }.pickerStyle(.segmented).disabled(saving)
            }
            Section {
                ForEach(options, id: \.self) { option in
                    Button { select(option) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: current == option ? "checkmark.circle.fill" : "circle").foregroundStyle(PocketTheme.accent)
                            VStack(alignment: .leading, spacing: 6) { Text(title(option)).font(.headline).foregroundStyle(PocketTheme.text); Text(detail(option)).font(.footnote).foregroundStyle(PocketTheme.secondary) }
                        }.padding(.vertical, 7)
                    }.disabled(saving || current == option)
                }
                if options.isEmpty { Text("DGXの権限設定を読み込んでいます").foregroundStyle(PocketTheme.secondary) }
            } header: { Text(currentConversation ? "この会話の権限" : "次に作る会話の権限") }
              footer: { Text("ボタンを選ぶとDGXに保存されます。既定値を変えても、既存の会話の設定は変わりません。") }
            if saving { ProgressView("保存中…") }
            if let localError { Text(localError).foregroundStyle(.red) }
        }.navigationTitle("権限と承認").navigationBarTitleDisplayMode(.inline)
        .task { if model.chat == nil { currentConversation = false }; await model.perform { try await model.loadSettings() } }
    }
    private func title(_ value: String) -> String { ["read-only": "読み取りのみ", "workspace-write": "作業フォルダ内の変更を許可", "danger-full-access": "すべて許可（確認なし）"][value] ?? value }
    private func detail(_ value: String) -> String { ["read-only": "変更が必要な操作では、許可を確認します。", "workspace-write": "作業フォルダと許可された一時フォルダ内を変更できます。範囲外の操作は確認します。", "danger-full-access": "DGX上のファイルへ広くアクセスし、承認の確認を省略します。"][value] ?? "DGXに登録された権限プリセットです。" }
    private func select(_ option: String) {
        saving = true; localError = nil
        let sessionID = currentConversation ? model.currentID : nil
        Task { @MainActor in
            defer { saving = false }
            do {
                if let sessionID, let api = model.api {
                    _ = try await api.request("v1/sessions/\(sessionID)/permissions", method: "POST", body: ["preset": option])
                    if model.currentID == sessionID { await model.open(sessionID) }
                } else if let namespace { try await model.saveSetting(namespace, path: ["defaultPreset"], value: option); try await model.loadSettings() }
            } catch { localError = error.localizedDescription }
        }
    }
}
