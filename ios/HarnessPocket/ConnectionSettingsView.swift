import SwiftUI

struct ConnectionSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var launchURL = ""
    @State private var working = false
    @State private var message: String?
    private var connection: [String: Any] { model.status["connection"] as? [String: Any] ?? [:] }
    private var automatic: Bool { connection["automatic"] as? Bool ?? false }

    var body: some View {
        Form {
            Section("接続状態") {
                Label(L10n.string(model.connected ? "DSHに接続しています" : "DSHへの接続を確認してください"), systemImage: model.connected ? "checkmark.circle" : "wifi.exclamationmark")
                    .foregroundStyle(model.connected ? PocketTheme.accent : PocketTheme.text)
                if let url = connection["url"] as? String { LabeledContent("DSH", value: url).font(.caption).textSelection(.enabled) }
                LabeledContent("再起動後の接続更新", value: L10n.string(automatic ? "自動" : "手動"))
                Button { Task { await reconnect() } } label: {
                    HStack { Text("再接続する"); if working { Spacer(); ProgressView() } }
                }.disabled(working)
                if let message { Text(message).font(.footnote).foregroundStyle(PocketTheme.secondary) }
            }
            Section {
                Text(L10n.string(automatic ? "DSHを再起動すると、最新の接続情報を自動で読み直します。少し待ってもつながらない時は「再接続する」を試してください。" : "DSHを起動してから「再接続する」を試してください。起動時URLが変わった時は、下の入力欄から更新できます。"))
                Text("外出先ではiPhoneのTailscaleが接続中か確認してください。下書きと端末登録は引き続き使えます。")
            }.font(.footnote).foregroundStyle(PocketTheme.secondary)
            if !automatic {
                Section("起動時URLで接続を更新") {
                    Text("DGXでDSHを起動した時の「dsh web:」に続くURLを貼り付けてください（http://127.0.0.1:…/?token=…）。")
                        .font(.footnote).foregroundStyle(PocketTheme.secondary)
                    SecureField("DSHの起動時URL", text: $launchURL, prompt: Text("DSHの起動時URL").foregroundColor(PocketTheme.secondary))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    Button("このURLで接続する") { Task { await reconnect(useURL: true) } }
                        .disabled(working || launchURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }.navigationTitle("接続を確認・修復").navigationBarTitleDisplayMode(.inline)
            .task { await refresh() }
    }
    private func refresh() async {
        do { try await model.loadConnectionStatus() }
        catch { message = L10n.string("DGXの中継に届いていません。TailscaleとDGXの起動状態を確認してください。") }
    }
    private func reconnect(useURL: Bool = false) async {
        guard let api = model.api else { return }
        working = true; message = nil; defer { working = false }
        do {
            var body: [String: Any] = [:]
            if useURL {
                let value = launchURL.trimmingCharacters(in: .whitespacesAndNewlines)
                body["url"] = value.hasPrefix("dsh web:") ? String(value.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines) : value
            }
            _ = try await api.request("v1/connection", method: "POST", body: body)
            launchURL = ""
            // Bounded checks only after an explicit tap; background reconnect is handled by the gateway.
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(500))
                try await model.loadConnectionStatus()
                if model.connected { message = L10n.string("接続できました。会話を続けられます。"); return }
            }
            message = L10n.string("再接続を続けています。DSHが起動しているか確認してください。")
        } catch { message = error.localizedDescription }
    }
}
