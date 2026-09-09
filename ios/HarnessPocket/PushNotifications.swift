import UIKit
import UserNotifications

extension Notification.Name {
    static let pocketPushToken = Notification.Name("pocketPushToken")
    static let pocketOpenConversation = Notification.Name("pocketOpenConversation")
    static let pocketPushError = Notification.Name("pocketPushError")
}
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        NotificationCenter.default.post(name: .pocketPushToken, object: token)
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .pocketPushError, object: "通知登録: \(error.localizedDescription)")
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let sessionId = response.notification.request.content.userInfo["sessionId"] as? String, !sessionId.isEmpty {
            UserDefaults.standard.set(sessionId, forKey: "pendingNotificationSession")
            NotificationCenter.default.post(name: .pocketOpenConversation, object: sessionId)
        }
        completionHandler()
    }
}
