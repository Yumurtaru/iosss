import SwiftUI

//
//  OrgBooking.swift — запись на услуги (для организаций mode == "service").
//  1:1 с Android OrgBooking.kt (премиум-стиль YM*).
//
//  Поток:
//    GET  api/v1/shops/{slug}/services            -> ServicesResponse(.services: [ServiceItem])
//    выбор услуги -> GET api/v1/services/{id}/slots?date=YYYY-MM-DD -> [Slot]
//    выбор слота  -> подтверждение -> POST api/v1/appointments (AppointmentBody{slotId})
//                                     -> OrderCreateResult(.id) -> экран «Вы записаны»
//
//  Деньги — только Decimal через Money (никогда Double в UI).
//  Дата — "yyyy-MM-dd", сегодня + ближайшие 6 дней.
//  NULL-безопасность: списки ?? [], строки isEmpty.
//

// MARK: - Одна дата в ленте выбора

private struct DayOption: Identifiable, Equatable {
    let value: String    // "yyyy-MM-dd" — для API
    let weekday: String  // "Сегодня" / "Пн" …
    let dayNum: String   // "3"
    var id: String { value }
}

// MARK: - Секция записи (встраивается в sheet OrgView как обычный VStack)

struct OrgBookingSection: View {
    let slug: String
    let detail: ShopDetail?
    /// Гость нажал «Записаться» — родитель показывает вход.
    var onNeedAuth: () -> Void = {}

    @State private var services: [ServiceItem] = []
    @State private var loading = true
    @State private var error: String?

    @State private var days: [DayOption] = OrgBookingSection.nearestDays(7)
    @State private var selectedDate: String = ""
    @State private var selected: ServiceItem?

    @State private var slots: [Slot] = []
    @State private var loadingSlots = false
    @State private var slotsError: String?

    // Единый модальный поток: подтверждение → успех (один .sheet во избежание
    // конфликта двух одновременных .sheet на одной вью).
    private enum BookingSheet: Identifiable {
        case confirm(Slot)
        case success(Int)
        var id: String {
            switch self {
            case .confirm(let s): return "confirm-\(s.id)"
            case .success(let o): return "success-\(o)"
            }
        }
    }
    @State private var sheet: BookingSheet?
    @State private var confirming = false
    @State private var actionMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Запись на услугу")
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(YMColor.text)

            Group {
                if loading {
                    VStack(spacing: 10) {
                        ForEach(0..<3, id: \.self) { _ in
                            SkeletonBox(radius: 16).frame(height: 72)
                        }
                    }
                } else if let e = error, !e.isEmpty {
                    BookingNotice(text: e)
                } else if services.isEmpty {
                    BookingNotice(text: "Услуги появятся позже")
                } else {
                    VStack(spacing: 10) {
                        ForEach(services) { sv in
                            serviceBlock(sv)
                        }
                    }
                }
            }

            if let msg = actionMessage {
                Text(msg)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(YMColor.statusCancel)
                    .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { if selectedDate.isEmpty { selectedDate = days.first?.value ?? "" }; await loadServices() }
        .sheet(item: $sheet) { s in
            switch s {
            case .confirm(let slot): confirmSheet(slot: slot)
            case .success(let oid):
                SuccessBookingSheet(orderId: oid) { sheet = nil; actionMessage = nil }
            }
        }
    }

    // MARK: Блок услуги + раскрывающийся выбор даты/слотов

