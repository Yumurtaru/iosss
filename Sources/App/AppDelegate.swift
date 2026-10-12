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
        // Кэш картинок. AsyncImage ходит через общий URLCache, а у него по
        // умолчанию ~0,5 МБ памяти и 10 МБ диска: фото каталога вытесняли друг
        // друга, и при прокрутке те же картинки качались заново. API-запросы
        // этот кэш не используют (.reloadIgnoringLocalCacheData).
        URLCache.shared = URLCache(memoryCapacity: 50 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024)
        // Сбрасываем бейдж на иконке при запуске.
        application.applicationIconBadgeNumber = 0
        // Запрос разрешения на пуш — ГАРАНТИРОВАННО при старте (не зависит от .task/онбординга,
        // которые могут не сработать под fullScreenCover). iOS покажет окно один раз.
        requestPushAuth()
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
    /// Последний разобранный push и когда. При запуске тапом по уведомлению iOS
    /// отдаёт его дважды: в launchOptions и в didReceive. Переход выполнялся два
    /// раза — дважды перечитывался список заказов, дважды закрывались окна.
    private var lastHandled: (key: String, at: Date)?

    private func handleNotification(_ userInfo: [AnyHashable: Any]) {
        let type = (userInfo["type"] as? String) ?? ""
        let orderId = Self.intValue(userInfo["order_id"])
        // Текст уведомления тоже в ключе: два разных сообщения чата по одному
        // заказу за 5 с раньше склеивались в одно. Дубль одного push совпадает.
        let alert = (userInfo["aps"] as? [String: Any])?["alert"]
        let alertDict = alert as? [String: Any]
        let alertTitle = (alertDict?["title"] as? String) ?? ""
        let alertBody = (alertDict?["body"] as? String) ?? (alert as? String) ?? ""
        let dedupKey = ["type", "order_id", "status", "product_id", "slug", "screen", "ad_id", "booking_id", "ticket_id", "title", "body"]
            .map { k -> String in "\(k)=" + (userInfo[k].map { v in "\(v)" } ?? "") }.joined(separator: "&")
            + "&aps_title=" + alertTitle + "&aps_body=" + alertBody
        if let last = lastHandled, last.key == dedupKey, Date().timeIntervalSince(last.at) < 5 { return }
        lastHandled = (dedupKey, Date())
        // П-21.1: «цена снизилась / снова в наличии» — только product_id без type.
        let productId = Self.intValue(userInfo["product_id"])
        // Новое заведение в городе: сервер присылает slug — это ключ экрана
        // организации (OrgView(shopSlug:)). RootTabView покажет её поверх
        // активного таба.
        let orgSlug = (userInfo["slug"] as? String) ?? ""
        // П-21.1: push без type (бронь жилья, объявление) — переход по ключам.
        // Новые ключи order_status (shop_id, shop_type, status_title,
        // is_appointment) на переход не влияют: он по-прежнему по order_id.
        // Неизвестный type без ключей — просто открываем приложение.
        let screen = (userInfo["screen"] as? String) ?? ""
        let adId = Self.intValue(userInfo["ad_id"])
        DispatchQueue.main.async {
            if type == "new_shop", !orgSlug.isEmpty {
                NavCoordinator.shared.openOrg(slug: orgSlug)
            } else if type == "order_chat", let id = orderId, id > 0 {
                // Открытые корзина/«Жильё» не дали бы показать чат — сначала закрываем.
                NavCoordinator.shared.revealForPush(closeAll: false) {
                    NavCoordinator.shared.openChat(orderId: id)
                }
            } else if let id = orderId, id > 0, !Session.shared.isLoggedIn {
                // Вышли из аккаунта, а push о заказе пришёл: раньше открывалась
                // деталь заказа без входа — «Сессия истекла» вместо экрана. Ведём
                // на вкладку «Заказы»: там «Войдите в аккаунт» с кнопкой входа.
                NavCoordinator.shared.revealForPush(closeAll: true) {
                    DeepLinkRouter.shared.requestedTab = 3
                }
            } else if let id = orderId, id > 0 {
                // OrdersView наблюдает pendingOrderDetail и открывает деталь; RootTabView
                // переключает на таб «Заказы». Окна поверх вкладок закрываем, иначе
                // вкладка переключалась незаметно под ними.
                NavCoordinator.shared.revealForPush(closeAll: true) {
                    NavCoordinator.shared.pendingOrderDetail = id
                }
            } else if type.isEmpty, let pid = productId, pid > 0 {
                // П-21.1: товар подешевел / снова в наличии — карточка товара на Главной.
                NavCoordinator.shared.revealForPush(closeAll: true) {
                    DeepLinkRouter.shared.requestedTab = 0
                    NavCoordinator.shared.pendingProductId = pid
                }
            } else if screen == "wallet" || type == "support" {
                // П-21.1: кошелёк (screen=wallet) и ответ поддержки (type=support) —
                // оба раздела в профиле; раньше тап просто открывал приложение.
                NavCoordinator.shared.revealForPush(closeAll: true) {
                    DeepLinkRouter.shared.requestedTab = 0
                    NavCoordinator.shared.profileOpen = true
                }
            } else if screen == "trips" {
                // П-21.1: бронь жилья (screen=trips + booking_id) — раздел «Жильё»,
                // оттуда «Мои поездки».
                NavCoordinator.shared.revealForPush(closeAll: true) {
                    NavCoordinator.shared.openLodging()
                }
            } else if let a = adId, a > 0 {
                // П-21.1: объявление истекает/заблокировано — вкладка «Объявления».
                NavCoordinator.shared.revealForPush(closeAll: true) {
                    DeepLinkRouter.shared.requestedTab = 4
                }
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
