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
    private static let iso: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "ru_RU"); return f
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
    static func label(_ s: String?) -> String {
        switch s {
        case "new", "pending": return "Новый"
        case "accepted": return "Принят"
        case "preparing", "cooking": return "Готовится"
        case "ready", "cooked": return "Готов"
        case "delivering": return "Доставляется"
        case "done", "delivered", "completed": return "Выполнен"
        case "cancelled", "canceled": return "Отменён"
        default: return s ?? "—"
        }
    }
}
