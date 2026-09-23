import Foundation

// ВАЖНО: канон денег в новом клиенте — `Money` из DesignSystem.swift (Decimal).
// Старый Double-форматтер сохранён как `MoneyLegacy`, чтобы не было redeclaration
// с DesignSystem.Money. Новый UI использует Money.parse/Money.format (Decimal).
enum MoneyLegacy {
    static func rub(_ v: Double?) -> String {
        let d = v ?? 0
        let s = d.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(d)) : String(format: "%.0f", d)
        return s + " ₽"
    }
}

enum DateFmt {
    /// Сервер отдаёт «2026-09-10 14:03:00» БЕЗ смещения, своим временем
    /// (Europe/Moscow). Без явного пояса строка разбиралась в поясе телефона, и
    /// одно и то же время в карточке заказа и в чате по этому же заказу
    /// показывалось по-разному: чат пояс задаёт, а этот форматтер — нет.
    private static let iso: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "ru_RU")
        f.timeZone = TimeZone(identifier: "Europe/Moscow") ?? .current
        return f
    }()
    static func short(_ s: String?) -> String {
        guard let s = s, let date = iso.date(from: s) else { return s ?? "" }
        let out = DateFormatter(); out.locale = Locale(identifier: "ru_RU"); out.dateFormat = "d MMM, HH:mm"
        return out.string(from: date)
    }
    static func time(_ s: String?) -> String {
        guard let s = s, let date = iso.date(from: s) else { return "" }
        let out = DateFormatter(); out.dateFormat = "HH:mm"; return out.string(from: date)
    }
}

enum OrderStatus {
    /// Подпись состояния. `shopType` — shop | cafe | service: коды состояний
    /// одинаковые у всех, а слова разные. Кафе готовит, магазин собирает,
    /// салон работает; «Готовится» для записи в барбершоп читается как ошибка.
    /// Параметр со значением по умолчанию — старые вызовы продолжают работать.
    static func label(_ s: String?, shopType: String? = nil) -> String {
        switch s {
        case "new", "pending": return "Новый"
        case "accepted": return "Принят"
        case "preparing", "cooking":
            switch shopType {
            case "cafe":    return "Готовится"
            case "service": return "В работе"
            case "shop":    return "Собирается"
            default:        return "Готовится"
            }
        case "ready", "cooked":
            switch shopType {
            case "service": return "Выполнена"
            case "shop":    return "Собран"
            default:        return "Готов"
            }
        // Канон сервера — in_delivery (routes/api_v1.php, orderStatusTitles).
        // "delivering" оставляем для совместимости со старыми ответами; без
        // in_delivery экран показывал человеку сырой код статуса.
        case "in_delivery", "delivering": return "В пути"
        case "done", "delivered", "completed":
            return shopType == "service" ? "Завершена" : "Выполнен"
        case "cancelled", "canceled": return "Отменён"
        default: return s ?? "—"
        }
    }
}
