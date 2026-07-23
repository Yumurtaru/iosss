import UIKit
import UserNotifications
import FirebaseCore
import FirebaseMessaging

// AppDelegate premium-клиента. Push доставляется через Firebase Cloud Messaging
// (тот же FCM-канал, что использует сервер для Android — core/Push.php, FCM HTTP v1):
// APNs-токен отдаётся в FCM, FCM возвращает свой токен, его и шлём на
// POST /api/v1/push/register (Core/Push.swift), platform: "ios".
// Требуется GoogleService-Info.plist в бандле; без него Firebase не инициализируется,
// приложение работает как обычно (просто без push) — не падает.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate, MessagingDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Инициализируем Firebase, только если есть конфиг-файл (иначе configure() падает).
        if Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil {
            FirebaseApp.configure()
            Messaging.messaging().delegate = self
        }
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

    // APNs-токен получен → отдаём его Firebase. FCM вернёт свой токен в
    // messaging(_:didReceiveRegistrationToken:) — именно его шлём на бэкенд.
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        if FirebaseApp.app() != nil {
            Messaging.messaging().apnsToken = deviceToken
        } else {
            // Firebase не сконфигурирован (нет plist) — фолбэк: сырой APNs-токен
            // (сработает, если бэкенд когда-нибудь получит прямой APNs-канал).
            Push.shared.fcmToken = deviceToken.map { String(format: "%02x", $0) }.joined()
            Task { await Push.shared.registerIfPossible() }
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Тихо игнорируем: push не критичен для работы приложения.
    }

    // FCM-токен (обновляется при первичной регистрации и ротации) → на бэкенд.
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let token = fcmToken, !token.isEmpty else { return }
        Push.shared.fcmToken = token
        Task { await Push.shared.registerIfPossible() }
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
