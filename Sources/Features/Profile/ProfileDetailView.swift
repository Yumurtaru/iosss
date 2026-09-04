//
//  ProfileDetailView.swift — Адреса / Мои записи (premium-клиент)
//
//  Макет ProfileDetailPhone (addresses | bookings). Токены, light+dark,
//  Dynamic Type, Reduce Motion.
//
//  ТОЧКИ ВХОДА (для навигации):
//    • AddressesView()   — карточки Дом/Работа/…, основной адрес (золотая рамка + бейдж),
//                          «＋ Добавить адрес» (пунктир), CRUD через реальные методы.
//    • BookingsView()    — табы Предстоящие/Прошедшие, карточки записи, действия Отменить/Маршрут.
//
//  ПРИВЯЗКА К API (как в старом AddressesView):
//    • GET    api/v1/profile/addresses          → [Address]
//    • POST   api/v1/profile/addresses          ← AddressBody (создание)
//    • DELETE api/v1/profile/addresses/{id}     (удаление)
//    • GET    api/address/suggest?q=            → [AddrSuggest] (Dadata-прокси)
//  Записи (bookings):
//    • GET  api/v1/appointments             → [Appointment] (список записей клиента)
//    • POST api/v1/orders/{orderId}/cancel  (отмена записи; сервер возвращает окно в продажу)
//

import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - АДРЕСА
// ─────────────────────────────────────────────────────────────────────────────

struct AddressesView: View {
    @State private var items: [Address] = []
    @State private var loading = true
    @State private var showAdd = false
    @State private var editItem: Address?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YMSpace.md) {
                if loading {
                    ForEach(0..<3, id: \.self) { _ in SkeletonBox(radius: 18).frame(height: 78) }
                } else if items.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(items.enumerated()), id: \.element.id) { _, a in
                        AddressCard(address: a,
                                    onEdit: { editItem = a },
                                    onDelete: { Task { await remove(a) } })
                    }
                }
                addButton
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxxl)
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Адреса доставки")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAdd, onDismiss: { Task { await load() } }) { AddAddressView() }
        .task { await load() }
    }

    private var addButton: some View {
        Button { Haptics.light(); showAdd = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                Text("Добавить адрес").font(.system(size: 14.5, weight: .heavy))
            }
            .foregroundStyle(YMColor.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(YMColor.hairline)
            )
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: YMSpace.sm) {
            Text("📍").font(.system(size: 44))
            Text("Адресов пока нет").font(YMFont.title3).foregroundStyle(YMColor.text)
            Text("Добавьте адрес доставки, чтобы оформлять заказы быстрее.")
                .font(YMFont.callout).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl).padding(.vertical, 30)
    }

    private func load() async {
        loading = true
        items = (try? await API.shared.list("api/v1/profile/addresses")) ?? []
        // Основной — первым (золотая рамка/бейдж по isDefaultBool).
        items.sort { ($0.isDefaultBool ? 0 : 1) < ($1.isDefaultBool ? 0 : 1) }
        loading = false
    }
    private func remove(_ a: Address) async {
        do {
            try await API.shared.deleteVoid("api/v1/profile/addresses/\(a.id)")
            await MainActor.run { items.removeAll { $0.id == a.id } }
        } catch {}
    }
}

/// Карточка адреса: иконка по типу, название, «Основной»-бейдж, адрес, свайп-удаление.
private struct AddressCard: View {
    let address: Address
    var onEdit: () -> Void = {}
    var onDelete: () -> Void = {}

