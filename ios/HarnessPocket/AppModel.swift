import SwiftUI
import UserNotifications

@MainActor final class AppModel: ObservableObject {
    @Published var paired = false
    @Published var connected = false
    @Published var busy = false
    @Published var error: String?
    @Published var conversations: [Conversation] = []
    @Published var chat: ChatSnapshot?
    @Published var models: [ModelOption] = []
    @Published var selectedModel = ""
    @Published var effort = ""
    @Published var workspaces: [Workspace] = []
    @Published var namespaces: [SettingsNamespace] = []
    @Published var status: [String: Any] = [:]
    @Published var draft = "" { didSet { UserDefaults.standard.set(draft, forKey: draftKey) } }
    @Published var attachments: [DraftAttachment] = [] { didSet { saveAttachments(attachments, key: "attachments." + (currentID ?? "new")) } }
    @Published var pendingAttachments: [DraftAttachment] = []
    @Published var importing = false
    @Published var pushMessage = ""
    @Published var pendingText: String?
    @Published var pendingRequestID: String?
    @AppStorage("workspaceID") var workspaceID = ""
    @AppStorage("serverURL") var serverURL = ""
    @AppStorage("deviceID") var deviceID = ""
    var api: API?
    var socket: URLSessionWebSocketTask?
    var connectionTask: Task<Void, Never>?
    var currentID: String? { didSet { if currentID != oldValue { streamSnapshot = nil; focusConversation() } } }
    private var streamSnapshot: [String: Any]?
    private let cacheQueue = DispatchQueue(label: "harness-pocket.cache", qos: .utility)
    var foreground = true
    var demo = false
    var lastPushToken: String?
    private var lastCacheWrite = Date.distantPast
    private var draftKey: String { "draft." + (currentID ?? "new") }
    var apnsConfigured: Bool { (status["apns"] as? [String: Any])?["configured"] as? Bool ?? false }
    var notificationsEnabled: Bool { status["notificationsEnabled"] as? Bool ?? false }
    var notificationDeviceRegistered: Bool { status["deviceRegistered"] as? Bool ?? false }
    var modelName: String { models.first(where: { $0.id == selectedModel })?.name ?? L10n.string("モデルを選択") }

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--demo") { loadDemo(); return }
        if let testURL = ProcessInfo.processInfo.environment["POCKET_TEST_URL"], let code = ProcessInfo.processInfo.environment["POCKET_TEST_CODE"] {
            Task {
                await self.pair(url: testURL, code: code)
                if let id = ProcessInfo.processInfo.environment["POCKET_TEST_SESSION"] {
                    for _ in 0..<50 { if self.connected { break }; try? await Task.sleep(for: .milliseconds(200)) }
                    await self.open(id)
                }
                if let message = ProcessInfo.processInfo.environment["POCKET_TEST_MESSAGE"] {
                    self.draft = message
                    await self.send()
                }
            }
            return
        }
        #endif
        if let token = Keychain.get("deviceToken"), let url = try? API.validate(serverURL) {
            api = API(url: url, token: token); paired = true
            currentID = UserDefaults.standard.string(forKey: "lastSession")
            if let id = currentID { chat = loadCache(id); restorePending() }
            if let url = cacheURL("index"), let data = try? Data(contentsOf: url), let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { conversations = rows.map(Conversation.init) }
        }
        draft = UserDefaults.standard.string(forKey: draftKey) ?? ""; attachments = readAttachments(key: "attachments." + (currentID ?? "new"))
    }
    func perform(_ action: () async throws -> Void) async {
        do { try await action() } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
    func pair(url: String, code: String) async {
        busy = true; defer { busy = false }
        await perform {
            let candidate = API(url: try API.validate(url))
            let health = try await candidate.request("health")
            guard health["service"] as? String == "harness-pocket", health["protocolVersion"] as? Int == 1 else { throw PocketError.message(L10n.string("Harness Pocket用の接続先ではありません")) }
            let response = try await candidate.request("v1/pair", method: "POST", body: ["code": code, "name": UIDevice.current.name])
            guard let token = response["token"] as? String, let id = response["deviceId"] as? String else { throw PocketError.message(L10n.string("端末登録に失敗しました")) }
            try Keychain.set("deviceToken", token)
            candidate.token = token; self.api = candidate; self.serverURL = candidate.baseURL.absoluteString; self.deviceID = id; self.paired = true
            self.startConnection()
        }
    }
    func startConnection() {
        guard paired, !demo, foreground, connectionTask == nil, let api else { return }
        connectionTask = Task { [weak self] in
            guard let self else { return }
            var retry: UInt64 = 1
            while !Task.isCancelled && self.foreground {
                let ws = api.socket(); self.socket = ws; ws.resume()
                do {
                    while !Task.isCancelled {
                        let message = try await ws.receive()
                        let data: Data
                        switch message { case .data(let d): data = d; case .string(let s): data = Data(s.utf8); @unknown default: continue }
                        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                        let type = json["type"] as? String
                        if type == "ready" || type == "status" {
                            let wasConnected = self.connected
                            self.status = json["status"] as? [String: Any] ?? [:]
                            if type == "ready" { self.streamSnapshot = nil; self.focusConversation() }
                            self.connected = self.status["connected"] as? Bool ?? false
                            if self.connected {
                                retry = 1
                                if type == "ready" || !wasConnected {
                                    await self.perform { try await self.refresh() }
                                    await self.registerIfAllowed()
                                    if let pending = UserDefaults.standard.string(forKey: "pendingNotificationSession") { await self.open(pending); UserDefaults.standard.removeObject(forKey: "pendingNotificationSession") }
                                }
                            }
                        } else if let snap = json["snapshot"] as? [String: Any] {
                            if snap["id"] as? String == self.currentID { self.streamSnapshot = snap; self.apply(ChatSnapshot(snap)) }
                            self.updateSummary(id: snap["id"] as? String, title: snap["title"] as? String, running: snap["running"] as? Bool)
                        } else if type == "sessionDelta" {
                            self.applyStreamDelta(json)
                        } else if type == "sessionSummary" {
                            self.updateSummary(id: json["sessionId"] as? String, title: json["title"] as? String, running: json["running"] as? Bool)
                        } else if type == "workspaces" { await self.perform { try await self.refreshWorkspaces(); try await self.refreshList() } }
                        else if type == "sessions" { await self.perform { try await self.refreshList() } }
                    }
                } catch { if self.socket === ws { self.connected = false } }
                ws.cancel(with: .goingAway, reason: nil)
                if Task.isCancelled { break }
                try? await Task.sleep(for: .seconds(retry)); retry = min(retry * 2, 10)
            }
        }
    }
    private func focusConversation() {
        guard let socket else { return }
        let value: [String: Any] = ["type": "focus", "sessionId": currentID as Any? ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        Task { try? await socket.send(.data(data)) }
    }
    private func updateSummary(id: String?, title: String?, running: Bool?) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        if let title, conversations[i].title != title { conversations[i].title = title }
        if let running, conversations[i].running != running { conversations[i].running = running }
    }
    private func applyStreamDelta(_ frame: [String: Any]) {
        guard let id = frame["sessionId"] as? String, id == currentID,
              let baseline = streamSnapshot, baseline["id"] as? String == id,
              var next = frame["meta"] as? [String: Any],
              let order = frame["order"] as? [String], let changes = frame["messages"] as? [[String: Any]] else { return }
        var rows: [String: [String: Any]] = [:]
        for row in (baseline["messages"] as? [[String: Any]] ?? []) + changes {
            if let key = row["id"] as? String { rows[key] = row }
        }
        guard order.allSatisfy({ rows[$0] != nil }) else { focusConversation(); return }
        next["messages"] = order.compactMap { rows[$0] }
        streamSnapshot = next
        apply(ChatSnapshot(next))
        updateSummary(id: id, title: next["title"] as? String, running: next["running"] as? Bool)
    }
    func pause() {
        if let chat { saveCache(chat, force: true) }
        streamSnapshot = nil
        foreground = false; connectionTask?.cancel(); connectionTask = nil; socket?.cancel(with: .goingAway, reason: nil); connected = false
    }
    func resume() { foreground = true; startConnection() }
    func refreshList() async throws {
        guard let api else { return }
        let value = try await api.request("v1/sessions"); conversations = (value["items"] as? [[String: Any]] ?? []).map(Conversation.init)
        if let url = cacheURL("index"), let rows = value["items"], let data = try? JSONSerialization.data(withJSONObject: rows) { try? data.write(to: url, options: [.atomic, .completeFileProtection]) }
    }
    func refresh() async throws {
        guard let api, !demo else { return }
        try await refreshList()
        let catalog = try await api.request("v1/models")
        models = (catalog["groups"] as? [[String: Any]] ?? []).flatMap { group in
            (group["models"] as? [[String: Any]] ?? []).map { model in
                ModelOption(provider: group["id"] as? String ?? "", model: model["id"] as? String ?? "", name: model["name"] as? String ?? "", efforts: ((model["reasoning"] as? [String: Any])?["efforts"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
            }
        }
        if selectedModel.isEmpty, let initial = catalog["default"] as? [String: Any], let p = initial["provider"] as? String, let m = initial["model"] as? String { selectedModel = p + "|" + m; effort = initial["reasoningEffort"] as? String ?? "" }
        try await refreshWorkspaces()
        if let id = currentID { apply(ChatSnapshot(try await api.request("v1/sessions/\(id)"))) }
    }
    func apply(_ snapshot: ChatSnapshot) {
        chat = snapshot
        if let selection = snapshot.raw["model"] as? [String: Any], let provider = selection["provider"] as? String, let model = selection["model"] as? String { let selected = provider + "|" + model; let nextEffort = selection["reasoningEffort"] as? String ?? ""; if selectedModel != selected { selectedModel = selected }; if effort != nextEffort { effort = nextEffort } }
        if let requestID = pendingRequestID, (snapshot.raw["messages"] as? [[String: Any]] ?? []).contains(where: { $0["requestId"] as? String == requestID }) { pendingText = nil; pendingRequestID = nil; pendingAttachments = []; persistPending() }
        saveCache(snapshot)
    }
    func refreshWorkspaces() async throws {
        guard let api else { return }
        let work = try await api.request("v1/workspaces")
        workspaces = (work["items"] as? [[String: Any]] ?? []).map(Workspace.init)
    }
    func directories(_ path: String?) async throws -> DirectoryListing {
        guard let api else { throw PocketError.message(L10n.string("DGXへ接続してください")) }
        let query = path.map { [URLQueryItem(name: "path", value: $0)] } ?? []
        return DirectoryListing(try await api.request("v1/directories", query: query))
    }
    func selectDirectory(_ path: String) async throws {
        guard let api else { throw PocketError.message(L10n.string("DGXへ接続してください")) }
        let response = try await api.request("v1/workspaces", method: "POST", body: ["path": path])
        guard let row = response["workspace"] as? [String: Any], let id = row["workspaceId"] as? String else { throw PocketError.message(L10n.string("作業場所を登録できませんでした")) }
        let workspace = Workspace(row)
        workspaces.removeAll { $0.id == id }; workspaces.append(workspace)
        workspaceID = id
    }
    func newChat() {
        currentID = nil; chat = nil; pendingText = nil; pendingRequestID = nil; pendingAttachments = []
        UserDefaults.standard.removeObject(forKey: "lastSession")
        draft = UserDefaults.standard.string(forKey: draftKey) ?? ""; attachments = readAttachments(key: "attachments." + (currentID ?? "new"))
    }
    func open(_ id: String) async {
        guard !demo else { return }
        currentID = id; chat = loadCache(id); draft = UserDefaults.standard.string(forKey: draftKey) ?? ""; attachments = readAttachments(key: "attachments." + (currentID ?? "new"))
        UserDefaults.standard.set(id, forKey: "lastSession")
        restorePending()
        guard connected, let api else { return }
        await perform { self.apply(ChatSnapshot(try await api.request("v1/sessions/\(id)"))) }
    }
    func send(retry: Bool = false) async {
        guard !demo, let api, connected, !busy else { return }
        guard retry || pendingText == nil else { return }
        let text = retry ? (pendingText ?? "") : draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let sendingAttachments = retry ? pendingAttachments : attachments
        guard !text.isEmpty || !sendingAttachments.isEmpty else { return }
        busy = true; defer { busy = false }
        await perform {
            if self.currentID == nil {
                let requestedModel = self.selectedModel
                let requestedEffort = self.effort
                let id = UUID().uuidString; self.currentID = id
                var body: [String: Any] = ["sessionId": id]
                if !self.workspaceID.isEmpty { body["workspaceId"] = self.workspaceID }
                do { self.apply(ChatSnapshot(try await api.request("v1/sessions", method: "POST", body: body))) }
                catch { self.currentID = nil; throw error }
                self.selectedModel = requestedModel
                self.effort = requestedEffort
                if !self.selectedModel.isEmpty { try await self.changeModel() }
                UserDefaults.standard.set(id, forKey: "lastSession")
            }
            guard let id = self.currentID else { return }
            let requestID = retry ? (self.pendingRequestID ?? UUID().uuidString) : UUID().uuidString
            self.pendingText = text; self.pendingRequestID = requestID; self.pendingAttachments = sendingAttachments; self.persistPending()
            if !retry { self.draft = ""; self.attachments = []; UserDefaults.standard.removeObject(forKey: "draft.new"); UserDefaults.standard.removeObject(forKey: "attachments.new") }
            do {
                _ = try await api.request("v1/sessions/\(id)/messages", method: "POST", body: ["text": text, "requestId": requestID, "timeZone": TimeZone.current.identifier, "attachments": try sendingAttachments.map { try $0.payload() }])
            } catch let PocketError.attachmentRejected(message) {
                self.pendingText = nil; self.pendingRequestID = nil; self.pendingAttachments = []; self.persistPending()
                self.draft = text; self.attachments = sendingAttachments
                throw PocketError.message(message + L10n.string("\n下書きに戻しました。モデルや添付を変更して送信できます。"))
            }
            try await self.refreshList()
        }
    }
    func changeModel() async throws {
        guard let api, let id = currentID, let option = models.first(where: { $0.id == selectedModel }) else { return }
        var body: [String: Any] = ["provider": option.provider, "model": option.model]
        if !effort.isEmpty && option.efforts.contains(effort) { body["reasoningEffort"] = effort }
        _ = try await api.request("v1/sessions/\(id)/model", method: "POST", body: body)
    }
    func stop() async { await perform { guard let id = self.currentID else { return }; _ = try await self.api?.request("v1/sessions/\(id)/cancel", method: "POST", body: [:]) } }
    func rename(_ id: String, title: String) async { await perform { _ = try await self.api?.request("v1/sessions/\(id)", method: "PATCH", body: ["title": title]); try await self.refreshList() } }
    func archive(_ id: String) async { await perform { _ = try await self.api?.request("v1/sessions/\(id)", method: "DELETE"); if self.currentID == id { self.newChat() }; try await self.refreshList() } }
    func older() async { await perform { guard let api = self.api, let id = self.currentID else { return }; self.apply(ChatSnapshot(try await api.request("v1/sessions/\(id)/older", method: "POST", body: [:]))) } }
    func answer(_ approval: Approval, value: Any) async { await perform { _ = try await self.api?.request("v1/approvals/\(approval.id)", method: "POST", body: ["answer": value]); if let id = self.currentID { await self.open(id) } } }
    func regenerate(before message: Message) async {
        guard let chat, let api else { return }
        let source = chat.messages.last(where: { $0.role == "user" && ($0.seq ?? 0) < (message.seq ?? Int.max) })
        guard let source, let seq = source.seq else { return }
        await perform {
            let result = try await api.request("v1/sessions/\(chat.id)/fork", method: "POST", body: ["atSeq": max(0, seq - 1)])
            if let id = result["id"] as? String { await self.open(id); self.draft = source.text }
        }
    }
    func loadSettings() async throws {
        guard let api else { return }
        try await loadConnectionStatus()
        guard connected else { return }
        let response = try await api.request("v1/settings")
        namespaces = (response["namespaces"] as? [[String: Any]] ?? []).map(SettingsNamespace.init)
    }
    func loadConnectionStatus() async throws {
        guard let api else { return }
        status = try await api.request("v1/status")
        connected = status["connected"] as? Bool ?? false
    }
    func saveSetting(_ namespace: SettingsNamespace, path: [String], value: Any) async throws {
        guard let api else { return }
        _ = try await api.request("v1/settings", method: "PATCH", body: ["ns": namespace.name, "expectedRevision": namespace.revision, "ops": [["op": "set", "path": path, "value": value]]])
        try await loadSettings()
    }
    func enableNotifications(_ enabled: Bool) async {
        await perform {
            if enabled {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                guard granted else { throw PocketError.message(L10n.string("iPhoneの「設定 → 通知 → Harness Pocket」で通知を許可してください")) }
                UIApplication.shared.registerForRemoteNotifications()
            }
            if let api = self.api { self.status = try await api.request("v1/push/preferences", method: "POST", body: ["enabled": enabled]) }
        }
    }
    func registerIfAllowed() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional { UIApplication.shared.registerForRemoteNotifications() }
    }
    func receivedToken(_ token: String) async {
        lastPushToken = token
        await perform {
            guard let api = self.api else { return }
            let environment = Bundle.main.object(forInfoDictionaryKey: "APNSEnvironment") as? String ?? "production"
            self.status = try await api.request("v1/push/register", method: "POST", body: ["token": token, "environment": environment])
            self.pushMessage = L10n.string("このiPhoneを登録しました")
        }
    }
    func disconnect() async {
        await perform {
            _ = try await self.api?.request("v1/devices/\(self.deviceID)", method: "DELETE")
            self.pause(); try Keychain.set("deviceToken", nil); self.api = nil; self.paired = false; self.chat = nil; self.currentID = nil
        }
    }
    private func saveAttachments(_ items: [DraftAttachment], key: String) { UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: key) }
    private func readAttachments(key: String) -> [DraftAttachment] { guard let data = UserDefaults.standard.data(forKey: key) else { return [] }; return (try? JSONDecoder().decode([DraftAttachment].self, from: data)) ?? [] }
    func addAttachment(data: Data, name: String, image: Bool) throws {
        guard attachments.count < 5 else { throw PocketError.message(L10n.string("添付は5個までです")) }
        let item = try DraftAttachment.make(data: data, name: name, image: image)
        guard attachments.reduce(0, { $0 + $1.size }) + item.size <= 20 * 1024 * 1024 else { try? FileManager.default.removeItem(at: item.url); throw PocketError.message(L10n.string("添付は合計20MBまでです")) }
        attachments.append(item)
    }
    func removeAttachment(_ item: DraftAttachment) { attachments.removeAll { $0.id == item.id }; try? FileManager.default.removeItem(at: item.url) }
    private func persistPending() { guard let id = currentID else { return }; saveAttachments(pendingAttachments, key: "pendingAttachments." + id); if let text = pendingText, let requestID = pendingRequestID { UserDefaults.standard.set(["text": text, "requestId": requestID], forKey: "pending." + id) } else { UserDefaults.standard.removeObject(forKey: "pending." + id) } }
    private func restorePending() { let value = UserDefaults.standard.dictionary(forKey: "pending." + (currentID ?? "")); pendingText = value?["text"] as? String; pendingRequestID = value?["requestId"] as? String; pendingAttachments = readAttachments(key: "pendingAttachments." + (currentID ?? "")) }
    private func cacheURL(_ id: String) -> URL? {
        guard !id.contains("/"), !id.contains(".."), let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return root.appendingPathComponent("conversation-\(id).json")
    }
    private func saveCache(_ snapshot: ChatSnapshot, force: Bool = false) {
        guard force || !snapshot.running || Date().timeIntervalSince(lastCacheWrite) > 10 else { return }
        lastCacheWrite = Date()
        guard let url = cacheURL(snapshot.id) else { return }
        let raw = snapshot.raw
        cacheQueue.async {
            guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtection])
        }
    }
    private func loadCache(_ id: String) -> ChatSnapshot? {
        guard let url = cacheURL(id), let data = try? Data(contentsOf: url), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }; return ChatSnapshot(value)
    }
    private func loadDemo() {
        demo = true; paired = true; connected = true
        models = [ModelOption(provider: "qwen-local", model: "qwen3.8-flash-next", name: "Qwen 3.8 Flash", efforts: [])]; selectedModel = models[0].id
        let title = L10n.string("いつものAIを、ポケットに。")
        currentID = "demo"; conversations = [Conversation(["id": "demo", "title": title, "updatedAt": Date().timeIntervalSince1970 * 1000])]
        chat = ChatSnapshot(["id": "demo", "title": title, "messages": [["id": "1", "role": "user", "text": L10n.string("外出中もDGXのAIと話せる？")], ["id": "2", "role": "assistant", "text": L10n.string("はい。自宅のDGX Sparkにつないで、ここから会話を続けられます。\n\n**画面を閉じても大丈夫。**\n回答が完了すると、iPhoneに通知が届きます。\n\nモデルの切り替えや基本設定も、右上の設定から操作できます。")]]])
    }
}
