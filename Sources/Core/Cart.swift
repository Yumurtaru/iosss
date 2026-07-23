import Foundation
import Combine

struct CartLine: Codable, Identifiable {
    let key: String
    let productId: Int
    let name: String
    let unitPrice: Double
    var qty: Double
    let modifierIds: [Int]
    let modsLabel: String
    let photo: String?
    var unit: String? = nil
    var qtyFractional: Bool? = nil
    var qtyPresets: String? = nil
    var id: String { key }

    var presets: [Double] {
        (qtyPresets ?? "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 0 }.sorted()
    }
    var isFractional: Bool {
        (qtyFractional ?? false) || presets.count >= 2 || ["кг", "г", "kg", "g", "л", "l", "мл", "ml"].contains((unit ?? "").trimmingCharacters(in: .whitespaces).lowercased())
    }
    var step: Double { presets.first ?? (isFractional ? 0.1 : 1.0) }
}

/// Количество с запятой и единицей: 0.3 → "0,3 кг".
func fmtQty(_ q: Double, _ unit: String? = nil) -> String {
    let n = (q * 1000).rounded() / 1000
    let s = (n == n.rounded() ? String(Int(n)) : String(n)).replacingOccurrences(of: ".", with: ",")
    if let u = unit, !u.isEmpty { return "\(s) \(u)" }
    return s
}

func snapCartQty(_ line: CartLine, _ q: Double) -> Double {
    func r3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
    if !line.isFractional { return max(1, q.rounded()) }
    let ps = line.presets
    if ps.count >= 2 { return max(ps.first ?? 0.001, r3(q)) }        // размеры суммируются → свободно
    if ps.count == 1 { let s = ps[0]; return max(s, (q / s).rounded() * s) }
    return max(0.001, r3(q))
}


final class Cart: ObservableObject {
    static let shared = Cart()
    @Published private(set) var lines: [CartLine] = []
    @Published private(set) var shopId: Int?
    @Published private(set) var shopName: String?
    @Published private(set) var shopSlug: String?

    var count: Int { lines.reduce(0) { $0 + ($1.qty < 1 ? 1 : Int($1.qty.rounded())) } }
    var total: Double { lines.reduce(0) { $0 + $1.unitPrice * $1.qty } }
    var isEmpty: Bool { lines.isEmpty }
    private var snapshotTask: Task<Void, Never>?

    private init() { load() }

    /// Заменить корзину набором позиций (для «Заказать снова»).
    func setLines(_ newLines: [CartLine], shopId: Int, shopName: String?, shopSlug: String?) {
        lines = newLines
        self.shopId = shopId; self.shopName = shopName; self.shopSlug = shopSlug
        save()
    }

    func add(product: ProductDetail, modifierIds: [Int], options: [ModifierOption], shopId: Int, shopName: String?, qty: Double = 1) {
        if self.shopId != nil && self.shopId != shopId { lines = [] } // корзина из одного заведения
        self.shopId = shopId; self.shopName = shopName; self.shopSlug = product.shopSlug
        let chosen = options.filter { modifierIds.contains($0.id) }
        let modPrice = chosen.reduce(0) { $0 + ($1.price ?? 0) }
        let key = "\(product.id)-\(modifierIds.sorted().map(String.init).joined(separator: ","))"
        if let idx = lines.firstIndex(where: { $0.key == key }) {
            lines[idx].qty = ((lines[idx].qty + qty) * 1000).rounded() / 1000   // суммируем
        } else {
            lines.append(CartLine(key: key, productId: product.id, name: product.name ?? "",
                unitPrice: (product.price ?? 0) + modPrice, qty: qty, modifierIds: modifierIds,
                modsLabel: chosen.compactMap { $0.name }.joined(separator: ", "),
                photo: product.photos?.first?.pathWebp,
                unit: product.unit, qtyFractional: (product.qtyFractional ?? 0) == 1, qtyPresets: product.qtyPresets))
        }
        Track.addToCart(id: product.id, name: product.name, price: product.price, qty: 1)
        save()
    }
    func inc(_ key: String) {
        if let i = lines.firstIndex(where: { $0.key == key }) { lines[i].qty = snapCartQty(lines[i], lines[i].qty + lines[i].step); save() }
    }
    func dec(_ key: String) {
        if let i = lines.firstIndex(where: { $0.key == key }) {
            let raw = lines[i].qty - lines[i].step
            if raw <= 0 { lines.remove(at: i) } else { lines[i].qty = snapCartQty(lines[i], raw) }
            if lines.isEmpty { shopId = nil; shopName = nil; shopSlug = nil }
            save()
        }
    }
    func clear() { lines = []; shopId = nil; shopName = nil; shopSlug = nil; save() }

    private func save() {
        if let d = try? JSONEncoder().encode(lines) { UserDefaults.standard.set(d, forKey: "cart_lines") }
        UserDefaults.standard.set(shopId ?? 0, forKey: "cart_shop")
        UserDefaults.standard.set(shopName, forKey: "cart_shop_name")
        UserDefaults.standard.set(shopSlug, forKey: "cart_shop_slug")
        syncSnapshot()
    }

    // Снимок корзины на сервер (для «брошенной корзины»). Дебаунс, только для залогиненных.
    private func syncSnapshot() {
        snapshotTask?.cancel()
        let body = CartSnapshotBody(shopId: shopId, shopSlug: shopSlug, shopName: shopName, itemsCount: count, subtotal: total)
        snapshotTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            guard Session.shared.isLoggedIn else { return }
            try? await API.shared.postVoid("api/v1/cart/snapshot", body: body)
        }
    }
    private func load() {
        if let d = UserDefaults.standard.data(forKey: "cart_lines"), let l = try? JSONDecoder().decode([CartLine].self, from: d) { lines = l }
        let s = UserDefaults.standard.integer(forKey: "cart_shop"); shopId = s == 0 ? nil : s
        shopName = UserDefaults.standard.string(forKey: "cart_shop_name")
        shopSlug = UserDefaults.standard.string(forKey: "cart_shop_slug")
    }
}

// Тело снимка корзины. Кодировщик API сам делает snake_case — CodingKeys не нужны.
struct CartSnapshotBody: Encodable {
    let shopId: Int?
    let shopSlug: String?
    let shopName: String?
    let itemsCount: Int
    let subtotal: Double
}

/// Расчёт сервисного сбора (как на сервере): берётся с клиента только при payer == "client".
enum Fees {
    static func service(subtotal: Double, shop: ShopDetail?) -> Double {
        guard let shop, (shop.serviceFeePayer ?? "") == "client" else { return 0 }
        if (shop.serviceFeeType ?? "percent") == "fixed" { return shop.serviceFeeFixed ?? 0 }
        let v = subtotal * (shop.serviceFeePercent ?? 0) / 100
        return (v * 100).rounded() / 100
    }
}