    private var isMain: Bool { address.isDefaultBool }
    private var icon: String {
        let l = (address.label ?? "").lowercased()
        if l.contains("дом") { return "🏠" }
        if l.contains("работ") || l.contains("офис") { return "💼" }
        return "📍"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Text(icon)
                .font(.system(size: 18))
                .frame(width: 40, height: 40)
                .background(isMain ? YMColor.accent.opacity(0.14) : YMColor.surface2,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(address.label ?? "Адрес")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(YMColor.text)
                    if isMain {
                        Text("Основной")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(YMColor.accent)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(YMColor.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
                Text(address.display.isEmpty ? "—" : address.display)
                    .font(.system(size: 13))
                    .foregroundStyle(YMColor.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Menu {
                Button { onEdit() } label: { Label("Изменить", systemImage: "pencil") }
                Button(role: .destructive) { onDelete() } label: { Label("Удалить", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(YMColor.muted)
                    .frame(width: 30, height: 30)
            }
        }
        .padding(15)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isMain ? YMColor.accent : YMColor.hairline, lineWidth: isMain ? 1.5 : 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(address.label ?? "Адрес")\(isMain ? ", основной" : ""), \(address.display)")
    }
}

/// Тело создания адреса (POST api/v1/profile/addresses). camelCase → snake_case автоматически.
private struct AddressBody: Encodable {
    let label: String
    let city: String?
    let street: String
    let house: String?
    let apartment: String?
    let entrance: String?
    let floor: String?
    let intercom: String?
    let lat: Double?
    let lng: Double?
}

/// Добавление адреса: живые подсказки Dadata (api/address/suggest), валидация координат.
private struct AddAddressView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var label = "Дом"
    @State private var street = ""
    @State private var house = ""
    @State private var apartment = ""
    @State private var entrance = ""
    @State private var floor = ""
    @State private var intercom = ""
    @State private var lat: Double?
    @State private var lng: Double?
    @State private var suggestions: [AddrSuggest] = []
    @State private var suggestTask: Task<Void, Never>?
    @State private var suppress = false
    @State private var saving = false
    @State private var error: String?

    private var cityName: String { Session.shared.cityName ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Название (Дом, Работа…)", text: $label) }
                Section("Адрес") {
                    if !cityName.isEmpty {
                        HStack { Text("Город"); Spacer(); Text(cityName).foregroundStyle(YMColor.muted) }
                    }
                    TextField("Улица и дом", text: $street)
                        .onChange(of: street) { v in scheduleSuggest(v) }
                    ForEach(suggestions) { s in
                        Button { pick(s) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "mappin.circle").foregroundStyle(YMColor.muted)
                                Text(s.value ?? "").foregroundStyle(YMColor.text)
                                Spacer()
                            }
                        }
                    }
                    TextField("Дом", text: $house)
                    TextField("Квартира (по желанию)", text: $apartment).keyboardType(.numbersAndPunctuation)
                    TextField("Подъезд (по желанию)", text: $entrance).keyboardType(.numbersAndPunctuation)
                    TextField("Этаж (по желанию)", text: $floor).keyboardType(.numbersAndPunctuation)
                    TextField("Домофон (по желанию)", text: $intercom).keyboardType(.numbersAndPunctuation)
                }
                if let e = error { Text(e).foregroundStyle(YMColor.statusCancel).font(YMFont.caption) }
                Section {
                    Button(action: save) {
                        HStack { Spacer()
                            if saving { ProgressView() } else { Text("Сохранить").fontWeight(.bold) }
                            Spacer() }
                    }
                    .disabled(saving)
                }
            }
            .navigationTitle("Новый адрес")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
        }
        .tint(YMColor.accent)
    }

