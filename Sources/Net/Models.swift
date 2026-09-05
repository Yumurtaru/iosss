import Foundation

// Конверт ответа v1: {success, data, meta, error}
struct APIEnvelope<T: Decodable>: Decodable { let success: Bool?; let data: T?; let error: APIErr? }

// error приходит по-разному: строкой ("текст") — core/Response.php (Response::error),
// ИЛИ объектом {message} — часть эндпоинтов. Толерантно принимаем обе формы,
// иначе понятный текст (напр. «Минимальная сумма заказа…») терялся и показывалось «Ошибка 422».
struct APIErr: Decodable {
    let message: String?
    init(message: String?) { self.message = message }
    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self.message = s
        } else if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            self.message = try? c.decode(String.self, forKey: .message)
        } else {
            self.message = nil
        }
    }
    private enum CodingKeys: String, CodingKey { case message }
}

// Список: массив или {items:[...], has_more}
struct ListPayload<T: Decodable>: Decodable {
    let items: [T]; let hasMore: Bool
    init(from decoder: Decoder) throws {
        if let arr = try? [T](from: decoder) { items = arr; hasMore = false; return }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = (try? c.decode([T].self, forKey: .items)) ?? []
        hasMore = (try? c.decode(Bool.self, forKey: .hasMore)) ?? false
    }
    enum CodingKeys: String, CodingKey { case items, hasMore }
}

struct City: Codable, Identifiable, Hashable { let id: Int; let name: String?; let region: String? }
struct Banner: Codable, Identifiable {
    let id: Int; let imageWebp: String?; let title: String?; let link: String?
    var image: String? { imageWebp }
}
struct Category: Codable, Identifiable, Hashable { let id: Int; let name: String?; let image: String? }

struct Shop: Codable, Identifiable, Hashable {
    let id: Int; let slug: String?; let name: String?; let logo: String?; let cover: String?; let banner: String?
    @LenientDouble var rating: Double?; let category: String?; let deliveryTime: String?; let isOpen: Bool?; let shopMode: String?; let address: String?
    @LenientInt var avgCookTime: Int?; @LenientInt var reviewsCount: Int?
    // Буст-продвижение (Фаза 3.1, аддитивно): 1 = показать бейдж «Реклама».
    @LenientInt var isPromoted: Int?
}
// Категория организации (магазин/услуга). Ключи snake_case декодируются авто-конвертером — CodingKeys НЕ добавляем.
struct OrgCategory: Codable, Identifiable, Hashable {
    let id: Int; let slug: String?; let name: String?; let icon: String?
    @LenientInt var count: Int?
    @LenientBool var requiresLicense: Bool?
}

// Заявка на регистрацию организации из приложения («стать продавцом»).
// Тело кодируется .convertToSnakeCase: orgName→org_name, fullName→full_name, cityId→city_id.
struct OrgApplyBody: Encodable {
    let orgName: String
    let fullName: String
    let phone: String
    let type: String            // store | restaurant | service (канон API)
    let cityId: Int?
}
struct OrgApplyResult: Decodable {
    @LenientInt var registrationId: Int?
    let status: String?          // "pending"
}
struct ShopDetail: Codable, Identifiable {
    let id: Int; let slug: String?; let name: String?; let logo: String?; let cover: String?; let banner: String?
    // Режим организации: "service" = запись на услуги, иначе магазин/меню (аддитивно, как на Android).
    let mode: String?
    // Кол-во оценок для сводки отзывов (аддитивно; сервер отдаёт reviews_count).
    @LenientInt var reviewsCount: Int?
    let description: String?; let address: String?; let phone: String?; @LenientDouble var rating: Double?
    @LenientDouble var lat: Double?; @LenientDouble var lng: Double?; let hours: [ShopHour]?
    @LenientDouble var deliveryFee: Double?; @LenientDouble var minOrder: Double?; let deliveryTime: String?; let categories: [Category]?
    let deliveryZones: [DeliveryZone]?
    @LenientDouble var serviceFeePercent: Double?; let serviceFeePayer: String?; let serviceFeeType: String?; @LenientDouble var serviceFeeFixed: Double?
}
/// Зона доставки заведения. Сервер отдаёт массив `delivery_zones` в карточке магазина.
struct DeliveryZone: Codable, Identifiable, Hashable {
    var id: String { name ?? "—" }
    let name: String?
    @LenientDouble var deliveryPrice: Double?
    @LenientDouble var minOrder: Double?
    @LenientDouble var freeFrom: Double?
    @LenientInt var deliveryTimeMin: Int?
    @LenientInt var deliveryTimeMax: Int?
}

