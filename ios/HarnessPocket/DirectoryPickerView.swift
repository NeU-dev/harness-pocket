import SwiftUI

struct DirectoryPickerView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var listing: DirectoryListing?
    @State private var requestedPath: String?
    @State private var search = ""
    @State private var showHidden = false
    @State private var loading = false
    @State private var saving = false
    @State private var error: String?

    private var entries: [RemoteDirectory] {
        (listing?.entries ?? []).filter {
            (showHidden || !$0.hidden) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        List {
            if let listing {
                Section {
                    Text(listing.path).font(.subheadline).textSelection(.enabled)
                    Button { select(listing.path) } label: {
                        Label("このフォルダを使う", systemImage: "checkmark.circle.fill")
                            .font(.headline)
                    }.disabled(loading || saving)
                } header: { Text("現在のフォルダ") }
                  footer: { Text("この場所を登録し、新しい会話の作業場所に設定します。") }
                Section {
                    if listing.path != listing.home {
                        Button { navigate(listing.home) } label: { Label("ホームへ", systemImage: "house") }
                    }
                    if let parent = listing.parent {
                        Button { navigate(parent) } label: { Label("1つ上のフォルダへ", systemImage: "arrow.turn.up.left") }
                    }
                    ForEach(entries) { entry in
                        Button { navigate(entry.path) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder").foregroundStyle(PocketTheme.accent)
                                Text(entry.name).foregroundStyle(PocketTheme.text)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(PocketTheme.secondary)
                            }.padding(.vertical, 3)
                        }
                    }
                    if entries.isEmpty {
                        Text(L10n.string(search.isEmpty ? "表示できるサブフォルダはありません" : "一致するフォルダはありません"))
                            .foregroundStyle(PocketTheme.secondary)
                    }
                } header: { Text("フォルダを開く") }
                  footer: {
                    if listing.truncated { Text("フォルダ数が多いため一部を表示しています。見つからない場所は、設定からパスを直接指定できます。") }
                }
                .disabled(loading || saving)
            }
            if loading || saving { HStack { ProgressView(); Text(L10n.string(saving ? "作業場所を設定中…" : "DGXのフォルダを読み込み中…")) }.font(.subheadline) }
            if let error {
                Section {
                    Text(error).foregroundStyle(PocketTheme.secondary)
                    Button("もう一度読み込む") { Task { await load(requestedPath) } }
                    if listing == nil { Button("ホームを開く") { navigate(nil) } }
                }.disabled(loading || saving)
            }
            Toggle("隠しフォルダを表示", isOn: $showHidden)
        }
        .foregroundStyle(PocketTheme.text)
        .navigationTitle("DGXのフォルダ")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "この階層のフォルダを検索")
        .task { if listing == nil { await load(nil) } }
    }

    private func navigate(_ path: String?) {
        search = ""
        Task { await load(path) }
    }

    @MainActor private func load(_ path: String?) async {
        guard !loading, !saving else { return }
        requestedPath = path; loading = true; error = nil
        defer { loading = false }
        do {
            let result = try await model.directories(path)
            try Task.checkCancellation()
            listing = result
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }

    private func select(_ path: String) {
        saving = true; error = nil
        Task { @MainActor in
            defer { saving = false }
            do { try await model.selectDirectory(path); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }
}