    private func scheduleSuggest(_ text: String) {
        suggestTask?.cancel()
        if suppress { suppress = false; suggestions = []; return }
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { suggestions = []; return }
        let query = cityName.isEmpty ? q : "\(cityName), \(q)"
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let res: [AddrSuggest] = (try? await API.shared.get("api/address/suggest", query: ["q": query])) ?? []
            if Task.isCancelled { return }
            await MainActor.run { suggestions = res }
        }
    }
    private func pick(_ s: AddrSuggest) {
        suppress = true
        street = s.street ?? street
        if let h = s.house, !h.isEmpty { house = h }
        lat = s.lat; lng = s.lng
        suggestions = []
    }
    private func save() {
        if street.trimmingCharacters(in: .whitespaces).isEmpty { error = "Укажите улицу и дом"; return }
        if lat == nil || lng == nil { error = "Выберите адрес из подсказок"; return }
        saving = true
        let body = AddressBody(label: label,
                               city: cityName.isEmpty ? nil : cityName,
                               street: street,
                               house: house.isEmpty ? nil : house,
                               apartment: apartment.isEmpty ? nil : apartment,
                               entrance: entrance.isEmpty ? nil : entrance,
                               floor: floor.isEmpty ? nil : floor,
                               intercom: intercom.isEmpty ? nil : intercom,
                               lat: lat, lng: lng)
        Task {
            try? await API.shared.postVoid("api/v1/profile/addresses", body: body)
            await MainActor.run { Haptics.success(); dismiss() }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - МОИ ЗАПИСИ (bookings)
// ─────────────────────────────────────────────────────────────────────────────

/// Модель карточки записи. Маппится из Appointment (GET api/v1/appointments);
/// поля 1:1 с макетом ProfileDetail (bookings) плюс то, что нужно кнопкам:
/// orderId — для отмены, address/coords — для маршрута.
struct BookingItem: Identifiable {
    let id: Int
    let orderId: Int?
    let service: String
    let org: String
    let date: Date?
    let time: String
    let status: BookingStatus
    let address: String?
    let lat: Double?
    let lng: Double?
    /// Отменять можно только предстоящую и ещё не начатую запись — те же статусы,
    /// что принимает сервер в POST api/v1/orders/{id}/cancel.
    var canCancel: Bool { orderId != nil && (status == .confirmed || status == .pending) }

    init(from a: Appointment) {
        id = a.id
        orderId = a.orderId
        service = a.service ?? "Услуга"
        org = a.shop ?? ""
        date = BookingItem.parse(a.date)
        time = String((a.timeStart ?? "").prefix(5))
        switch (a.status ?? "").lowercased() {
        case "cancelled":           status = .cancelled
        case "accepted", "done":    status = .confirmed
        default:                    status = .pending
        }
        address = (a.shopAddress?.isEmpty == false) ? a.shopAddress : nil
        lat = a.shopLat
        lng = a.shopLng
    }

    /// Дата визита приходит как "2026-09-06" — разбираем фиксированной локалью,
    /// иначе на телефоне с другим календарём получится nil и плашка будет пустой.
    private static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }
}
enum BookingStatus { case confirmed, pending, cancelled
    var title: String { self == .confirmed ? "Подтверждена" : self == .pending ? "Ожидает" : "Отменена" }
}

private enum BookingTab: String, CaseIterable, Hashable {
    case upcoming, past
    var title: String { self == .upcoming ? "Предстоящие" : "Прошедшие" }
}

struct BookingsView: View {
    @State private var tab: BookingTab = .upcoming
    @State private var upcoming: [BookingItem] = []
    @State private var past: [BookingItem] = []
    @State private var loading = true

    private var current: [BookingItem] { tab == .upcoming ? upcoming : past }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                YMSegmented(options: BookingTab.allCases, selection: $tab) { $0.title }
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.bottom, YMSpace.lg)

                if loading {
                    VStack(spacing: YMSpace.lg) {
                        ForEach(0..<2, id: \.self) { _ in SkeletonBox(radius: 20).frame(height: 150) }
                    }
                    .padding(.horizontal, YMSpace.xl)
                } else if current.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: YMSpace.lg) {
                        ForEach(current) { b in
                            BookingCard(booking: b, onCancel: { await cancel(b) })
                        }
                    }
                    .padding(.horizontal, YMSpace.xl)
                }
            }
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxxl)
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Мои записи")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var emptyState: some View {
        VStack(spacing: YMSpace.sm) {
            Text("📅").font(.system(size: 44))
            Text(tab == .upcoming ? "Нет предстоящих записей" : "Нет прошедших записей")
                .font(YMFont.title3).foregroundStyle(YMColor.text)
            Text("Запишитесь на услугу в разделе организаций.")
                .font(YMFont.callout).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl).padding(.top, 40)
    }

    private func load() async {
        loading = true
        let list: [Appointment] = (try? await API.shared.list("api/v1/appointments")) ?? []
        // Делим по серверному признаку is_past: он уже учитывает и время окончания
        // визита, и статусы done/cancelled. Если поля нет (старый сервер) — запись
        // считается предстоящей, чтобы не пропасть из виду.
        upcoming = list.filter { $0.isPast != true }.map(BookingItem.init(from:))
        past     = list.filter { $0.isPast == true }.map(BookingItem.init(from:))
        loading = false
    }

    /// Отмена записи. Сервер тем же вызовом возвращает окно в продажу
    /// (POST api/v1/orders/{id}/cancel → releaseServiceSlotForOrder).
    private func cancel(_ b: BookingItem) async {
        guard let oid = b.orderId else { return }
        try? await API.shared.postVoid("api/v1/orders/\(oid)/cancel")
        await load()
    }
}

