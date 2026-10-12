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
        // en_US_POSIX: разбор фиксированного формата не зависит от настройки
        // «24-часовой формат» на телефоне (Apple QA1480).
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Moscow") ?? .current
        return f
    }()
    static func short(_ s: String?) -> String {
        // Дата без времени («2026-11-09») раньше показывалась как есть, латиницей
        // ISO; теперь — «09.11.2026».
        guard let s = s, let date = iso.date(from: s) else { return day(s) ?? s ?? "" }
        return shortOut.string(from: date)
    }
    /// «2026-11-09» (или начало «2026-11-09 14:03:00») → «09.11.2026».
    /// Только дата, без пересчёта поясов. Пустое и неожиданное → nil.
    static func day(_ s: String?) -> String? {
        guard let s, s.count >= 10 else { return nil }
        let p = s.prefix(10).split(separator: "-")
        guard p.count == 3, p[0].count == 4, p[1].count == 2, p[2].count == 2,
              p.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return nil }
        return "\(p[2]).\(p[1]).\(p[0])"
    }
    /// Для списков (последнее сообщение): сегодня — «14:05», вчера — «вчера»,
    /// раньше — «9 окт.». Одно время «14:05» у переписки месячной давности
    /// читалось как сегодняшнее.
    static func listTime(_ s: String?) -> String {
        guard let s = s, let date = iso.date(from: s) else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return timeOut.string(from: date) }
        if cal.isDateInYesterday(date) { return "вчера" }
        return dayOut.string(from: date)
    }
    private static let dayOut: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMM"
        f.timeZone = .autoupdatingCurrent; return f
    }()
    static func time(_ s: String?) -> String {
        guard let s = s, let date = iso.date(from: s) else { return "" }
        return timeOut.string(from: date)
    }
    // Один раз на приложение (вызываются из строк списков при каждой перерисовке).
    // Пояс — текущий телефона, как и раньше у форматтера по умолчанию.
    private static let shortOut: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d MMM, HH:mm"
        f.timeZone = .autoupdatingCurrent; return f
    }()
    private static let timeOut: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"
        f.timeZone = .autoupdatingCurrent; return f
    }()
}

enum OrderStatus {
    /// Подпись состояния. `shopType` — shop | cafe | service: коды состояний
    /// одинаковые у всех, а слова разные. Кафе готовит, магазин собирает,
    /// салон работает; «Готовится» для записи в барбершоп читается как ошибка.
    /// Параметр со значением по умолчанию — старые вызовы продолжают работать.
    /// `title` — подпись сервера (status_title): нужна для кодов, которых нет в
    /// словаре ниже — раньше человек видел их латиницей.
    static func label(_ s: String?, shopType: String? = nil, title: String? = nil) -> String {
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
        default:
            if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
            return s ?? "—"
        }
    }
}

/// Непустые строки через разделитель: `joinedNonEmpty([a, b], separator: " · ")`.
/// Отдельная функция вместо цепочки `[a, b].compactMap { $0 }.filter { … }`:
/// на Xcode 26 такие цепочки упирались в лимит проверки типов и роняли сборку
/// («unable to type-check this expression in reasonable time», сборка 74).
func joinedNonEmpty(_ parts: [String?], separator: String) -> String {
    var out: [String] = []
    for p in parts {
        guard let s = p, !s.isEmpty else { continue }
        out.append(s)
    }
    return out.joined(separator: separator)
}
