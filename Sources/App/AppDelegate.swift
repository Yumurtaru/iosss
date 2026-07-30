import UIKit
import UserNotifications

// AppDelegate premium-клиента. Push регистрируется напрямую через APNs (без Firebase):
// device-токен уходит на POST /api/v1/push/register (Core/Push.swift), platform: "ios".
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        application.applicationIconBadgeNumber = 0
        // Запрос разрешения на пуш — ГАРАНТИРОВАННО при старте (не зависит от .task/онбординга).
        requestPushAuth()
        if let remote = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            handleNotification(remote)
        }
        return true
    }

    func requestPushAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Push.shared.fcmToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await Push.shared.registerIfPossible() }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        handleNotification(response.notification.request.content.userInfo)
        completionHandler()
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        completionHandler(.newData)
    }

    private func handleNotification(_ userInfo: [AnyHashable: Any]) {
        let type = (userInfo["type"] as? String) ?? ""
        let orderId = Self.intValue(userInfo["order_id"])
        DispatchQueue.main.async {
            if type == "order_chat", let id = orderId, id > 0 {
                NavCoordinator.shared.openChat(orderId: id)
            } else if let id = orderId, id > 0 {
                NavCoordinator.shared.pendingOrderDetail = id
            }
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }

    private static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) }
        return nil
    }
}