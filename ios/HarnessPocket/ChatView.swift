import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var model: AppModel
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var showModel = false
    @State private var showDirectories = false
    @State private var showConnection = false
    @State private var followBottom = true
    @State private var bottomVisible = true
    @State private var viewportHeight: CGFloat = 0
    @State private var jumpRequest = 0
    @State private var explicitJump = 0
    @State private var photos: [PhotosPickerItem] = []
    @State private var importFiles = false
    @FocusState private var composing: Bool
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !model.connected {
                    Button { showConnection = true } label: {
                        HStack(spacing: 8) { Image(systemName: "wifi.exclamationmark"); Text("DGXへ再接続中 · 接続を確認").font(.caption); Image(systemName: "chevron.right").font(.caption2) }
                            .padding(10).frame(maxWidth: .infinity).foregroundStyle(PocketTheme.text).background(Color.orange.opacity(0.09))
                    }.buttonStyle(.plain)
                }
                if model.demo { Text("画面プレビュー · 実際の会話ではありません").font(.caption2).foregroundStyle(PocketTheme.secondary).padding(6) }
                if model.chat == nil { welcome } else { transcript }
                composer.layoutPriority(1)
            }
            .background(PocketTheme.background)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button { showHistory = true } label: { Image(systemName: "line.3.horizontal").font(.title3) }.accessibilityLabel("会話履歴").disabled(model.busy || model.importing) }
                ToolbarItem(placement: .principal) {
                    Button { showModel = true } label: {
                        VStack(spacing: 3) { HStack(spacing: 5) { Text("Harness Pocket").font(.headline); Image(systemName: "chevron.down").font(.caption2.weight(.bold)) }; HStack(spacing: 4) { Circle().fill(model.connected ? .green : .orange).frame(width: 5, height: 5); Text(model.modelName).font(.caption2).foregroundStyle(PocketTheme.secondary) } }.foregroundStyle(PocketTheme.text)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("設定") }
                ToolbarItem(placement: .topBarTrailing) { Button { model.newChat() } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel("新しいチャット").disabled(model.busy || model.importing) }
            }
            .toolbarBackground(PocketTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .fileImporter(isPresented: $importFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                do {
                    let urls = try result.get()
                    for url in urls {
                        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
                        guard (values.fileSize ?? 0) <= 10 * 1024 * 1024 else { throw PocketError.message(L10n.string("添付は1個10MBまでです")) }
                        try model.addAttachment(data: Data(contentsOf: url), name: url.lastPathComponent, image: values.contentType?.conforms(to: .image) == true)
                    }
                } catch { model.error = error.localizedDescription }
            }
            .onChange(of: photos) { _, items in
                guard !items.isEmpty else { return }
                model.importing = true
                Task { @MainActor in
                    defer { photos = []; model.importing = false }
                    do { for item in items { if let data = try await item.loadTransferable(type: Data.self) { try model.addAttachment(data: data, name: L10n.string("写真.jpg"), image: true) } } }
                    catch { model.error = error.localizedDescription }
                }
            }
            .sheet(isPresented: $showHistory) { HistoryView().environmentObject(model) }
            .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
            .sheet(isPresented: $showModel) { ModelPickerView().environmentObject(model).presentationDetents([.medium, .large]) }
            .sheet(isPresented: $showDirectories) { NavigationStack { DirectoryPickerView() }.environmentObject(model) }
            .sheet(isPresented: $showConnection) { NavigationStack { ConnectionSettingsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { showConnection = false } } } }.environmentObject(model) }
            .onAppear {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--settings") { showSettings = true }
                if ProcessInfo.processInfo.arguments.contains("--history") { showHistory = true }
                if ProcessInfo.processInfo.arguments.contains("--directories") { showDirectories = true }
                if ProcessInfo.processInfo.arguments.contains("--connection-qa") { model.connected = false; showConnection = true }
                #endif
            }
            .task {
                #if DEBUG
                if let sessionID = ProcessInfo.processInfo.environment["POCKET_OPEN_SESSION"] {
                    for _ in 0..<60 { if model.connected { break }; try? await Task.sleep(for: .milliseconds(200)) }
                    await model.open(sessionID)
                }
                await PerformanceFixture.run(model)
                if ProcessInfo.processInfo.arguments.contains("--welcome-qa") { model.newChat(); model.draft = "" }
                if ProcessInfo.processInfo.arguments.contains("--question-qa") {
                    model.draft = ""
                    model.chat = ChatSnapshot(["id": "question-qa", "title": L10n.string("質問の表示確認"), "messages": [["id": "qa-user", "role": "user", "text": L10n.string("次の作業を一緒に決めよう。")]], "approvals": [["eventId": "qa-question", "event": "user-questions/request", "request": ["questions": [["id": "next", "question": L10n.string("どちらから進めましょう？"), "options": [["label": L10n.string("画面の使いやすさ")], ["label": L10n.string("通知の確認")]]]]]]]])
                }
                if ProcessInfo.processInfo.arguments.contains("--scroll-qa") {
                    let rows: [[String: Any]] = (0..<35).map { index in ["id": "qa-\(index)", "role": "assistant", "text": L10n.format("回答 %lld\n", Int64(index)) + String(repeating: L10n.string("長い会話のスクロールを確認します。\n"), count: 12), "reasoning": String(repeating: L10n.string("推論の長さによって画面の高さが変わります。\n"), count: 8)] }
                    model.chat = ChatSnapshot(["id": "scroll-qa", "title": L10n.string("スクロール検証"), "messages": rows + [["id": "last", "role": "assistant", "text": L10n.string("最下部の確認：ここが最後のメッセージです。")]]])
                }
                if ProcessInfo.processInfo.arguments.contains("--attachment-qa") {
                    model.newChat()
                    for item in model.attachments { model.removeAttachment(item) }
                    try? model.addAttachment(data: Data(L10n.string("添付テストの合言葉は POCKET_FILE_731 です。").utf8), name: L10n.string("検証ファイル.txt"), image: false)
                    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120))
                    let image = renderer.image { context in UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 120)) }
                    if let data = image.pngData() { try? model.addAttachment(data: data, name: L10n.string("赤い画像.png"), image: true) }
                    model.draft = L10n.string("添付のテキストファイルの合言葉と、画像の色を答えてください。ファイルは変更しないでください。")
                }
                if ProcessInfo.processInfo.arguments.contains("--keyboard") {
                    model.newChat()
                    model.draft = L10n.string("入力中の文章が見えるか確認します。\n複数行のメッセージでも\nキーボードの上に入力欄が収まり\n最後の行まで確認できます。")
                    try? await Task.sleep(for: .milliseconds(400))
                    composing = true
                }
                #endif
            }
        }
    }
    private var welcome: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
            if composing {
                Label("何から始めましょう？", systemImage: "sparkle")
                    .font(.title3.weight(.semibold)).foregroundStyle(PocketTheme.text)
            } else {
            Spacer(minLength: 12)
            Image(systemName: "bubble.left.and.text.bubble.right").font(.system(size: 46, weight: .light)).foregroundStyle(PocketTheme.accent)
            Text("いつものAIを、\nポケットに。").font(.system(size: 33, weight: .semibold, design: .rounded)).tracking(-0.8).lineSpacing(7)
            Text("自宅のDGX Sparkとつながる。\n思いついたことから、話してみましょう。").font(.subheadline).foregroundStyle(PocketTheme.secondary).lineSpacing(5)
            Spacer(minLength: 24)
            VStack(spacing: 9) {
                suggestion("考えを整理する", "今考えていることを一緒に整理してください。", icon: "lightbulb")
                suggestion("コードの相談", "コードについて相談したいです。", icon: "chevron.left.forwardslash.chevron.right")
            }
            if !model.notificationsEnabled || !model.notificationDeviceRegistered {
                Button { Task { await model.enableNotifications(true) } } label: { Label("完了・確認待ちの通知を有効にする", systemImage: "bell.badge").font(.footnote) }.frame(maxWidth: .infinity).padding(.top, 4)
            }
            }
                }.padding(.horizontal, 28).padding(.vertical, 24)
                    .frame(maxWidth: 650, minHeight: geometry.size.height, alignment: .topLeading)
                    .frame(maxWidth: .infinity)
            }.scrollDismissesKeyboard(.interactively)
        }
    }
    private func suggestion(_ title: String, _ text: String, icon: String) -> some View {
        Button { model.draft = L10n.string(text); composing = true } label: { HStack { Image(systemName: icon).frame(width: 24).foregroundStyle(PocketTheme.accent); Text(L10n.string(title)).font(.subheadline); Spacer(); Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(PocketTheme.secondary) }.padding(16).background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.055))) }.foregroundStyle(PocketTheme.text)
    }
    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 25) {
                    if model.chat?.hasMore == true { Button("以前のメッセージを読み込む") { Task { await model.older() } }.font(.footnote).frame(maxWidth: .infinity) }
                    ForEach(model.chat?.messages ?? []) { message in MessageView(message: message) { Task { await model.regenerate(before: message) } }.equatable() }
                    if let text = model.pendingText {
                        VStack(alignment: .trailing, spacing: 6) { if !model.pendingAttachments.isEmpty { AttachmentStrip(items: model.pendingAttachments) }; Text(text).padding(15).background(PocketTheme.bubble, in: RoundedRectangle(cornerRadius: 21)); HStack { Text("送信を確認中").font(.caption).foregroundStyle(PocketTheme.secondary); Button("再試行") { Task { await model.send(retry: true) } }.font(.caption) } }.frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    ForEach(model.chat?.approvals ?? []) { approval in ApprovalCard(approval: approval) }
                    if model.chat?.running == true { HStack(spacing: 9) { ProgressView().controlSize(.small); Text("DGXで処理中…").font(.caption).foregroundStyle(PocketTheme.secondary) } }
                    if let error = model.chat?.error { Label(L10n.string(error), systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange) }
                    if ["aborted", "interrupted", "max-tokens", "blocked"].contains(model.chat?.endReason ?? "") { Text("処理は中断または上限に達しました。内容を確認して続けられます。").font(.caption).foregroundStyle(PocketTheme.secondary) }
                    Color.clear.frame(height: 1).id("bottom").background(GeometryReader { geometry in Color.clear.preference(key: BottomPositionKey.self, value: geometry.frame(in: .named("transcript")).maxY) })
                }.padding(.horizontal, 20).padding(.vertical, 24).frame(maxWidth: 750).frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "transcript")
            .background(GeometryReader { geometry in Color.clear.onAppear { viewportHeight = geometry.size.height }.onChange(of: geometry.size.height) { _, height in viewportHeight = height; if followBottom { jumpRequest += 1 } } })
            .onPreferenceChange(BottomPositionKey.self) { bottom in bottomVisible = bottom > 0 && bottom <= viewportHeight + 26 }
            .defaultScrollAnchor(.bottom)
            .task(id: jumpRequest) {
                // One scroll after SwiftUI has laid out the coalesced update.
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, followBottom else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .task(id: explicitJump) {
                // A user jump may need a second layout pass for lazy row heights.
                for _ in 0..<3 {
                    guard !Task.isCancelled, followBottom else { return }
                    proxy.scrollTo("bottom", anchor: .bottom)
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(DragGesture().onChanged { _ in followBottom = false })
            .onChange(of: model.chat?.messages.last) { _, _ in if followBottom { jumpRequest += 1 } }
            .onChange(of: model.chat?.approvals.count) { _, _ in if followBottom { jumpRequest += 1 } }
            .onChange(of: model.chat?.running) { _, _ in if followBottom { jumpRequest += 1 } }
            .onChange(of: model.currentID) { _, _ in followBottom = true; explicitJump += 1 }
            .onChange(of: model.chat?.id) { _, _ in followBottom = true; explicitJump += 1 }
            .overlay(alignment: .bottomTrailing) {
                if !bottomVisible { Button { followBottom = true; explicitJump += 1 } label: { Image(systemName: "arrow.down").padding(12).background(.regularMaterial, in: Circle()) }.padding(16).accessibilityLabel("最新のメッセージへ") }
            }
        }
    }
    private var composer: some View {
        VStack(spacing: 7) {
            if !model.attachments.isEmpty { AttachmentStrip(items: model.attachments) { model.removeAttachment($0) }.disabled(model.busy || model.importing) }
            if model.importing { ProgressView("添付を読み込み中…").font(.caption) }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    PhotosPicker(selection: $photos, maxSelectionCount: max(1, 5 - model.attachments.count), matching: .images) { Label("写真を選ぶ", systemImage: "photo") }
                    Button { importFiles = true } label: { Label("ファイルを選ぶ", systemImage: "doc") }
                } label: { Image(systemName: "plus").font(.title3).frame(width: 34, height: 44) }.padding(.leading, 6).disabled(model.busy || model.importing || model.attachments.count >= 5).accessibilityLabel("画像やファイルを添付")
                TextField("メッセージを入力", text: $model.draft, prompt: Text("メッセージを入力").foregroundColor(PocketTheme.secondary), axis: .vertical).foregroundStyle(PocketTheme.text).lineLimit(1...5).focused($composing).padding(.vertical, 10).padding(.leading, 2)
                Button {
                    followBottom = true
                    Task { if model.chat?.running == true && model.draft.isEmpty && model.attachments.isEmpty { await model.stop() } else { await model.send() } }
                } label: {
                    Image(systemName: model.chat?.running == true && model.draft.isEmpty && model.attachments.isEmpty ? "stop.fill" : "arrow.up").font(.system(size: 16, weight: .bold)).foregroundStyle(.white).frame(width: 37, height: 37).background(model.connected ? PocketTheme.buttonFill : Color.gray, in: Circle())
                }.padding(6).disabled(!model.connected || model.busy || model.importing || (model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.attachments.isEmpty && model.chat?.running != true)).accessibilityLabel(L10n.string(model.chat?.running == true && model.draft.isEmpty && model.attachments.isEmpty ? "回答を停止" : "送信"))
            }.background(.background, in: RoundedRectangle(cornerRadius: 27)).overlay(RoundedRectangle(cornerRadius: 27).stroke(.primary.opacity(0.08)))
            if !composing {
                Text(L10n.string(model.chat?.running == true ? "画面を閉じても、DGXで処理を続けます" : "Harness Pocket · あなたのDGXとつながる")).font(.system(size: 11)).foregroundStyle(PocketTheme.secondary)
            }
        }.padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6).background(PocketTheme.background)
    }
}
struct MessageView: View, Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.message == rhs.message }
    let message: Message
    var regenerate: () -> Void
    var body: some View {
        if message.role == "user" {
            VStack(alignment: .trailing, spacing: 10) { ForEach(message.attachments) { SentAttachmentView(attachment: $0) }; if !message.text.isEmpty { Text(message.text) } }.foregroundStyle(PocketTheme.text).textSelection(.enabled).padding(.horizontal, 17).padding(.vertical, 13).background(PocketTheme.bubble, in: RoundedRectangle(cornerRadius: 22)).frame(maxWidth: .infinity, alignment: .trailing).padding(.leading, 35)
        } else if message.role == "tool" {
            DisclosureGroup { VStack(alignment: .leading, spacing: 10) { Text(message.text).font(.system(.caption, design: .monospaced)); if !message.result.isEmpty { Divider(); Text(message.result).font(.caption) } }.textSelection(.enabled) } label: { Label(message.title, systemImage: "terminal").font(.caption.weight(.medium)) }.foregroundStyle(PocketTheme.text).tint(PocketTheme.accent).padding(13).background(PocketTheme.surface, in: RoundedRectangle(cornerRadius: 13))
        } else {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 6) { Image(systemName: "sparkle").foregroundStyle(PocketTheme.accent); Text("Harness").font(.caption.weight(.semibold)).foregroundStyle(PocketTheme.secondary) }
                if !message.reasoning.isEmpty { ReasoningView(text: message.reasoning, streaming: message.streaming && message.text.isEmpty) }
                if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { if message.streaming {
                    Text(message.text).font(.system(size: 16)).lineSpacing(7).foregroundStyle(PocketTheme.text).textSelection(.enabled)
                } else { MarkdownMessage(text: message.text.trimmingCharacters(in: .whitespacesAndNewlines)).equatable() } }
                if message.interrupted { Text("途中までの回答").font(.caption).foregroundStyle(.orange) }
                if !message.streaming && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack(spacing: 22) {
                        Button { UIPasteboard.general.string = message.text } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("回答をコピー")
                        Button(action: regenerate) { Image(systemName: "arrow.triangle.branch") }.accessibilityLabel("分岐して再生成する")
                    }.buttonStyle(.plain).font(.system(size: 16)).foregroundStyle(PocketTheme.secondary).padding(.top, 2)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
struct ReasoningView: View {
    let text: String
    let streaming: Bool
    @State private var expanded: Bool
    @State private var showFull = false
    init(text: String, streaming: Bool) {
        self.text = text; self.streaming = streaming
        _expanded = State(initialValue: streaming)
    }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if streaming && !showFull && text.count > 2000 {
                Button("推論の全文を表示") { showFull = true }.font(.caption)
            }
            Text(streaming && !showFull ? String(text.suffix(2000)) : text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 15)).lineSpacing(5)
                .foregroundStyle(PocketTheme.text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "brain").foregroundStyle(PocketTheme.accent)
                Text(L10n.string(streaming ? "推論中" : "推論内容")).font(.subheadline.weight(.semibold)).foregroundStyle(PocketTheme.text)
                if streaming { ProgressView().controlSize(.small).tint(PocketTheme.accent) }
            }
        }.tint(PocketTheme.accent).padding(15).background(PocketTheme.surface, in: RoundedRectangle(cornerRadius: 15))
    }
}
struct MarkdownMessage: View, Equatable {
    let text: String
    var body: some View {
        let parts = text.components(separatedBy: "```")
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index % 2 == 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        let lines = part.components(separatedBy: "\n")
                        HStack { Text(lines.first ?? "code").font(.caption2).foregroundStyle(PocketTheme.secondary); Spacer(); Button { UIPasteboard.general.string = lines.dropFirst().joined(separator: "\n") } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel("コードをコピー") }
                        ScrollView(.horizontal) { Text(lines.dropFirst().joined(separator: "\n")).font(.system(.footnote, design: .monospaced)).textSelection(.enabled) }
                    }.padding(14).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                } else if !part.isEmpty {
                    Text((try? AttributedString(markdown: part, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(part)).font(.system(size: 16)).lineSpacing(7).foregroundStyle(PocketTheme.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var search = ""
    @State private var renaming: Conversation?
    @State private var name = ""
    @State private var removing: Conversation?
    var body: some View {
        NavigationStack {
            List {
                Button { model.newChat(); dismiss() } label: { Label("新しいチャット", systemImage: "square.and.pencil") }
                ForEach(model.conversations.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }) { conversation in
                    Button { Task { await model.open(conversation.id); dismiss() } } label: { HStack { VStack(alignment: .leading, spacing: 6) { Text(conversation.title).lineLimit(2).foregroundStyle(PocketTheme.text); Text(Date(timeIntervalSince1970: conversation.updatedAt / 1000), style: .date).font(.caption).foregroundStyle(PocketTheme.secondary) }; Spacer(); if conversation.running { ProgressView().controlSize(.small) } } }
                    .swipeActions { Button("アーカイブ", role: .destructive) { removing = conversation }; Button("名前変更") { renaming = conversation; name = conversation.title }.tint(PocketTheme.accent) }
                }
            }.buttonStyle(.plain).foregroundStyle(PocketTheme.text).navigationTitle("会話履歴").searchable(text: $search, prompt: "会話名で検索")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } } }
                .refreshable { await model.perform { try await model.refreshList() } }
                .alert("会話の名前", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) { TextField("名前", text: $name); Button("保存") { if let c = renaming { Task { await model.rename(c.id, title: name) } } }; Button("キャンセル", role: .cancel) {} }
                .confirmationDialog("会話をアーカイブしますか？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) { Button("アーカイブ", role: .destructive) { if let c = removing { Task { await model.archive(c.id) } } } } message: { Text("Harnessの会話履歴は保持されます。") }
        }
    }
}
struct ModelPickerView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Picker("モデル", selection: $model.selectedModel) { ForEach(model.models) { m in Text(m.name).tag(m.id) } }.pickerStyle(.inline)
                if let selected = model.models.first(where: { $0.id == model.selectedModel }), !selected.efforts.isEmpty {
                    Picker("思考の強さ", selection: $model.effort) { Text("モデルの既定値").tag(""); ForEach(selected.efforts, id: \.self) { Text($0).tag($0) } }
                }
                Text("この会話の次のリクエストから適用します。全体の既定値は設定画面で変更できます。").font(.caption).foregroundStyle(PocketTheme.secondary)
            }.navigationTitle("モデルを選択").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("適用") { Task { await model.perform { try await model.changeModel(); dismiss() } } } } }
        }
    }
}

private struct BottomPositionKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