// Серверный расчёт доставки по адресу (POST /api/v1/delivery/quote).
// ВАЖНО: API-декодер использует .convertFromSnakeCase, поэтому НЕ задаём явные
// CodingKeys (иначе двойная конвертация: delivery_price → deliveryPrice не находит ключ
// "delivery_price", и поля молча становятся nil — доставка показывалась «бесплатно»).
// Имена свойств в camelCase автоматически маппятся на snake_case сервера.
struct DeliveryQuote: Codable {
    let available: Bool
    let zone: String?
    @LenientDouble var deliveryPrice: Double?
    @LenientDouble var minOrder: Double?
    let belowMin: Bool?
    @LenientDouble var freeFrom: Double?
    let freeApplies: Bool?
    @LenientInt var timeMin: Int?
    @LenientInt var timeMax: Int?
    let reason: String?
}

// Подсказка адреса с сервера (GET /api/address/suggest?q=…) — прокси Dadata, токен на сервере.
struct AddrSuggest: Codable, Identifiable {
    let value: String?
    let city: String?
    let street: String?
    let house: String?
    @LenientDouble var lat: Double?
    @LenientDouble var lng: Double?
    var id: String { value ?? "" }
}
struct ShopHour: Codable, Hashable, Identifiable {
    var id: Int { dayOfWeek ?? 0 }
    @LenientInt var dayOfWeek: Int?; let openTime: String?; let closeTime: String?; @LenientInt var isClosed: Int?
}
struct Product: Codable, Identifiable, Hashable {
    let id: Int; let name: String?; @LenientDouble var price: Double?; @LenientDouble var oldPrice: Double?
    let description: String?; let photo: String?; @LenientInt var categoryId: Int?; let hasMods: Bool?; @LenientInt var shopId: Int?
    let unit: String?
    @LenientBool var isHalal: Bool?
}
struct ComboItem: Codable {
    let name: String?; @LenientInt var qty: Int?; @LenientDouble var price: Double?; let photo: String?
}
struct ProductDetail: Codable, Identifiable {
    let id: Int; let name: String?; @LenientDouble var price: Double?; @LenientDouble var oldPrice: Double?
    let description: String?; let photos: [MediaPhoto]?; let modifierGroups: [ModifierGroup]?; @LenientInt var shopId: Int?; let shopName: String?; let shopSlug: String?
    let comboItems: [ComboItem]?
    let unit: String?; @LenientInt var qtyFractional: Int?; @LenientDouble var qtyStep: Double?; let qtyPresets: String?
    @LenientBool var isHalal: Bool?
}
struct ModifierGroup: Codable, Identifiable {
    let id: Int; let name: String?; let type: String?; @LenientBool var isRequired: Bool?
    @LenientInt var minQty: Int?; @LenientInt var maxQty: Int?; let options: [ModifierOption]?
}
struct ModifierOption: Codable, Identifiable, Hashable { let id: Int; let name: String?; @LenientDouble var price: Double?; let photoWebp: String? }
struct MediaPhoto: Codable, Hashable { let pathWebp: String? }

