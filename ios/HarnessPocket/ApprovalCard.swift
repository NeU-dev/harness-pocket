import SwiftUI

struct ApprovalCard: View {
    @EnvironmentObject var model: AppModel
    let approval: Approval
    @State private var selections: [String: Set<String>] = [:]
    @State private var custom: [String: String] = [:]
    @State private var submitting = false
    @State private var showPermissions = false
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                Label(L10n.string(approval.event == "approval/request" ? "操作の承認" : "回答を待っています"), systemImage: approval.event == "approval/request" ? "hand.raised" : "bubble.left.and.bubble.right")
                    .font(.headline).foregroundStyle(PocketTheme.text)
            }
            if approval.event == "approval/request" {
                Text(approval.title).font(.subheadline.weight(.semibold))
                if !approval.reason.isEmpty { Text(approval.reason).font(.footnote).textSelection(.enabled) }
                HStack { Button("拒否", role: .destructive) { answer("rejected") }.buttonStyle(.bordered); Spacer(); Button("今回のみ許可") { answer("allowed-once") }.buttonStyle(.borderedProminent).tint(PocketTheme.buttonFill).foregroundStyle(.white) }
                Button("権限の設定を選ぶ") { showPermissions = true }.font(.footnote)
            } else {
                ForEach(approval.questions) { question in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(question.question).font(.subheadline.weight(.medium))
                        if !question.detail.isEmpty { DisclosureGroup("詳細を読む") { MarkdownMessage(text: question.detail) } }
                        ForEach(question.options, id: \.self) { option in
                            Button {
                                var selected = selections[question.id] ?? []
                                if question.multiple { if selected.contains(option) { selected.remove(option) } else { selected.insert(option) } } else { selected = [option] }
                                selections[question.id] = selected
                            } label: { HStack { Image(systemName: (selections[question.id] ?? []).contains(option) ? "checkmark.circle.fill" : "circle"); Text(option).multilineTextAlignment(.leading); Spacer() }.foregroundStyle(PocketTheme.text) }.buttonStyle(.bordered)
                        }
                        TextField("自分の言葉で回答", text: Binding(get: { custom[question.id] ?? "" }, set: { custom[question.id] = $0 }), prompt: Text("自分の言葉で回答").foregroundColor(PocketTheme.secondary), axis: .vertical).foregroundStyle(PocketTheme.text).textFieldStyle(.roundedBorder)
                    }
                }
                Button("回答する") {
                    let answers: [[String: Any]] = approval.questions.map { q in var item: [String: Any] = ["id": q.id, "selected": Array(selections[q.id] ?? [])]; if let text = custom[q.id], !text.isEmpty { item["custom"] = text }; return item }
                    answer(["answers": answers])
                }.buttonStyle(.borderedProminent).tint(PocketTheme.buttonFill).foregroundStyle(.white).disabled(approval.questions.contains { (selections[$0.id] ?? []).isEmpty && (custom[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
        }.padding(18).background(PocketTheme.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 20)).overlay(RoundedRectangle(cornerRadius: 20).stroke(PocketTheme.accent.opacity(0.2))).disabled(submitting || !model.connected)
            .sheet(isPresented: $showPermissions) { NavigationStack { PermissionSettingsView().toolbar { ToolbarItem(placement: .confirmationAction) { Button("閉じる") { showPermissions = false } } } }.environmentObject(model) }
    }
    private func answer(_ value: Any) { submitting = true; Task { await model.answer(approval, value: value); submitting = false } }
}
