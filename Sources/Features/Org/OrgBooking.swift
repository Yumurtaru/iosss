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
    /// Организация услуг (mode == "service") — у неё это основной раздел.
    /// У ресторана или магазина услуги идут дополнительным блоком: меняется
    /// заголовок, а при пустом списке блок не рисуется вовсе (hideWhenEmpty).
    var serviceOrg: Bool = true
    var hideWhenEmpty: Bool = false

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
    /// Адрес визита — только для выездной услуги (сантехник, уборка на дом).
    /// Заполняется в окне подтверждения: у записи, в отличие от доставки,
    /// другого места спросить адрес нет.
    @State private var visitAddress = VisitAddress()
    /// Сохранённые адреса клиента — чтобы не набирать заново то, что уже есть
    /// в профиле. Грузим только если среди услуг есть выездные.
    @State private var savedAddresses: [Address] = []
    @State private var actionMessage: String?
    /// Человек и часов в брони. Сбрасываются при смене услуги: у каждой свои
    /// пределы, и «3 человека» от игрового зала на массаже неуместны.
    @State private var guests = 1
    @State private var hours = 1
    /// Данные успешной брони — экран успеха печатает их как есть, без расчётов.
    @State private var lastBooking: AppointmentResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // У ресторана или магазина это не «запись к мастеру», а бронь
            // игрового зала или кинозала — заголовок должен это отражать.
            Text(serviceOrg ? "Запись на услугу" : "Услуги и бронирование")
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
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(services.enumerated()), id: \.element.id) { idx, sv in
                            // Подзаголовок группы («Игровой зал», «Кинозал»):
                            // сервер уже отдаёт услуги в порядке групп.
                            if let g = sv.groupName, !g.isEmpty,
                               idx == 0 || services[idx - 1].groupName != g {
                                Text(g)
                                    .font(.system(size: 13, weight: .heavy))
                                    .foregroundStyle(YMColor.muted)
                                    .padding(.top, idx == 0 ? 0 : 6)
                            }
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
        // Пустой дополнительный блок не занимает места и не пишет «услуги
        // появятся позже» на витрине кафе, у которого их просто нет.
        .opacity(hideWhenEmpty && !loading && services.isEmpty ? 0 : 1)
        .frame(height: hideWhenEmpty && !loading && services.isEmpty ? 0 : nil)
        .clipped()
        .task { if selectedDate.isEmpty { selectedDate = days.first?.value ?? "" }; await loadServices() }
        .sheet(item: $sheet) { s in
            switch s {
            case .confirm(let slot): confirmSheet(slot: slot)
            case .success(let oid):
                SuccessBookingSheet(orderId: oid, info: lastBooking) {
                    sheet = nil; actionMessage = nil; lastBooking = nil
                }
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
                    // Сколько человек и на сколько часов. Показываем только там,
                    // где это что-то значит: у обычной услуги блока нет.
                    if sv.needsGuests {
                        CountStepper(
                            label: "Человек", value: $guests,
                            min: sv.guestsMin, max: sv.guestsMax,
                            hint: "Одновременно до \(sv.capacityValue)"
                        )
                    }
                    if sv.needsHours {
                        CountStepper(
                            label: "Часов подряд", value: $hours,
                            min: 1, max: sv.maxSlotsValue,
                            hint: "По \(sv.slotMinutes) мин"
                        )
                    }
                    if sv.needsGuests || sv.needsHours {
                        HStack {
                            Text("Стоимость брони")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(YMColor.muted)
                            Spacer()
                            Text(Money.format(sv.quote(guests: guests, slots: hours)))
                                .font(.system(size: 15, weight: .heavy))
                                .foregroundStyle(YMColor.text)
                        }
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
        .onChange(of: selected?.id) { _ in
            // Пределы у новой услуги свои — сбрасываем выбор.
            guests = selected?.guestsMin ?? 1
            hours = 1
            Task { await loadSlots() }
        }
        .onChange(of: selectedDate) { _ in if isSel { Task { await loadSlots() } } }
    }

    /// Окна, с которых можно начать бронь при текущем выборе человек/часов.
    private var startableSlots: [Slot] {
        Self.bookableStarts(slots, guests: guests, hours: hours)
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
            // Начать бронь можно только с окна, за которым идёт нужное число
            // окон подряд и в каждом хватает мест. Сервер проверит это ещё раз
            // под блокировкой — здесь мы просто не показываем занятое.
            if startableSlots.isEmpty {
                Text("На эту дату нет подходящего времени — попробуйте меньше часов или человек")
                    .font(.system(size: 14.5)).foregroundStyle(YMColor.muted)
            } else {
                SlotGrid(slots: startableSlots, showFree: (selected?.capacityValue ?? 1) > 1) { slot in
                    if Session.shared.isLoggedIn { sheet = .confirm(slot) } else { onNeedAuth() }
                }
            }
        }
    }

    // MARK: Подтверждение

    private func confirmSheet(slot: Slot) -> some View {
        let atClient = selected?.isAtClient ?? false
        // Цена брони, а не цена услуги: у игрового зала это 150 ₽ × человек × часы.
        let price = selected?.quote(guests: guests, slots: hours) ?? 0
        let travel = atClient ? Money.dec(selected?.travelFee) : 0
        // Сервисный сбор считается от полной суммы, включая выезд, — ровно так
        // же, как на сервере. Иначе итог на экране разойдётся с чеком.
        let fee = clientFee(price + travel)
        let total = price + travel + fee
        return ConfirmBookingSheet(
            dateLabel: fmtDateHuman(selectedDate),
            // Интервал, а не одно время: бронь на 2 часа — это 19:00–21:00.
            timeLabel: Self.slotRangeLabel(slot, slotMinutes: selected?.slotMinutes ?? 0, hours: hours),
            serviceName: selected?.name ?? "",
            composition: Self.bookingComposition(selected, guests: guests, hours: hours),
            price: price, travel: travel, fee: fee, total: total,
            atClient: atClient,
            address: $visitAddress,
            saved: savedAddresses,
            onPickSaved: { applyAddress($0) },
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
        if services.contains(where: { $0.isAtClient }) { await loadAddresses() }
    }

    /// Адреса из профиля: подставляем адрес по умолчанию в форму выезда.
    /// Ошибку глотаем — адрес всегда можно ввести руками.
    private func loadAddresses() async {
        // Город известен всегда (выбран в приложении) — он идёт в value.
        if visitAddress.value.isEmpty { visitAddress.value = Session.shared.cityName ?? "" }
        guard Session.shared.isLoggedIn else { return }
        let list: [Address] = (try? await API.shared.list("api/v1/profile/addresses")) ?? []
        savedAddresses = list
        if visitAddress.isComplete { return }
        if let a = list.first(where: { $0.isDefaultBool }) ?? list.first { applyAddress(a) }
    }

    private func applyAddress(_ a: Address) {
        visitAddress.street    = a.street ?? ""
        visitAddress.house     = a.house ?? ""
        visitAddress.apartment = a.apartment ?? ""
        visitAddress.entrance  = a.entrance ?? ""
        visitAddress.floor     = a.floor ?? ""
        // value — ТОЛЬКО город: сервер склеивает адрес как «value, улица, д. N».
        // Если положить сюда a.display, город и улица задвоятся в «Мои записи».
        visitAddress.value     = a.city ?? Session.shared.cityName ?? ""
        visitAddress.lat       = a.lat
        visitAddress.lng       = a.lng
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
                let atClient = selected?.isAtClient ?? false
                let sel = selected
                let r: AppointmentResult = try await API.shared.post(
                    "api/v1/appointments",
                    body: AppointmentBody(
                        slotId: slot.id,
                        address: atClient ? visitAddress : nil,
                        // Отправляем только то, что клиент реально выбирал: у
                        // обычной услуги тело запроса остаётся прежним.
                        guests: (sel?.needsGuests ?? false) ? guests : nil,
                        slots: (sel?.needsHours ?? false) ? hours : nil))
                let taken = guests
                await MainActor.run {
                    confirming = false
                    // Окно убираем из списка только если мест больше не осталось:
                    // в игровом зале после брони на 3 человека остаётся ещё 5.
                    if slot.capacityValue > 1, slot.freeValue - taken > 0 {
                        slots = slots.map { x in
                            guard x.id == slot.id else { return x }
                            var y = x
                            y.free = x.freeValue - taken
                            y.booked = (x.booked ?? 0) + taken
                            return y
                        }
                    } else {
                        slots.removeAll { $0.id == slot.id }
                    }
                    lastBooking = r
                    sheet = .success(r.orderId ?? 0)   // подтверждение → успех в том же .sheet
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
        // «Сегодня» считаем по времени ПЛОЩАДКИ, а не телефона: свободные окна
        // сервер отсекает своим `date()`, и у покупателя восточнее/западнее
        // Москвы чип «Сегодня» указывал на другой день — сегодняшние окна он не
        // видел вовсе, а на «Сегодня» приходили окна следующих суток.
        cal.timeZone = TimeZone(identifier: "Europe/Moscow") ?? .current
        let api = DateFormatter(); api.calendar = cal; api.timeZone = cal.timeZone
        api.locale = Locale(identifier: "en_US_POSIX"); api.dateFormat = "yyyy-MM-dd"
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

    // MARK: Отбор окон и подписи брони (1:1 с Android OrgBooking.kt)

    /// Окна, с которых можно НАЧАТЬ бронь: нужно `hours` окон подряд (следующее
    /// начинается ровно там, где кончилось предыдущее) и в каждом хватает мест.
    ///
    /// Тот же отбор делает сервер под блокировкой (serviceSlotChain +
    /// serviceSlotsHaveRoom) — здесь он нужен, чтобы не предлагать занятое время.
    fileprivate static func bookableStarts(_ slots: [Slot], guests: Int, hours: Int) -> [Slot] {
        if hours <= 1 && guests <= 1 { return slots.filter { $0.freeValue >= 1 } }
        var out: [Slot] = []
        for i in slots.indices {
            var ok = true
            for k in 0..<hours {
                let idx = i + k
                guard idx < slots.count else { ok = false; break }
                if slots[idx].freeValue < guests { ok = false; break }
                if k > 0, slots[idx].timeStart != slots[idx - 1].timeEnd { ok = false; break }
            }
            if ok { out.append(slots[i]) }
        }
        return out
    }

    /// «19:00» или «19:00–21:00» для брони на несколько окон.
    fileprivate static func slotRangeLabel(_ slot: Slot, slotMinutes: Int, hours: Int) -> String {
        let start = String((slot.timeStart ?? "").prefix(5))
        guard hours > 1, slotMinutes > 0, start.count >= 4 else { return start }
        let parts = start.split(separator: ":").map(String.init)
        let mins = (Int(parts.first ?? "0") ?? 0) * 60 + (Int(parts.count > 1 ? parts[1] : "0") ?? 0)
            + slotMinutes * hours
        let end = String(format: "%02d:%02d", (mins / 60) % 24, mins % 60)
        return "\(start)–\(end)"
    }

    /// «3 чел. · 2 ч» — состав брони. nil, если выбирать было нечего.
    fileprivate static func bookingComposition(_ service: ServiceItem?, guests: Int, hours: Int) -> String? {
        guard let sv = service else { return nil }
        var parts: [String] = []
        if sv.needsGuests { parts.append("\(guests) чел.") }
        if sv.needsHours { parts.append("\(hours) ч") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Шаг «−  N  +» для количества человек и часов

private struct CountStepper: View {
    let label: String
    @Binding var value: Int
    let min: Int
    let max: Int
    let hint: String

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 13, weight: .bold)).foregroundStyle(YMColor.text)
                Text(hint).font(.system(size: 11)).foregroundStyle(YMColor.muted)
            }
            Spacer()
            stepButton("minus", enabled: value > min) { value = Swift.max(min, value - 1) }
            Text("\(value)")
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(YMColor.text)
                .frame(width: 40)
            stepButton("plus", enabled: value < max) { value = Swift.min(max, value + 1) }
        }
        .frame(maxWidth: .infinity)
    }

    private func stepButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(enabled ? YMColor.text : YMColor.muted)
                .frame(width: 36, height: 36)
                .background(enabled ? YMColor.surface2 : YMColor.surface, in: Circle())
                .overlay(Circle().strokeBorder(YMColor.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Строка услуги

private struct ServiceRow: View {
    /// «до 8 чел. одновременно · до 6 ч». nil — обычная услуга на одного.
    fileprivate static func capacityNote(_ s: ServiceItem) -> String? {
        var parts: [String] = []
        if s.capacityValue > 1 { parts.append("до \(s.capacityValue) чел. одновременно") }
        if s.maxSlotsValue > 1 { parts.append("до \(s.maxSlotsValue) ч") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    let service: ServiceItem
    let selected: Bool
    let fee: Decimal
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(service.name ?? "—")
                                .font(.system(size: 15.5, weight: .bold))
                                .foregroundStyle(YMColor.text)
                                .lineLimit(2)
                            if service.isAtClient {
                                Text("Выезд к вам")
                                    .font(.system(size: 10.5, weight: .heavy))
                                    .foregroundStyle(YMColor.accent)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(YMColor.accent.opacity(0.14), in: Capsule())
                            }
                        }
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
                        // Игровой зал: «до 8 чел. одновременно · до 6 ч».
                        // У обычной услуги (1 место, 1 окно) строки нет.
                        if let note = Self.capacityNote(service) {
                            Text(note)
                                .font(.system(size: 12))
                                .foregroundStyle(YMColor.muted)
                        }
                        // Кто оказывает услугу: «мастер Анна» / «мастера: Анна, Ольга».
                        if let who = service.mastersLabel {
                            Text(who)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(YMColor.accent)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Money.format(Money.dec(service.price)))
                            .font(.system(size: 15.5, weight: .heavy))
                            .foregroundStyle(YMColor.text)
                        // «за человека в час» — подпись готовит сервер (price_unit).
                        if let unit = service.priceUnit, !unit.isEmpty, unit != "за услугу" {
                            Text(unit)
                                .font(.system(size: 11))
                                .foregroundStyle(YMColor.muted)
                        }
                        // Стоимость выезда показываем отдельной строкой: гость
                        // должен видеть её до выбора времени, а не в чеке.
                        if service.isAtClient, Money.dec(service.travelFee) > 0 {
                            Text("+ \(Money.format(Money.dec(service.travelFee))) выезд")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(YMColor.accent)
                        }
                    }
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
    /// Показывать «N св.» — только для окон с ёмкостью больше одного места.
    var showFree: Bool = false
    var onPick: (Slot) -> Void = { _ in }

    private let columns = [GridItem(.adaptive(minimum: 78), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(slots) { slot in
                Button { Haptics.light(); onPick(slot) } label: {
                    VStack(spacing: 0) {
                        Text(String((slot.timeStart ?? "").prefix(5)))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(YMColor.text)
                        if showFree {
                            Text("\(slot.freeValue) св.")
                                .font(.system(size: 11))
                                .foregroundStyle(YMColor.muted)
                        }
                    }
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
    /// «3 чел. · 2 ч». nil — выбирать было нечего (обычная услуга).
    var composition: String?
    let price: Decimal
    /// Выезд мастера. Только для услуги с location_type == "at_client".
    let travel: Decimal
    let fee: Decimal
    let total: Decimal
    /// Услуга выездная — просим адрес и не даём подтвердить без улицы и дома.
    let atClient: Bool
    @Binding var address: VisitAddress
    /// Адреса из профиля — подставить в один тап.
    var saved: [Address] = []
    var onPickSaved: (Address) -> Void = { _ in }
    let confirming: Bool
    var onConfirm: () -> Void = {}
    var onDismiss: () -> Void = {}

    /// Кнопку блокируем, пока выездной адрес неполный: сервер всё равно вернёт
    /// 422 «нужен адрес», и лучше показать это до нажатия, а не после.
    private var canConfirm: Bool { !confirming && (!atClient || address.isComplete) }

    var body: some View {
        ScrollView {
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

                // Состав брони: гость должен видеть, за что платит, до подтверждения.
                if let comp = composition {
                    HStack {
                        Text("Бронь")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(YMColor.muted)
                        Spacer()
                        Text(comp)
                            .font(.system(size: 13, weight: .heavy)).foregroundStyle(YMColor.text)
                    }
                    .padding(14)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.top, 8)
                }

                if atClient { addressBlock.padding(.top, 12) }

                priceRow(atClient ? "Стоимость услуги" : "Стоимость", price, bold: false).padding(.top, 12)
                if travel > 0 { priceRow("Выезд мастера", travel, bold: false) }
                if fee > 0 { priceRow("Сервисный сбор", fee, bold: false) }
                priceRow("Итого", total, bold: true).padding(.top, 4)

                Button(action: onConfirm) {
                    Text(confirming ? "Записываем…" : "Подтвердить запись")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(YMPrimaryButtonStyle())
                .disabled(!canConfirm)
                .opacity(canConfirm ? 1 : 0.5)
                .padding(.top, 18)

                if atClient && !address.isComplete {
                    Text("Укажите улицу и номер дома — мастер приедет по этому адресу")
                        .font(.system(size: 12.5))
                        .foregroundStyle(YMColor.muted)
                        .padding(.top, 8)
                }

                Button("Отмена", action: onDismiss)
                    .buttonStyle(YMSecondaryButtonStyle())
                    .disabled(confirming)
                    .padding(.top, 10)
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .presentationDetents(atClient ? [.large] : [.medium])
    }

    // MARK: Куда приехать

    @ViewBuilder
    private var addressBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(YMColor.accent)
                Text("Куда приехать")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(YMColor.text)
            }

            if !saved.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(saved) { a in
                            Button {
                                Haptics.selection()
                                onPickSaved(a)
                            } label: {
                                Text(a.label?.isEmpty == false ? (a.label ?? "") : a.display)
                                    .font(.system(size: 12.5, weight: .bold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(YMColor.surface, in: Capsule())
                                    .foregroundStyle(YMColor.text)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }

            addrField("Улица", text: $address.street)
            HStack(spacing: 8) {
                addrField("Дом", text: $address.house)
                addrField("Кв.", text: $address.apartment, numeric: true)
            }
            HStack(spacing: 8) {
                addrField("Подъезд", text: $address.entrance, numeric: true)
                addrField("Этаж", text: $address.floor, numeric: true)
            }
            addrField("Комментарий для мастера", text: $address.comment)
        }
        .padding(14)
        .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func addrField(_ placeholder: String, text: Binding<String>,
                           numeric: Bool = false) -> some View {
        TextField(placeholder, text: text)
            .keyboardType(numeric ? .numbersAndPunctuation : .default)
            .font(.system(size: 14.5))
            .foregroundStyle(YMColor.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .disabled(confirming)
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
    /// Данные с сервера — печатаем как есть, ничего не пересчитываем.
    var info: AppointmentResult?
    var onClose: () -> Void = {}

    private var summary: String? {
        guard let r = info else { return nil }
        var when: [String] = []
        if let d = r.date, !d.isEmpty { when.append(d) }
        let t = [r.time, r.timeEnd].compactMap { $0 }.filter { !$0.isEmpty }
        if !t.isEmpty { when.append(t.joined(separator: "–")) }
        var what: [String] = []
        if (r.guests ?? 1) > 1 { what.append("\(r.guests ?? 1) чел.") }
        if (r.slots ?? 1) > 1 { what.append("\(r.slots ?? 1) ч") }
        let all = [when.joined(separator: ", "), what.joined(separator: " · ")].filter { !$0.isEmpty }
        return all.isEmpty ? nil : all.joined(separator: " · ")
    }

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
            if let sum = summary {
                Text(sum)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(YMColor.text)
                    .multilineTextAlignment(.center)
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
