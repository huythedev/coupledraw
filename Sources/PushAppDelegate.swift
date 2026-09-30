import UIKit
import UserNotifications

extension Notification.Name {
    static let coupleDrawPushToken = Notification.Name("CoupleDrawPushToken")
    static let coupleDrawPushFailure = Notification.Name("CoupleDrawPushFailure")
}

final class PushAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "apnsDeviceToken")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .coupleDrawPushToken, object: nil)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .coupleDrawPushFailure, object: error.localizedDescription)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
