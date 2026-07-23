import UIKit
import UserNotifications

// AppDelegate premium-клиента. Push регистрируется напрямую через APNs (без Firebase):
// device-токен уходит на POST /api/v1/push/register (Core/Push.swift), platform: "ios".
// Обработка уведомлений (тап → заказ/чат, foreground-баннер, бейдж) — здесь.
// Примечание: для реальной доставки нужен канал (FCM или прямой APNs на сервере) —
// это конфигурируется отдельно; на устройстве всё готово.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Сбрасываем бейдж на иконке при запуске.
        application.applicationIconBadgeNumber = 0
        // Холодный старт по тапу на уведомление: разбираем payload и маршрутизируем.
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

    // APNs-токен → hex-строка → на бэкенд.
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Push.shared.fcmToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await Push.shared.registerIfPossible() }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Тихо игнорируем: push не критичен для работы приложения.
    }

    // Показ уведомления, когда приложение открыто (баннер + звук).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

    // Тап по уведомлению (приложение в фоне/закрыто) → переход к заказу/чату.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        handleNotification(response.notification.request.content.userInfo)
        completionHandler()
    }

    // Тихий/фоновый data-push (обновление статуса) — просто подтверждаем.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        completionHandler(.newData)
    }

    // MARK: - Маршрутизация из payload уведомления
    // Сервер кладёт в data: type ("order_chat" | "order_status" | …) и order_id (строкой).
    // Чат по заказу → NavCoordinator.openChat; иначе с order_id → таб «Заказы» + деталь.
    private func handleNotification(_ userInfo: [AnyHashable: Any]) {
        let type = (userInfo["type"] as? String) ?? ""
        let orderId = Self.intValue(userInfo["order_id"])
        DispatchQueue.main.async {
            if type == "order_chat", let id = orderId, id > 0 {
                NavCoordinator.shared.openChat(orderId: id)
            } else if let id = orderId, id > 0 {
                // OrdersView наблюдает pendingOrderDetail и открывает деталь; RootTabView
                // переключает на таб «Заказы».
                NavCoordinator.shared.pendingOrderDetail = id
            }
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }

    /// Толерантно достаёт Int из payload (сервер шлёт order_id строкой).
    private static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) }
        return nil
    }
}
