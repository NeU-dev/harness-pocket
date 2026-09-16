import SwiftUI

@main struct HarnessPocketApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = "system"
    var body: some Scene {
        WindowGroup {
            Group { if model.paired { ChatView() } else { PairingView() } }
                .environmentObject(model)
                .tint(PocketTheme.accent)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .task { model.resume() }
                .onChange(of: scenePhase) { _, phase in if phase == .active { model.resume() } else if phase == .background { model.pause() } }
                .onReceive(NotificationCenter.default.publisher(for: .pocketPushToken)) { note in if let token = note.object as? String { Task { await model.receivedToken(token) } } }
                .onReceive(NotificationCenter.default.publisher(for: .pocketOpenConversation)) { note in if let id = note.object as? String { Task { await model.open(id) } } }
                .onReceive(NotificationCenter.default.publisher(for: .pocketPushError)) { note in model.pushMessage = note.object as? String ?? L10n.string("通知登録に失敗しました") }
                .alert("確認してください", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("閉じる", role: .cancel) { model.error = nil } } message: { Text(model.error ?? "") }
        }
    }
}
enum PocketTheme {
    static let accent = adaptive(light: 0x4935B5, dark: 0xB8B2FF)
    static let buttonFill = Color(red: 0.345, green: 0.286, blue: 0.839)
    static let text = adaptive(light: 0x191B23, dark: 0xF3F4F7)
    static let secondary = adaptive(light: 0x525863, dark: 0xBEC3CF)
    static let surface = adaptive(light: 0xF0EEF5, dark: 0x22252E)
    static let bubble = adaptive(light: 0xEDE9F8, dark: 0x28253A)
    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
    static let background = Color(uiColor: UIColor { traits in traits.userInterfaceStyle == .dark ? UIColor(red: 0.075, green: 0.08, blue: 0.10, alpha: 1) : UIColor(red: 0.977, green: 0.973, blue: 0.965, alpha: 1) })
}
