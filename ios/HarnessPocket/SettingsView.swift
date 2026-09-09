import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @AppStorage("appearance") private var appearance = "system"
    @State private var path = ""
    @State private var disconnect = false
    var body: some View {
        NavigationStack {
            Form {
                Section("接続") {
                    LabeledContent("DGX Spark", value: model.connected ? "接続中" : "再接続中")
                    Text(model.serverURL).font(.caption).foregroundStyle(PocketTheme.secondary).textSelection(.enabled)
                    NavigationLink("接続を確認・修復") { ConnectionSettingsView() }
                    NavigationLink("登録済み端末") { DevicesView() }
                }
                Section("完了・確認待ちの通知") {
                    Toggle("完了・権限確認・質問を通知", isOn: Binding(get: { model.notificationsEnabled }, set: { enabled in Task { await model.enableNotifications(enabled) } }))
                    LabeledContent("Appleへの送信設定", value: model.apnsConfigured ? "設定済み" : "キーの登録が必要")
                    LabeledContent("このiPhone", value: model.notificationDeviceRegistered ? "登録済み" : "未登録")
                    NavigationLink("通知の設定・接続テスト") { NotificationSettingsView() }
                }
                Section("表示") {
                    Picker("外観", selection: $appearance) { Text("システムに合わせる").tag("system"); Text("ライト").tag("light"); Text("ダーク").tag("dark") }
                }
                Section("作業場所") {
                    Picker("新しい会話のフォルダ", selection: $model.workspaceID) { Text("DGXのホーム").tag(""); ForEach(model.workspaces) { Text($0.title).tag($0.id) } }
                    NavigationLink { DirectoryPickerView() } label: { Label("DGXのフォルダから選ぶ", systemImage: "folder") }
                    if let selected = model.workspaces.first(where: { $0.id == model.workspaceID }) {
                        Text(selected.path).font(.caption).foregroundStyle(PocketTheme.secondary).textSelection(.enabled)
                    }
                    DisclosureGroup("パスを直接指定") {
                        TextField("DGX上のフォルダ（/home/…）", text: $path).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("このフォルダを使う") { Task { await model.perform { try await model.selectDirectory(path); path = "" } } }.disabled(path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text("選んだフォルダは、新しい会話から使います。").font(.caption).foregroundStyle(PocketTheme.secondary)
                }
                Section("モデル接続") { NavigationLink("APIキーを登録・更新") { CredentialView() }; NavigationLink("カスタムプロバイダを追加") { ProviderView() } }
                Section("権限") { NavigationLink("ボタンで権限と承認を選ぶ") { PermissionSettingsView() } }
                Section("Harnessの設定") {
                    ForEach(model.namespaces.filter { !$0.name.hasPrefix("ui-") && $0.name != "permission" }) { namespace in NavigationLink(namespace.displayName) { NamespaceView(namespaceName: namespace.name) } }
                    if model.namespaces.isEmpty { Text("接続すると設定を読み込めます").foregroundStyle(PocketTheme.secondary) }
                }
                Section { Button("このiPhoneの登録を解除", role: .destructive) { disconnect = true } }
                Section { Text("Harness Pocket 0.1\n会話・モデル実行・設定の保存はDGX側で行います。").font(.caption).foregroundStyle(PocketTheme.secondary) }
            }.navigationTitle("設定").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
                .task { await model.perform { try await model.loadSettings() } }
                .confirmationDialog("このiPhoneの接続を解除しますか？", isPresented: $disconnect) { Button("登録を解除", role: .destructive) { Task { await model.disconnect(); dismiss() } } }
        }
    }
}
struct NamespaceView: View {
    @EnvironmentObject var model: AppModel
    let namespaceName: String
    var namespace: SettingsNamespace? { model.namespaces.first { $0.name == namespaceName } }
    var body: some View {
        Group {
            if let namespace {
                SettingsObjectView(namespace: namespace, path: [], object: namespace.value)
                    .navigationTitle(namespace.displayName)
            } else { ContentUnavailableView("設定を読み込めません", systemImage: "exclamationmark.triangle") }
        }.navigationBarTitleDisplayMode(.inline)
    }
}
struct SettingsObjectView: View {
    @EnvironmentObject var model: AppModel
    let namespace: SettingsNamespace
    let path: [String]
    let object: [String: Any]
    var body: some View {
        List {
            Section {
                ForEach(object.keys.sorted(), id: \.self) { key in
                    if let nested = object[key] as? [String: Any] {
                        NavigationLink(key) { SettingsObjectView(namespace: namespace, path: path + [key], object: nested).navigationTitle(key) }
                    } else {
                        NavigationLink { SettingEditor(namespaceName: namespace.name, path: path + [key], initialValue: object[key] ?? "") } label: {
                            HStack { Text(key); Spacer(); Text(summary(object[key])).foregroundStyle(PocketTheme.secondary).lineLimit(1).frame(maxWidth: 160, alignment: .trailing) }
                        }
                    }
                }
            } footer: { Text(namespace.applies == "restart" ? "この設定はHarness再起動後に反映されます。" : "保存した設定はHarness側へ反映されます。") }
            if object.isEmpty { Text("現在この項目には設定がありません。").foregroundStyle(PocketTheme.secondary) }
        }
    }
    private func summary(_ value: Any?) -> String {
        guard let value else { return "未設定" }
        if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "オン" : "オフ" }
        if let a = value as? [Any] { return "\(a.count)件" }
        return String(describing: value)
    }
}
struct SettingEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let namespaceName: String
    let path: [String]
    let initialValue: Any
    @State private var text = ""
    @State private var boolean = false
    @State private var revision: Int?
    @State private var saving = false
    @State private var localError: String?
    private var isBool: Bool { guard let n = initialValue as? NSNumber else { return false }; return CFGetTypeID(n) == CFBooleanGetTypeID() }
    private var isNumber: Bool { initialValue is NSNumber && !isBool }
    private var isArray: Bool { initialValue is [Any] }
    var body: some View {
        Form {
            Section(path.last ?? "設定") {
                if isBool { Toggle("有効", isOn: $boolean) }
                else if isNumber { TextField("値", text: $text).keyboardType(.numbersAndPunctuation) }
                else { TextEditor(text: $text).frame(minHeight: 160).textInputAutocapitalization(.never).autocorrectionDisabled() }
            }
            if isArray { Text("配列の詳細設定です。JSON形式で編集できます。").font(.caption).foregroundStyle(PocketTheme.secondary) }
            if let localError { Text(localError).foregroundStyle(.red).font(.footnote) }
            Button("保存") { Task { await save() } }.disabled(saving)
        }.navigationTitle(path.last ?? "設定").navigationBarTitleDisplayMode(.inline)
            .task {
                revision = model.namespaces.first { $0.name == namespaceName }?.revision
                if isBool { boolean = (initialValue as? NSNumber)?.boolValue ?? false }
                else if isArray, let data = try? JSONSerialization.data(withJSONObject: initialValue, options: [.prettyPrinted, .sortedKeys]) { text = String(decoding: data, as: UTF8.self) }
                else { text = String(describing: initialValue) }
            }
    }
    private func save() async {
        saving = true; defer { saving = false }
        do {
            guard let revision, let api = model.api else { throw PocketError.message("設定を読み直してください") }
            let value: Any
            if isBool { value = boolean }
            else if isNumber { guard let number = Double(text), number.isFinite else { throw PocketError.message("数値を入力してください") }; value = number }
            else if isArray { value = try JSONSerialization.jsonObject(with: Data(text.utf8)) }
            else { value = text }
            _ = try await api.request("v1/settings", method: "PATCH", body: ["ns": namespaceName, "expectedRevision": revision, "ops": [["op": "set", "path": path, "value": value]]])
            try await model.loadSettings(); dismiss()
        } catch { localError = error.localizedDescription }
    }
}
struct CredentialView: View {
    @EnvironmentObject var model: AppModel
    @State private var ref = "DEEPSEEK_API_KEY"
    @State private var value = ""
    @State private var saved = false
    @State private var remove = false
    var body: some View {
        Form {
            Section("APIキー") {
                TextField("キーの参照名", text: $ref).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("新しいAPIキー", text: $value).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("保存") { Task { await model.perform { _ = try await model.api?.request("v1/credentials", method: "POST", body: ["ref": ref, "value": value]); value = ""; saved = true } } }.disabled(value.isEmpty)
                if saved { Label("DGXへ保存しました", systemImage: "checkmark.circle").foregroundStyle(.green) }
            }
            Text("参照名はモデル設定の apiKeyEnv と合わせます。保存済みのキーはアプリへ返されません。").font(.caption).foregroundStyle(PocketTheme.secondary)
            Button("この参照名のキーを削除", role: .destructive) { remove = true }
        }.navigationTitle("APIキー").confirmationDialog("保存済みのAPIキーを削除しますか？", isPresented: $remove) { Button("削除", role: .destructive) { Task { await model.perform { _ = try await model.api?.request("v1/credentials", method: "DELETE", body: ["ref": ref]); saved = false } } } }
    }
}
struct ProviderView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var provider = ""
    @State private var display = ""
    @State private var baseURL = ""
    @State private var modelID = ""
    @State private var key = ""
    @State private var apiProtocol = "openai-completions"
    var body: some View {
        Form {
            Section("接続先") {
                TextField("識別名（my-provider）", text: $provider)
                TextField("表示名", text: $display)
                TextField("APIのURL", text: $baseURL).keyboardType(.URL)
                Picker("API形式", selection: $apiProtocol) { Text("Chat Completions互換").tag("openai-completions"); Text("Responses互換").tag("openai-responses"); Text("Anthropic互換").tag("anthropic-messages") }
                TextField("モデルID", text: $modelID)
                SecureField("APIキー", text: $key)
            }.textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("追加する") { Task { await model.perform {
                guard provider.range(of: "^[a-z][a-z0-9-]{0,48}$", options: .regularExpression) != nil else { throw PocketError.message("識別名は小文字・数字・ハイフンで指定してください") }
                guard let namespace = model.namespaces.first(where: { $0.name == "llm-pi-ai" }), let api = model.api else { throw PocketError.message("モデル接続設定を読み込んでください") }
                if (namespace.value["providers"] as? [String: Any])?[provider] != nil { throw PocketError.message("同じ識別名が登録済みです") }
                let ref = "POCKET_" + provider.replacingOccurrences(of: "-", with: "_").uppercased() + "_API_KEY"
                if !key.isEmpty { _ = try await api.request("v1/credentials", method: "POST", body: ["ref": ref, "value": key]) }
                let value: [String: Any] = ["name": display.isEmpty ? provider : display, "baseURL": baseURL, "api": apiProtocol, "apiKeyEnv": ref, "models": [["id": modelID, "name": modelID]]]
                try await model.saveSetting(namespace, path: ["providers", provider], value: value)
                key = ""; try await model.refresh(); dismiss()
            } } }.disabled(provider.isEmpty || modelID.isEmpty || baseURL.isEmpty)
        }.navigationTitle("プロバイダを追加")
    }
}
struct NotificationSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var keyID = ""
    @State private var teamID = ""
    @State private var privateKey = ""
    @State private var fileName = ""
    @State private var importKey = false
    @State private var message = ""
    var body: some View {
        Form {
            Section("このiPhone") {
                Button("通知を許可して登録") { Task { await model.enableNotifications(true) } }
                if !model.pushMessage.isEmpty { Text(model.pushMessage).font(.caption) }
                Button("テスト通知を送信") { Task { await model.perform { _ = try await model.api?.request("v1/push/test", method: "POST", body: [:]); message = "Appleがテスト通知を受け付けました" } } }.disabled(!model.apnsConfigured || !model.notificationDeviceRegistered)
            }
            Section("Apple通知キー（初回のみ）") {
                Text("DGXからiPhoneへ通知するための設定です。Apple DeveloperでAPNsキーを作成し、ここからDGXへ登録します。").font(.footnote).foregroundStyle(PocketTheme.secondary)
                Link("Apple Developerのキー管理を開く", destination: URL(string: "https://developer.apple.com/account/resources/authkeys/list")!)
                TextField("Key ID", text: $keyID).textInputAutocapitalization(.characters).autocorrectionDisabled()
                TextField("Team ID", text: $teamID).textInputAutocapitalization(.characters).autocorrectionDisabled()
                Button(fileName.isEmpty ? ".p8 ファイルを選択" : fileName) { importKey = true }
                LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "").font(.caption)
                Button("通知キーをDGXへ保存") { Task { await model.perform {
                    guard let api = model.api else { return }
                    _ = try await api.request("v1/push/config", method: "POST", body: ["keyId": keyID, "teamId": teamID, "privateKey": privateKey, "topic": Bundle.main.bundleIdentifier ?? ""])
                    privateKey = ""; fileName = ""; try await model.loadSettings(); message = "通知キーを保存しました。テスト通知で確認できます。"
                } } }.disabled(keyID.count != 10 || teamID.count != 10 || privateKey.isEmpty)
            }
            if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(PocketTheme.accent) }
            Section { Text("回答の完了、操作の許可、質問への回答を待っている時に通知します。会話の本文はロック画面へ載せず、タップすると該当する会話が開きます。iPhoneの集中モードや通知設定によって表示が遅れることがあります。").font(.caption).foregroundStyle(PocketTheme.secondary) }
        }.navigationTitle("通知").navigationBarTitleDisplayMode(.inline)
            .fileImporter(isPresented: $importKey, allowedContentTypes: [.data]) { result in
                do { let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; let data = try Data(contentsOf: url); guard data.count < 20_000, let text = String(data: data, encoding: .utf8), text.contains("BEGIN PRIVATE KEY") else { throw PocketError.message("APNsの.p8ファイルを選択してください") }; privateKey = text; fileName = url.lastPathComponent } catch { model.error = error.localizedDescription }
            }
    }
}
struct DevicesView: View {
    @EnvironmentObject var model: AppModel
    @State private var devices: [[String: Any]] = []
    @State private var revokeID: String?
    var body: some View {
        List {
            ForEach(devices.indices, id: \.self) { i in HStack { Text(devices[i]["name"] as? String ?? "iPhone"); Spacer(); if devices[i]["current"] as? Bool == true { Text("この端末").font(.caption).foregroundStyle(PocketTheme.secondary) } else { Button("解除", role: .destructive) { revokeID = devices[i]["id"] as? String } } } }
        }.navigationTitle("登録済み端末").task { await load() }
            .confirmationDialog("この端末の接続を解除しますか？", isPresented: Binding(get: { revokeID != nil }, set: { if !$0 { revokeID = nil } })) { Button("解除", role: .destructive) { Task { await model.perform { if let id = revokeID { _ = try await model.api?.request("v1/devices/\(id)", method: "DELETE"); await load() } } } } }
    }
    private func load() async { await model.perform { let result = try await model.api?.request("v1/devices"); devices = result?["devices"] as? [[String: Any]] ?? [] } }
}