/// Карточка записи: дата-плашка, услуга, организация, время, статус, действия Отменить/Маршрут.
private struct BookingCard: View {
    let booking: BookingItem
    /// Отмена записи — выполняет владелец экрана (BookingsView), он же перезагружает список.
    var onCancel: () async -> Void = {}
    @Environment(\.openURL) private var openURL
    @State private var confirmCancel = false
    @State private var working = false

    private var monthText: String {
        guard let d = booking.date else { return "" }
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "MMM"
        return f.string(from: d).uppercased()
    }
    private var dayText: String {
        guard let d = booking.date else { return "—" }
        let f = DateFormatter(); f.dateFormat = "d"
        return f.string(from: d)
    }
    private var statusColor: Color {
        switch booking.status {
        case .confirmed: return YMColor.statusDone
        case .pending:   return YMColor.accent
        case .cancelled: return YMColor.statusCancel
        }
    }

    /// Маршрут строим по координатам организации, а если их нет — по адресу.
    private var hasRoute: Bool {
        (booking.lat != nil && booking.lng != nil) || (booking.address?.isEmpty == false)
    }

    private func openRoute() {
        var url: URL?
        if let lat = booking.lat, let lng = booking.lng {
            url = URL(string: "http://maps.apple.com/?daddr=\(lat),\(lng)&dirflg=d")
        } else if let addr = booking.address,
                  let q = addr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            url = URL(string: "http://maps.apple.com/?daddr=\(q)&dirflg=d")
        }
        if let url { openURL(url) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(spacing: 0) {
                    Text(monthText).font(.system(size: 11, weight: .bold)).foregroundStyle(YMColor.accent)
                    Text(dayText).font(.system(size: 22, weight: .heavy)).foregroundStyle(YMColor.text)
                }
                .frame(width: 56)
                .padding(.vertical, 8)
                .background(YMColor.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(booking.service).font(.system(size: 15.5, weight: .heavy)).foregroundStyle(YMColor.text).lineLimit(1)
                    Text(booking.org).font(.system(size: 12.5)).foregroundStyle(YMColor.muted).lineLimit(1)
                    HStack(spacing: 8) {
                        Label(booking.time, systemImage: "clock")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(YMColor.text)
                            .labelStyle(.titleAndIcon)
                        Text(booking.status.title)
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(statusColor)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(statusColor.opacity(0.16), in: Capsule())
                    }
                    .padding(.top, 5)
                }
                Spacer(minLength: 0)
            }
            .padding(15)

            Divider().overlay(YMColor.hairline)

            HStack(spacing: 0) {
                if booking.canCancel {
                    Button {
                        Haptics.light(); confirmCancel = true
                    } label: {
                        Text(working ? "Отменяем…" : "Отменить")
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(YMColor.muted)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .disabled(working)
                    Rectangle().fill(YMColor.hairline).frame(width: 1, height: 44)
                }
                Button {
                    Haptics.light(); openRoute()
                } label: {
                    Text("Маршрут")
                        .font(.system(size: 13.5, weight: .heavy))
                        .foregroundStyle(YMColor.accent)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .disabled(!hasRoute)
                .opacity(hasRoute ? 1 : 0.4)
            }
        }
        .confirmationDialog("Отменить запись? Время освободится и станет доступно другим клиентам.",
                            isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Отменить запись", role: .destructive) {
                working = true
                Task { await onCancel(); working = false }
            }
            Button("Оставить", role: .cancel) {}
        }
        .ymCard(radius: 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(booking.service), \(booking.org), \(booking.time), \(booking.status.title)")
    }
}