    private func serviceBlock(_ sv: ServiceItem) -> some View {
        let isSel = selected?.id == sv.id
        return VStack(spacing: 0) {
            ServiceRow(service: sv, selected: isSel, fee: clientFee(Money.dec(sv.price))) {
                Haptics.selection()
                withAnimation(.easeInOut(duration: 0.2)) {
                    selected = isSel ? nil : sv
                }
            }
            if isSel {
                VStack(alignment: .leading, spacing: 10) {
                    DaySelector(days: days, selected: selectedDate) { d in
                        Haptics.selection()
                        selectedDate = d
                    }
                    Text("Свободное время")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(YMColor.muted)
                    slotsView
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: selected?.id) { _ in Task { await loadSlots() } }
        .onChange(of: selectedDate) { _ in if isSel { Task { await loadSlots() } } }
    }

    @ViewBuilder
    private var slotsView: some View {
        if loadingSlots {
            HStack { Spacer(); ProgressView().tint(YMColor.accent); Spacer() }
                .padding(.vertical, 8)
        } else if let e = slotsError, !e.isEmpty {
            Text(e).font(.system(size: 14.5)).foregroundStyle(YMColor.muted)
        } else if slots.isEmpty {
            Text("На эту дату нет свободных слотов")
                .font(.system(size: 14.5)).foregroundStyle(YMColor.muted)
        } else {
            SlotGrid(slots: slots) { slot in
                if Session.shared.isLoggedIn { sheet = .confirm(slot) } else { onNeedAuth() }
            }
        }
    }

    // MARK: Подтверждение

    private func confirmSheet(slot: Slot) -> some View {
        let price = Money.dec(selected?.price)
        let fee = clientFee(price)
        let total = price + fee
        return ConfirmBookingSheet(
            dateLabel: fmtDateHuman(selectedDate),
            timeLabel: String((slot.timeStart ?? "").prefix(5)),
            serviceName: selected?.name ?? "",
            price: price, fee: fee, total: total,
            confirming: confirming,
            onConfirm: { book(slot: slot) },
            onDismiss: { if !confirming { sheet = nil } }
        )
    }

    // MARK: Сеть

    private func loadServices() async {
        loading = true; error = nil
        do {
            let r: ServicesResponse = try await API.shared.get("api/v1/shops/\(slug)/services")
            services = r.services ?? []
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func loadSlots() async {
        guard let sel = selected, !selectedDate.isEmpty else { return }
        loadingSlots = true; slotsError = nil; slots = []
        do {
            slots = try await API.shared.list("api/v1/services/\(sel.id)/slots", query: ["date": selectedDate])
        } catch is CancellationError {
        } catch {
            slotsError = error.localizedDescription
        }
        loadingSlots = false
    }

    private func book(slot: Slot) {
        confirming = true
        Task {
            do {
                let r: OrderCreateResult = try await API.shared.post(
                    "api/v1/appointments", body: AppointmentBody(slotId: slot.id))
                await MainActor.run {
                    confirming = false
                    slots.removeAll { $0.id == slot.id }
                    sheet = .success(r.id ?? 0)   // подтверждение → успех в том же .sheet
                    Haptics.success()
                }
            } catch {
                await MainActor.run {
                    confirming = false
                    sheet = nil
                    actionMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: Сервисный сбор клиента (Decimal, как считает сервер)

    private func clientFee(_ price: Decimal) -> Decimal {
        guard let d = detail else { return 0 }
        if (d.serviceFeePayer ?? "client") != "client" { return 0 }
        if (d.serviceFeeType ?? "percent") == "fixed" {
            return Money.dec(d.serviceFeeFixed)
        }
        let pct = Money.dec(d.serviceFeePercent)
        var raw = price * pct / 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, 2, .plain)
        return rounded
    }

    // MARK: Ближайшие дни

    fileprivate static func nearestDays(_ count: Int) -> [DayOption] {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "ru_RU")
        let api = DateFormatter(); api.calendar = cal; api.locale = Locale(identifier: "en_US_POSIX"); api.dateFormat = "yyyy-MM-dd"
        let weekdays = ["Вс", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб"] // weekday: 1 = Вс
        let today = Date()
        return (0..<count).compactMap { i in
            guard let day = cal.date(byAdding: .day, value: i, to: today) else { return nil }
            let comps = cal.dateComponents([.weekday, .day], from: day)
            let wd = (comps.weekday ?? 1) - 1
            return DayOption(
                value: api.string(from: day),
                weekday: i == 0 ? "Сегодня" : weekdays[max(0, min(6, wd))],
                dayNum: "\(comps.day ?? 0)"
            )
        }
    }
}

// MARK: - Строка услуги

private struct ServiceRow: View {
    let service: ServiceItem
    let selected: Bool
    let fee: Decimal
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(service.name ?? "—")
                            .font(.system(size: 15.5, weight: .bold))
                            .foregroundStyle(YMColor.text)
                            .lineLimit(2)
                        if let d = service.description, !d.isEmpty {
                            Text(d)
                                .font(.system(size: 12))
                                .foregroundStyle(YMColor.muted)
                                .lineLimit(2)
                        }
                        if let dm = service.durationMin, dm > 0 {
                            Text("🕑 \(dm) мин")
                                .font(.system(size: 12))
                                .foregroundStyle(YMColor.muted)
                        }
                    }
                    Spacer(minLength: 8)
                    Text(Money.format(Money.dec(service.price)))
                        .font(.system(size: 15.5, weight: .heavy))
                        .foregroundStyle(YMColor.text)
                }
                if selected && fee > 0 {
                    HStack {
                        Text("Сервисный сбор")
                            .font(.system(size: 12)).foregroundStyle(YMColor.muted)
                        Spacer()
                        Text(Money.format(fee))
                            .font(.system(size: 12)).foregroundStyle(YMColor.text)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? YMColor.surface2 : YMColor.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(selected ? YMColor.accent.opacity(0.6) : YMColor.hairline, lineWidth: 1))
        }
        .buttonStyle(CardPressStyle())
    }
}

// MARK: - Лента выбора даты

private struct DaySelector: View {
    let days: [DayOption]
    let selected: String
    var onSelect: (String) -> Void = { _ in }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(days) { d in
                    let active = d.value == selected
                    Button { onSelect(d.value) } label: {
                        VStack(spacing: 2) {
                            Text(d.weekday)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(active ? YMColor.onAccent : YMColor.muted)
                            Text(d.dayNum)
                                .font(.system(size: 16, weight: .heavy))
                                .foregroundStyle(active ? YMColor.onAccent : YMColor.text)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(active ? YMColor.accent : YMColor.surface,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(active ? YMColor.accent : YMColor.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Сетка слотов

private struct SlotGrid: View {
    let slots: [Slot]
    var onPick: (Slot) -> Void = { _ in }

    private let columns = [GridItem(.adaptive(minimum: 78), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(slots) { slot in
                Button { Haptics.light(); onPick(slot) } label: {
                    Text(String((slot.timeStart ?? "").prefix(5)))
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(YMColor.text)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(YMColor.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(YMColor.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Мягкая инфо-плашка

private struct BookingNotice: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 14.5))
            .foregroundStyle(YMColor.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22).padding(.horizontal, 16)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(YMColor.hairline, lineWidth: 1))
    }
}

// MARK: - Лист подтверждения записи

private struct ConfirmBookingSheet: View {
    let dateLabel: String
    let timeLabel: String
    let serviceName: String
    let price: Decimal
    let fee: Decimal
    let total: Decimal
    let confirming: Bool
    var onConfirm: () -> Void = {}
    var onDismiss: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Подтверждение записи")
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(YMColor.text)
            if !serviceName.isEmpty {
                Text(serviceName)
                    .font(.system(size: 15))
                    .foregroundStyle(YMColor.muted)
                    .padding(.top, 4)
            }

            HStack {
                Text("Дата и время")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(YMColor.muted)
                Spacer()
                Text("\(dateLabel) · \(timeLabel)")
                    .font(.system(size: 13, weight: .heavy)).foregroundStyle(YMColor.text)
            }
            .padding(14)
            .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.top, 12)

            priceRow("Стоимость", price, bold: false).padding(.top, 12)
            if fee > 0 { priceRow("Сервисный сбор", fee, bold: false) }
            priceRow("Итого", total, bold: true).padding(.top, 4)

            Button(action: onConfirm) {
                Text(confirming ? "Записываем…" : "Подтвердить запись")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(YMPrimaryButtonStyle())
            .disabled(confirming)
            .padding(.top, 18)

            Button("Отмена", action: onDismiss)
                .buttonStyle(YMSecondaryButtonStyle())
                .disabled(confirming)
                .padding(.top, 10)
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .presentationDetents([.medium])
    }

    private func priceRow(_ label: String, _ value: Decimal, bold: Bool) -> some View {
        HStack {
            Text(label)
                .font(.system(size: bold ? 17 : 13, weight: bold ? .heavy : .semibold))
                .foregroundStyle(bold ? YMColor.text : YMColor.muted)
            Spacer()
            Text(Money.format(value))
                .font(.system(size: bold ? 17 : 13, weight: bold ? .heavy : .bold))
                .foregroundStyle(YMColor.text)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Лист успеха

private struct SuccessBookingSheet: View {
    let orderId: Int
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(YMColor.statusDone)
                .padding(.bottom, 6)
            Text("Вы записаны!")
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(YMColor.text)
            if orderId > 0 {
                Text("Заказ №\(orderId)")
                    .font(.system(size: 15))
                    .foregroundStyle(YMColor.muted)
                    .padding(.top, 4)
            }
            Button("Готово", action: onClose)
                .buttonStyle(YMPrimaryButtonStyle())
                .padding(.top, 18)
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, 28)
        .frame(maxWidth: .infinity)
        .presentationDetents([.height(280)])
    }
}

// MARK: - Хелпер даты

/// "yyyy-MM-dd" -> "3 июля".
private func fmtDateHuman(_ date: String) -> String {
    let p = date.split(separator: "-").map(String.init)
    guard p.count == 3 else { return date }
    let months = ["января", "февраля", "марта", "апреля", "мая", "июня",
                  "июля", "августа", "сентября", "октября", "ноября", "декабря"]
    let m = min(max(Int(p[1]) ?? 1, 1), 12)
    guard let day = Int(p[2]) else { return date }
    return "\(day) \(months[m - 1])"
}
