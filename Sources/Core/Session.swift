import Foundation
import Combine


final class Session: ObservableObject {
    static let shared = Session()
    @Published private(set) var token: String?
    @Published var cityId: Int? {
        didSet {
            UserDefaults.standard.set(cityId ?? 0, forKey: "cityId")
            // Город сменился — сообщаем серверу вместе с push-токеном, иначе
            // уведомления о новых заведениях продолжат приходить по старому
            // городу. Вызов идемпотентен и молча выходит, если вход не сделан.
            guard cityId != oldValue else { return }
            Task { await Push.shared.registerIfPossible() }
        }
    }
    @Published var cityName: String? { didSet { UserDefaults.standard.set(cityName, forKey: "cityName") } }

    var isLoggedIn: Bool { token != nil }

    private init() {
        token = TokenStore.access
        let c = UserDefaults.standard.integer(forKey: "cityId"); cityId = c == 0 ? nil : c
        cityName = UserDefaults.standard.string(forKey: "cityName")
        // При 401 (истёкший токен) аккуратно выходим из аккаунта.
        API.shared.onUnauthorized = { [weak self] in self?.signOut() }
    }
    /// refresh — токен продления (30 дней): API тихо обновляет access при 401 (security-аудит).
    func signIn(_ token: String, refresh: String? = nil) {
        self.token = token
        TokenStore.access = token
        if let r = refresh, !r.isEmpty { TokenStore.refresh = r }
        // После входа: спросить разрешение на push (если ещё не спрашивали) и отправить
        // device-токен на бэкенд — токен привязывается к вошедшему пользователю.
        Push.shared.requestAuthorization()
        Task { await Push.shared.registerIfPossible() }
    }
    /// clearLocalData — только для явного выхода и удаления аккаунта. При
    /// истёкшей сессии (401) корзина остаётся: человек просто войдёт снова.
    /// Номер неподтверждённой оплаты Plus убирается при любом выходе: он
    /// привязан к человеку (подписку после оплаты всё равно включит сервер
    /// по уведомлению ЮKassa).
    func signOut(clearLocalData: Bool = false) {
        let wasLoggedIn = token != nil
        token = nil
        TokenStore.clear()
        API.clearCookies()   // cookie прежних версий не должны пережить выход
        // Корзина, история поиска и «недавно смотрели» лежат на телефоне. Раньше
        // следующий вошедший видел всё это от прежнего владельца, а первая правка
        // корзины уходила на сервер «брошенной корзиной» уже от его имени.
        // Только для настоящего выхода: onUnauthorized зовёт signOut и у гостя,
        // и случайный 401 не должен стирать гостю корзину.
        // Номер платежа Плюс привязан к человеку — убираем при любом выходе
        // (и по истёкшей сессии): иначе следующий вошедший активировал бы чужой.
        if wasLoggedIn {
            UserDefaults.standard.removeObject(forKey: "plus_pending_payment_id")
            UserDefaults.standard.removeObject(forKey: "plus_pending_payment_at")
        }
        if wasLoggedIn && clearLocalData {
            Task { @MainActor in
                Cart.shared.clear()
                SearchHistoryStore.clear()
                RecentStore.clear()
            }
        }
    }
}
