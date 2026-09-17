import Combine
import Foundation

/// Связывает Siri/Shortcuts и внешние ссылки (Universal Links / custom scheme) с навигацией.
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()
    @Published var requestedTab: Int?     // 0 главная, 2 корзина, 3 заказы
    @Published var referralCode: String?  // код из ссылки .../r/КОД
    private init() {}

    /// Разбирает входящую ссылку:
    ///   https://yumurta.ru/r/КОД   / yumurta://r/КОД      — приглашение
    ///   https://yumurta.ru/shop/СЛАГ / yumurta://shop/СЛАГ — организация
    func handle(url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        // Организация: тот же экран, что открывается по тапу на уведомление
        // «новое заведение в городе».
        var shopSlug: String?
        if url.host == "shop", let first = parts.first {                       // yumurta://shop/СЛАГ
            shopSlug = first
        } else if let idx = parts.firstIndex(of: "shop"), idx + 1 < parts.count { // https://.../shop/СЛАГ
            shopSlug = parts[idx + 1]
        }
        if let slug = shopSlug, !slug.isEmpty {
            DispatchQueue.main.async { NavCoordinator.shared.openOrg(slug: slug) }
            return
        }
        var code: String?
        if url.host == "r", let first = parts.first {            // yumurta://r/КОД
            code = first
        } else if let idx = parts.firstIndex(of: "r"), idx + 1 < parts.count { // https://.../r/КОД
            code = parts[idx + 1]
        }
        if let code = code, !code.isEmpty {
            let value = code.uppercased()
            DispatchQueue.main.async { self.referralCode = value }
        }
    }
}
