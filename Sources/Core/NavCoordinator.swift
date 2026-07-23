import Combine
import Foundation

/// Централизованный координатор навигации premium-клиента.
///
/// Зачем нужен: экраны, открытые глубоко внутри стека таба (например OrgView,
/// созданный из Home / Discover / Listing), не получают колбэков от RootTabView
/// напрямую. Cart — глобальный синглтон, поэтому и «показать корзину / чат»
/// делаем через общий синглтон-координатор (тот же паттерн `.shared`
/// + `@EnvironmentObject`, что у Cart / Session / DeepLinkRouter).
///
/// RootTabView наблюдает эти флаги и показывает флоу корзины и чат ГЛОБАЛЬНО
/// поверх активного таба. Контракт API не затрагивается — это чистый UI-слой.
final class NavCoordinator: ObservableObject {
    static let shared = NavCoordinator()
    private init() {}

    /// Показать полноэкранный флоу корзины (Корзина → Оформление → Успех).
    @Published var showCart = false

    /// Открыть чат: nil — не показывать; -1 — общий список чатов; иначе — по orderId.
    @Published var chatOrderId: Int?

    /// Заказ, который нужно открыть в табе «Заказы» (после успешного оформления,
    /// кнопка «Следить за заказом»). OrdersView наблюдает и пушит деталь у себя.
    @Published var pendingOrderDetail: Int?

    // ── Диалог конфликта корзины (single-store) ──
    /// Показать ли диалог конфликта.
    @Published var cartConflict = false
    /// Имя магазина, который сейчас в корзине (для текста диалога).
    @Published var conflictCurrentShop: String?
    /// Имя магазина, товар из которого добавляют.
    @Published var conflictNewShop: String?
    /// Действие «Очистить и начать новую» (очищает корзину и добавляет товар).
    var conflictConfirm: (() -> Void)?

    /// Попросить подтверждение при смене магазина корзины. Диалог покажет
    /// RootTabView через `.cartConflictDialog`. onConfirm выполняется по «Очистить».
    func requestCartConflict(currentShop: String?, newShop: String?, onConfirm: @escaping () -> Void) {
        conflictCurrentShop = currentShop
        conflictNewShop = newShop
        conflictConfirm = onConfirm
        cartConflict = true
    }

    /// Удобные хелперы (читабельные точки вызова из экранов).
    func openCart() { showCart = true }
    func openChat(orderId: Int) { chatOrderId = orderId }
    func openChatList() { chatOrderId = -1 }
    func closeChat() { chatOrderId = nil }
}