struct Profile: Codable { @LenientInt var id: Int?; let name: String?; let phone: String?; let email: String?; @LenientDouble var bonusBalance: Double? }
struct Address: Codable, Identifiable {
    let id: Int; let label: String?; let city: String?; let street: String?; let house: String?
    let apartment: String?; let entrance: String?; let floor: String?; let intercom: String?
    @LenientDouble var lat: Double?; @LenientDouble var lng: Double?; @LenientInt var isDefault: Int?
    var display: String {
        [city, street, house.map { "д. \($0)" }, apartment.map { "кв. \($0)" }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
    var isDefaultBool: Bool { (isDefault ?? 0) > 0 }
}

struct Order: Codable, Identifiable {
    let id: Int; @LenientInt var dailyNumber: Int?; let status: String?; @LenientDouble var total: Double?
    let createdAt: String?; let shopName: String?; let shopLogo: String?
    /// Запись на услугу. На сервере запись хранится как заказ, поэтому она приходила
    /// и сюда, и должна была прийти в «Мои записи». Признак is_appointment позволяет
    /// показать её ровно в одном разделе — в «Моих записях» (см. OrdersViewModel.load).
    /// Поле аддитивное: у старого ответа без него значение nil → заказ обычный.
    @LenientBool var isAppointment: Bool?
}

/// Запись клиента на услугу — GET api/v1/appointments (экран «Мои записи»).
///
/// Раньше этого эндпоинта не существовало (был только POST на создание), поэтому
/// BookingsView стоял пустой заглушкой. Форма ответа повторяет продавцовый
/// GET /api/seller/bookings: те же date / time_start / time_end / service / master / status.
///
/// `id` — это id ОКНА (service_slots.id), а `orderId` — id заказа, которым запись
/// хранится на сервере: он нужен для отмены (POST api/v1/orders/{id}/cancel).
struct Appointment: Codable, Identifiable {
    let id: Int
    @LenientInt var orderId: Int?
    let date: String?           // "2026-09-06"
    let timeStart: String?      // "15:00:00"
    let timeEnd: String?
    @LenientInt var serviceId: Int?
    let service: String?
    @LenientDouble var price: Double?
    @LenientInt var durationMin: Int?
    let master: String?
    let masterPhoto: String?
    let status: String?         // new | accepted | done | cancelled
    @LenientDouble var total: Double?
    @LenientInt var shopId: Int?
    let shop: String?
    let shopSlug: String?
    let shopLogo: String?
    let shopAddress: String?
    /// Адрес визита для выездной услуги («сантехник на дом»). У услуги
    /// в заведении сервер отдаёт пустую строку — форма ответа одинаковая.
    let address: String?
    let shopPhone: String?
    @LenientDouble var shopLat: Double?
    @LenientDouble var shopLng: Double?
    /// Считает сервер — чтобы табы «Предстоящие / Прошедшие» одинаково делились
    /// на всех платформах и не зависели от часового пояса телефона.
    @LenientBool var isPast: Bool?
}
struct OrderItem: Codable, Identifiable {
    var id: Int { (productId ?? 0) &* 100000 &+ Int((qty ?? 0).rounded()) }
    @LenientInt var productId: Int?; let name: String?; @LenientDouble var qty: Double?; @LenientDouble var price: Double?
    let unit: String?
}
struct OrderDetail: Codable, Identifiable {
    let id: Int; @LenientInt var dailyNumber: Int?; let status: String?; @LenientDouble var total: Double?
    let deliveryType: String?; let paymentType: String?; let address: String?
    let createdAt: String?; let shopName: String?; let items: [OrderItem]?
    @LenientDouble var subtotal: Double?; @LenientDouble var deliveryPrice: Double?; @LenientDouble var serviceFee: Double?
    @LenientDouble var tip: Double?; @LenientDouble var discount: Double?; let promoCode: String?
    // Баллы по заказу (points_spent / points_earned маппятся через .convertFromSnakeCase).
    @LenientDouble var pointsSpent: Double?; @LenientDouble var pointsEarned: Double?
}
struct TrackData: Codable {
    let status: String?; @LenientDouble var courierLat: Double?; @LenientDouble var courierLng: Double?
    let courierName: String?; let courierPhone: String?; @LenientInt var etaMinutes: Int?
}
struct ChatMessage: Codable, Identifiable {
    @LenientInt var id: Int?; let message: String?; let sender: String?; let createdAt: String?
    @LenientBool var mine: Bool?        // сервер отдаёт mine — источник правды «моё сообщение»
    let attachment: String?             // относительный webp-путь фото (nil = текст)
    @LenientBool var read: Bool?        // прочитано контрагентом (для моих сообщений → ✓✓)
    let senderName: String?
    var stableId: String { "\(id ?? 0)-\(createdAt ?? "")" }
    // Локальные (ещё не отправленные / ошибка) сообщения — для оптимистичного UI.
    var localState: String? = nil       // nil=с сервера, "sending", "failed"
    var localImage: Data? = nil         // локальное фото до загрузки (превью)
}

// Диалог в списке чатов: GET /api/v1/chats.
struct ChatDialog: Codable, Identifiable {
    @LenientInt var orderId: Int?
    @LenientInt var dailyNumber: Int?
    let status: String?
    let shopName: String?
    let shopLogo: String?
    let lastMessage: String?
    let lastAttachment: String?
    let lastAt: String?
    @LenientInt var unreadCount: Int?
    var id: Int { orderId ?? 0 }
}
struct BonusInfo: Codable { @LenientDouble var balance: Double?; let history: [BonusRow]? }
struct BonusRow: Codable, Identifiable { @LenientInt var id: Int?; @LenientDouble var amount: Double?; let reason: String?; let createdAt: String?
    var stableId: Int { id ?? 0 } }
// Баланс баллов по магазину (ответ /profile/bonuses — массив).
struct BonusShopBalance: Codable { @LenientInt var shopId: Int?; let shop: String?; @LenientDouble var balance: Double? }
// Операция по баллам (ответ /profile/bonuses/history).
struct BonusTx: Codable { @LenientInt var id: Int?; let shop: String?; let type: String?; @LenientDouble var amount: Double?; let createdAt: String?
    var stableId: String { "\(id ?? 0)-\(createdAt ?? "")" } }
struct AppNotification: Codable, Identifiable { let id: Int; let type: String?; let title: String?; let body: String?; @LenientInt var isRead: Int?; let createdAt: String?
    var read: Bool { (isRead ?? 0) > 0 } }
struct OrderCreateResult: Codable {
    @LenientInt var id: Int?; @LenientInt var dailyNumber: Int?
    // Сервер возвращает id созданного заказа под ключом order_id (→ orderId после
    // convertFromSnakeCase). Раньше читали только id → nil → трекинг открывал id=0
    // («заказ не найден»). Теперь резолвим оба.
    @LenientInt var orderId: Int?
    /// Итоговый id заказа: сначала order_id, затем id.
    var resolvedId: Int? { orderId ?? id }
    // Движок акций: применённые акции/подарки/баллы (аддитивно, optional).
    var promotions: [AppliedPromo]? = nil
    var gifts: [PromoGift]? = nil
    var pointsSpent: Double? = nil
    var pointsEarned: Double? = nil
}
// Ответ создания онлайн-платежа (YooKassa). Декодер сам делает snake_case → CodingKeys не нужны.
struct PayOnlineResp: Codable { let confirmationUrl: String?; let paymentId: String? }

// ---- Возвраты ----
struct ReturnItem: Codable, Identifiable {
    let id: Int; @LenientInt var orderId: Int?; let type: String?; let reasonCode: String?
    let status: String?; @LenientDouble var refundAmount: Double?; let createdAt: String?; let shop: String?
}
struct ReturnEligibility: Codable { let eligible: Bool?; @LenientInt var windowHours: Int?; let reason: String? }

// ---- Вакансии ----
struct Job: Codable, Identifiable {
    let id: Int; let title: String?; let category: String?
    @LenientDouble var salaryFrom: Double?; @LenientDouble var salaryTo: Double?; let employmentType: String?
    let experience: String?; let schedule: String?; let shop: String?
}
struct JobDetail: Codable, Identifiable {
    let id: Int; let title: String?; let category: String?
    @LenientDouble var salaryFrom: Double?; @LenientDouble var salaryTo: Double?; let description: String?; let requirements: String?
    let schedule: String?; let employmentType: String?; let experience: String?
    let shop: String?; let shopAddress: String?
}

// ---- Услуги / запись ----
struct Master: Codable, Identifiable { let id: Int; let name: String?; let photoWebp: String?; let bio: String?; @LenientDouble var rating: Double? }
struct ServiceItem: Codable, Identifiable {
    let id: Int; @LenientInt var masterId: Int?; let name: String?; let description: String?
    @LenientInt var durationMin: Int?; @LenientDouble var price: Double?
    /// Где оказывается услуга: "at_business" — клиент приходит сам,
    /// "at_client" — мастер выезжает по адресу клиента (сантехник, уборка).
    /// Поле аддитивное: у старого сервера его нет → nil → считаем «в заведении».
    let locationType: String?
    /// Стоимость выезда мастера, прибавляется к цене услуги.
    @LenientDouble var travelFee: Double?

    var isAtClient: Bool { (locationType ?? "at_business") == "at_client" }
}
struct ServicesResponse: Codable { let masters: [Master]?; let services: [ServiceItem]? }
struct CatalogItem: Codable, Hashable {
    let id: Int; let name: String?; @LenientDouble var price: Double?
    let type: String?; let shopName: String?; let shopSlug: String?; let photo: String?; let category: String?
    var uid: String { "\(type ?? "p")-\(id)" }
}

// Личные рекомендации (Фаза 1.5): GET /api/v1/recommendations.
// popular — товары по истории заказов (та же форма, что CatalogItem),
// ordered_again — магазины, где пользователь уже заказывал.
struct RecommendationsResp: Codable {
    let orderedAgain: [Shop]?
    let popular: [CatalogItem]?
}
struct Slot: Codable, Identifiable { let id: Int; let timeStart: String?; let timeEnd: String? }

// ---- Подарочные карты ----
struct GiftCard: Codable { let code: String?; @LenientDouble var balance: Double?; let status: String?; let expiresAt: String? }

// ---- Заявки / отклики ----
struct Application: Codable, Identifiable { let id: Int; let status: String?; let title: String?; let shop: String?; let createdAt: String? }

// ---- Отзыв (чтение) ----
struct Review: Codable, Identifiable {
    var id: String { "\(author ?? "")-\(createdAt ?? "")" }
    @LenientInt var ratingOverall: Int?; let text: String?; let author: String?; @LenientInt var isVerified: Int?; let createdAt: String?
    let photos: [String]?
    // Ответ продавца (Фаза 2.4, аддитивно): nil = ответа нет.
    let reply: String?; let replyAt: String?
}

// ---- Тела запросов (camelCase -> snake_case автоматически) ----
struct NotifReadBody: Encodable { let ids: [Int] }
struct ReturnCreateBody: Encodable { let orderId: Int; let type: String; let reasonCode: String; let reasonText: String? }
/// Адрес визита для выездной услуги. Форма 1:1 с тем, что принимает сервер
/// (routes/api_v1.php → normalizeVisitAddress) и что уже пишет оформление
/// заказа: тогда адрес виден везде, где он показывается сейчас.
struct VisitAddress: Encodable {
    var value: String = ""        // город/населённый пункт
    var street: String = ""
    var house: String = ""
    var apartment: String = ""
    var entrance: String = ""
    var floor: String = ""
    var comment: String = ""
    var lat: Double?
    var lng: Double?

    /// Сервер отклонит запись без улицы и дома (422) — проверяем это заранее,
    /// чтобы не терять выбранное окно.
    var isComplete: Bool {
        !street.trimmingCharacters(in: .whitespaces).isEmpty &&
        !house.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

struct AppointmentBody: Encodable {
    let slotId: Int
    /// Только для выездной услуги; у услуги в заведении не отправляется.
    var address: VisitAddress? = nil
}
struct SocialBody: Encodable { let provider: String; let code: String }
struct NpsBody: Encodable { let score: Int; let comment: String? }
struct ReferralInfo: Decodable {
    let code: String?; @LenientInt var invited: Int?; @LenientInt var reward: Int?
}
struct LoyaltyLevel: Decodable, Identifiable {
    let key: String; let name: String; let icon: String
    @LenientInt var min: Int?; @LenientInt var cashback: Int?
    var id: String { key }
}
struct LoyaltyInfo: Decodable {
    let level: LoyaltyLevel?; let next: LoyaltyLevel?
    @LenientInt var doneOrders: Int?; @LenientInt var toNext: Int?
    @LenientDouble var bonusBalance: Double?
    let levels: [LoyaltyLevel]?
}
struct ReorderData: Decodable {
    @LenientInt var shopId: Int?; let shopName: String?; let shopSlug: String?
    let items: [ReorderItem]?
}
struct ReorderItem: Decodable {
    @LenientInt var productId: Int?; @LenientDouble var qty: Double?; let name: String?; @LenientDouble var price: Double?; let photo: String?
}
struct PromoCheckBody: Encodable {
    let code: String; let subtotal: Double; let shopId: Int?
    enum CodingKeys: String, CodingKey { case code, subtotal, shopId = "shop_id" }
}
