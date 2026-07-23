import SwiftUI

//
//  CheckoutView.swift — экран оформления (screen: checkout). Дизайн 1:1 с CheckoutPhone.dc.html.
//
//  ПУБЛИЧНАЯ INIT-СИГНАТУРА (для централизованной навигации):
//    CheckoutView(onSuccess: (OrderCreateResult) -> Void, onBack: () -> Void)
//      onSuccess — заказ создан; родитель пушит SuccessView(order:).
//      onBack    — «‹ Оформление» назад к корзине.
//
//  API — реальные методы старого клиента (контракт НЕ меняется):
//    POST api/v1/delivery/quote            -> DeliveryQuote   (расчёт доставки по адресу)
//    GET  api/v1/profile/addresses         -> [Address]       (сохранённые адреса)
//    GET  api/address/suggest?q=…          -> [AddrSuggest]   (Dadata-прокси, токен на сервере)
//    POST api/v1/profile/addresses         -> (создание адреса, AddressBody)
//    GET  api/v1/shops/{slug}              -> ShopDetail      (сервисный сбор)
//    POST api/v1/orders                    -> OrderCreateResult (создание заказа)
//
//  Зона доставки определяется на сервере СКРЫТО по координатам адреса. Клиент видит только
//  результат: DeliveryQuote.available == false → адрес вне зоны, «Оформить заказ» блокируется.
//  Деньги — только Decimal через Money.format(Money.parse(...)). Токены — YM*.
//
//  Паритет с Android (9 Android-client-new): выбор сохранённых адресов радио-строкой,
//  «＋ Добавить новый адрес», форма без города (город из Session.cityName), Dadata-подсказки
//  строго по выбранному городу, блокировка CTA при outOfZone/noAddress, оплата «Наличные/Картой».
//

// ── Тело создания заказа (контракт как в старом клиенте, snake_case) ──
private struct OrderItemBody: Encodable {
    let productId: Int; let qty: Double; let modifiers: [Int]?
    enum CodingKeys: String, CodingKey { case productId = "product_id", qty, modifiers }
}
private struct OrderBody: Encodable {
    let shopId: Int; let items: [OrderItemBody]; let deliveryType: String
    let paymentType: String; let address: String?; let comment: String?
    let deliveryPrice: Double?
    let lat: Double?; let lng: Double?
    enum CodingKeys: String, CodingKey {
        case shopId = "shop_id", items, deliveryType = "delivery_type", paymentType = "payment_type",
             address, comment, deliveryPrice = "delivery_price", lat, lng
    }
}
// Тело расчёта доставки (совпадает со старым клиентом).
private struct QuoteBody: Encodable { let shopId: Int; let lat: Double; let lng: Double; let subtotal: Double
    enum CodingKeys: String, CodingKey { case shopId = "shop_id", lat, lng, subtotal } }

// Тело создания адреса (POST api/v1/profile/addresses). camelCase → snake_case автоматически.
// Совпадает 1:1 с AddressBody профиля и AddressReq Android.
private struct NewAddressBody: Encodable {
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

// Способ получения (в макете 3 сегмента; delivery/pickup + за столик = dine_in).
private enum Fulfillment: String, CaseIterable, Hashable {
    case delivery, pickup, dineIn
    var apiValue: String { self == .dineIn ? "dine_in" : rawValue }
    var title: String {
        switch self {
        case .delivery: return "Доставка"
        case .pickup:   return "Самовывоз"
        case .dineIn:   return "За столик"
        }
    }
}

// Способ оплаты. «Картой» — это онлайн-оплата (серверу paymentType="online"), «Наличные» → "cash".
private enum Payment: String, CaseIterable, Hashable {
    case cash, card
    var apiValue: String { self == .card ? "online" : "cash" }
    var title: String { self == .card ? "Картой" : "Наличные" }
}

struct CheckoutView: View {
    var onSuccess: (OrderCreateResult) -> Void = { _ in }
    var onBack: () -> Void = {}

    @ObservedObject private var cart = Cart.shared

    @State private var fulfillment: Fulfillment = .delivery
    @State private var payment: Payment = .cash
    @State private var addresses: [Address] = []
    @State private var selectedAddress: Address?
    @State private var shop: ShopDetail?
    @State private var quote: DeliveryQuote?
    @State private var comment = ""
    @State private var placing = false
    @State private var errorText: String?
    @State private var showAddAddress = false

    // Город из настроек — клиент его НЕ вводит (шапка «Ваш город»).
    private var cityName: String { Session.shared.cityName ?? "" }

    // MARK: - Деньги (всё Decimal)

    private var subtotal: Decimal { Money.parse(cart.total) }

    // Стоимость доставки — ТОЛЬКО из серверного расчёта по адресу. До адреса / при
    // недоступности / для самовывоза-и-стола → 0.
    private var deliveryCost: Decimal {
        guard fulfillment == .delivery, let q = quote, q.available else { return 0 }
        return Money.parse(q.deliveryPrice ?? 0)
    }
    private var serviceFee: Decimal { Money.parse(Fees.service(subtotal: cart.total, shop: shop)) }
    private var grandTotal: Decimal { max(0, subtotal + deliveryCost + serviceFee) }

    // MARK: - Блокировка CTA (паритет с Android: outOfZone / noAddress / belowMin)

    // Адрес вне зоны доставки: сервер вернул quote.available == false.
    private var outOfZone: Bool {
        fulfillment == .delivery && quote != nil && quote?.available == false
    }
    // Для доставки обязателен выбранный адрес с координатами.
    private var noAddress: Bool {
        fulfillment == .delivery &&
        (selectedAddress == nil || selectedAddress?.lat == nil || selectedAddress?.lng == nil)
    }
    // Минимальная сумма не набрана.
    private var belowMin: Bool {
        fulfillment == .delivery && quote?.belowMin == true
    }
    private var ctaEnabled: Bool {
        !placing && !cart.isEmpty && !outOfZone && !noAddress && !belowMin
    }

    var body: some View {
        ZStack {
            YMColor.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                scrollContent
                bottomCTA
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showAddAddress, onDismiss: { Task { await loadAddresses() } }) {
            AddAddressSheet(cityName: cityName) { newAddr in
                // Свежесозданный адрес выбираем и сразу считаем доставку.
                selectedAddress = newAddr
                Task { await loadAddresses(selectAfter: newAddr) }
            }
        }
        .task {
            await loadAddresses()
            if let slug = cart.shopSlug {
                shop = try? await API.shared.get("api/v1/shops/\(slug)")
            }
        }
        .onChange(of: fulfillment) { _ in Task { await quoteDelivery() } }
    }

    // MARK: - Header «‹ Оформление»

    private var header: some View {
        HStack(spacing: YMSpace.md) {
            Button(action: { Haptics.light(); onBack() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(YMColor.text)
                    .frame(width: 38, height: 38)
                    .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Text("Оформление")
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(YMColor.text)
            Spacer()
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.xs)
        .padding(.bottom, YMSpace.md)
    }

    // MARK: - Scroll content

    private var scrollContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                storeBanner
                    .padding(.bottom, YMSpace.md)

                SectionKicker("Способ получения").padding(.top, YMSpace.xs).padding(.bottom, YMSpace.sm)
                YMSegmented(options: Fulfillment.allCases, selection: $fulfillment) { $0.title }

                if fulfillment == .delivery {
                    addressSelector.padding(.top, YMSpace.md)
                    if outOfZone {
                        Text(quote?.reason?.isEmpty == false ? quote!.reason! : "Доставка по этому адресу недоступна")
                            .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, YMSpace.sm)
                    }
                }

                SectionKicker("Ваш заказ").padding(.top, YMSpace.lg).padding(.bottom, YMSpace.md)
                VStack(spacing: YMSpace.md) {
                    ForEach(cart.lines) { line in CheckoutRow(line: line) }
                }

                SectionKicker("Оплата").padding(.top, YMSpace.lg).padding(.bottom, YMSpace.sm)
                YMSegmented(options: Payment.allCases, selection: $payment) { $0.title }

                commentField.padding(.top, YMSpace.lg)

                totalsCard.padding(.top, YMSpace.lg)

                if let e = errorText {
                    Text(e).font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, YMSpace.md)
                }
                Color.clear.frame(height: YMSpace.lg)
            }
            .padding(.horizontal, YMSpace.xl)
        }
    }

    private var storeBanner: some View {
        HStack(spacing: YMSpace.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(YMColor.surface2)
                Text(monogram).font(.system(size: 17, weight: .heavy)).foregroundStyle(YMColor.accent)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(cart.shopName ?? "Магазин").font(.system(size: 14.5, weight: .bold)).foregroundStyle(YMColor.text)
                Text("\(cart.count) поз. в заказе").font(YMFont.caption).foregroundStyle(YMColor.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    private var monogram: String {
        let s = (cart.shopName ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "•" : String(s.prefix(1)).uppercased()
    }

    // MARK: - Выбор сохранённого адреса (радио-строки) + «＋ Добавить новый адрес»

    private var addressSelector: some View {
        VStack(spacing: YMSpace.xs) {
            if addresses.isEmpty {
                Text("Нет сохранённых адресов")
                    .font(YMFont.subhead).foregroundStyle(YMColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 10)
            } else {
                ForEach(addresses) { a in
                    Button(action: { Haptics.light(); selectAddress(a) }) {
                        addressRow(a)
                    }
                    .buttonStyle(.plain)
                }
            }

            // ＋ Добавить новый адрес
            Button(action: { Haptics.light(); showAddAddress = true }) {
                HStack(spacing: YMSpace.sm) {
                    Text("＋").font(.system(size: 17, weight: .bold)).foregroundStyle(YMColor.accent)
                    Text("Добавить новый адрес")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(YMColor.accent)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            // ETA доставки / минимум — только для выбранного адреса.
            if let q = quote, q.available, let tmin = q.timeMin, let tmax = q.timeMax, tmax > 0 {
                Text("\(tmin)–\(tmax) мин")
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 2)
            }
            if belowMin, let q = quote {
                Text("Минимальная сумма заказа: \(Money.format(Money.parse(q.minOrder ?? 0)))")
                    .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 2)
            }
        }
        .padding(YMSpace.xs)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    private func addressRow(_ a: Address) -> some View {
        let isSel = selectedAddress?.id == a.id
        return HStack(spacing: YMSpace.md) {
            // radio-индикатор
            ZStack {
                Circle().strokeBorder(isSel ? YMColor.accent : YMColor.hairline, lineWidth: 2)
                if isSel { Circle().fill(YMColor.accent).frame(width: 10, height: 10) }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.label?.isEmpty == false ? a.label! : "Адрес")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(YMColor.text)
                Text(a.display.isEmpty ? "Адрес без деталей" : a.display)
                    .font(YMFont.caption).foregroundStyle(YMColor.muted).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(isSel ? YMColor.surface2 : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }

    private var commentField: some View {
        HStack(spacing: YMSpace.sm) {
            Image(systemName: "square.and.pencil").font(.system(size: 15)).foregroundStyle(YMColor.muted)
            TextField("Комментарий к заказу…", text: $comment, axis: .vertical)
                .font(.system(size: 13.5))
                .foregroundStyle(YMColor.text)
                .tint(YMColor.accent)
        }
        .padding(14)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(YMColor.hairline)
        )
    }

    // Итоги: Товары / Доставка / Сервисный сбор.
    private var totalsCard: some View {
        VStack(spacing: 9) {
            totalRow("Товары (\(cart.count))", Money.format(subtotal))
            if fulfillment == .delivery {
                totalRow("Доставка", deliveryLabel)
            }
            if serviceFee > 0 {
                totalRow("Сервисный сбор", Money.format(serviceFee))
            }
        }
        .padding(YMSpace.lg)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    private var deliveryLabel: String {
        guard let q = quote else { return "уточняется" }
        if !q.available { return "недоступна" }
        return deliveryCost <= 0 ? "бесплатно" : Money.format(deliveryCost)
    }

    private func totalRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 13.5)).foregroundStyle(YMColor.muted)
            Spacer()
            Text(value).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(YMColor.muted)
        }
    }

    // MARK: - Bottom CTA «Оформить заказ · СУММА»

    private var bottomCTA: some View {
        VStack(spacing: YMSpace.md) {
            HStack {
                Text("Итого").font(.system(size: 13.5)).foregroundStyle(YMColor.muted)
                Spacer()
                Text(Money.format(grandTotal)).font(.system(size: 22, weight: .heavy)).foregroundStyle(YMColor.text)
            }
            Button(action: placeOrder) {
                HStack(spacing: YMSpace.sm) {
                    if placing { ProgressView().tint(YMColor.onAccent) }
                    Text(placing ? "Оформляем…" : "Оформить заказ · \(Money.format(grandTotal))")
                }
            }
            .buttonStyle(YMPrimaryButtonStyle())
            .disabled(!ctaEnabled)
        }
        .padding(.horizontal, YMSpace.lg)
        .padding(.top, YMSpace.lg)
        .padding(.bottom, YMSpace.xxl)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .top) { YMColor.hairline.frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Загрузка / расчёт

    // Загрузка списка адресов. selectAfter — если задан, выбрать именно его (после создания).
    private func loadAddresses(selectAfter: Address? = nil) async {
        do {
            let list: [Address] = try await API.shared.list("api/v1/profile/addresses")
            await MainActor.run {
                addresses = list
                if let want = selectAfter,
                   let match = list.first(where: { $0.id == want.id }) ?? list.max(by: { $0.id < $1.id }) {
                    selectedAddress = match
                } else if selectedAddress == nil {
                    // По умолчанию — основной адрес (с координатами) → сразу считается доставка.
                    selectedAddress = list.first(where: { $0.isDefaultBool }) ?? list.first
                }
            }
            await quoteDelivery()
        } catch {
            // graceful: адресов нет — покажем плейсхолдер, доставка = уточняется.
        }
    }

    private func selectAddress(_ a: Address) {
        selectedAddress = a
        Task { await quoteDelivery() }
    }

    // Серверный расчёт доставки по координатам адреса. shop_id — из корзины.
    private func quoteDelivery() async {
        guard fulfillment == .delivery,
              let a = selectedAddress, let la = a.lat, let lo = a.lng,
              let sid = cart.shopId else {
            await MainActor.run { quote = nil }
            return
        }
        let q: DeliveryQuote? = try? await API.shared.post(
            "api/v1/delivery/quote",
            body: QuoteBody(shopId: sid, lat: la, lng: lo, subtotal: cart.total)
        )
        await MainActor.run { quote = q }
    }

    // Полный адрес курьеру: город/улица/дом + доп. поля из выбранного адреса.
    private func composedAddress() -> String? {
        guard let a = selectedAddress else { return nil }
        var parts: [String] = []
        if let c = a.city, !c.isEmpty { parts.append(c) }
        if let st = a.street, !st.isEmpty {
            var line = st
            if let h = a.house, !h.isEmpty { line += ", д. \(h)" }
            parts.append(line)
        }
        if let ap = a.apartment, !ap.isEmpty { parts.append("кв. \(ap)") }
        if let en = a.entrance, !en.isEmpty { parts.append("подъезд \(en)") }
        if let fl = a.floor, !fl.isEmpty { parts.append("этаж \(fl)") }
        if let ic = a.intercom, !ic.isEmpty { parts.append("домофон \(ic)") }
        let s = parts.joined(separator: ", ")
        return s.isEmpty ? a.display : s
    }

    // MARK: - Создание заказа

    private func placeOrder() {
        guard ctaEnabled, let shopId = cart.shopId, !cart.isEmpty else { return }
        if fulfillment == .delivery {
            if selectedAddress == nil { errorText = "Выберите адрес доставки"; return }
            if let q = quote, !q.available { errorText = q.reason ?? "Доставка по этому адресу недоступна"; return }
            if let q = quote, q.belowMin == true {
                errorText = "Минимальная сумма заказа: \(Money.format(Money.parse(q.minOrder ?? 0)))"; return
            }
        }
        Haptics.medium()
        placing = true; errorText = nil

        let items = cart.lines.map {
            OrderItemBody(productId: $0.productId, qty: $0.qty,
                          modifiers: $0.modifierIds.isEmpty ? nil : $0.modifierIds)
        }
        let dp = fulfillment == .delivery ? NSDecimalNumber(decimal: deliveryCost).doubleValue : nil
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = OrderBody(
            shopId: shopId, items: items,
            deliveryType: fulfillment.apiValue,
            paymentType: payment.apiValue,   // "cash" | "online" («Картой» → online)
            address: fulfillment == .delivery ? composedAddress() : nil,
            comment: trimmed.isEmpty ? nil : trimmed,
            deliveryPrice: dp,
            lat: fulfillment == .delivery ? selectedAddress?.lat : nil,
            lng: fulfillment == .delivery ? selectedAddress?.lng : nil
        )

        Task {
            do {
                let r: OrderCreateResult = try await API.shared.post("api/v1/orders", body: body)
                await MainActor.run {
                    Haptics.success()
                    cart.clear()
                    placing = false
                    onSuccess(r)
                }
            } catch {
                await MainActor.run {
                    Haptics.error()
                    errorText = error.localizedDescription
                    placing = false
                }
            }
        }
    }
}

// MARK: - Форма нового адреса (шторка). Город НЕ вводится — из Session.cityName.
//         Улица — Dadata-подсказки строго по выбранному городу.

private struct AddAddressSheet: View {
    let cityName: String
    var onSaved: (Address) -> Void

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
    @State private var suppressSuggest = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField("Название (Дом, Работа…)", text: $label) }
                Section("Адрес") {
                    // Город берётся из настроек — не поле ввода.
                    if !cityName.isEmpty {
                        HStack { Text("Город"); Spacer(); Text(cityName).foregroundStyle(YMColor.muted) }
                    }
                    TextField("Улица", text: $street)
                        .onChange(of: street) { v in scheduleSuggest(v) }
                    // Подсказки Dadata, отфильтрованные по выбранному городу.
                    ForEach(suggestions) { s in
                        Button { pick(s) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "mappin.circle").foregroundStyle(YMColor.muted)
                                Text(suggestLine(s)).foregroundStyle(YMColor.text)
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
        .presentationDetents([.large])
    }

    private func suggestLine(_ s: AddrSuggest) -> String {
        var line = s.street ?? ""
        if let h = s.house, !h.isEmpty { line += (line.isEmpty ? "" : ", ") + "д. \(h)" }
        return line.isEmpty ? (s.value ?? "") : line
    }

    // Подсказки адреса (Dadata через сервер). Дебаунс 300 мс. Только выбранный город.
    private func scheduleSuggest(_ text: String) {
        suggestTask?.cancel()
        lat = nil; lng = nil   // новый ввод улицы — координаты недействительны, пока не выбрана подсказка
        if suppressSuggest { suppressSuggest = false; suggestions = []; return }
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { suggestions = []; return }
        // Запрос строим как «<Город>, <ввод>» — Dadata приоритезирует этот город.
        let query = cityName.isEmpty ? q : "\(cityName), \(q)"
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let res: [AddrSuggest] = (try? await API.shared.get("api/address/suggest", query: ["q": query])) ?? []
            if Task.isCancelled { return }
            // Дополнительная фильтрация: остаются только адреса выбранного города
            // (или без города — если прокси не вернул city), чтобы улицы других городов не лезли.
            let filtered = res.filter { s in
                cityName.isEmpty || (s.city?.isEmpty ?? true) || s.city?.caseInsensitiveCompare(cityName) == .orderedSame
            }
            await MainActor.run { suggestions = filtered }
        }
    }

    // Выбор подсказки: заполняем улицу/дом/координаты.
    private func pick(_ s: AddrSuggest) {
        suppressSuggest = true
        street = s.street?.isEmpty == false ? s.street! : (s.value ?? street)
        if let h = s.house, !h.isEmpty { house = h }
        lat = s.lat; lng = s.lng
        suggestions = []
    }

    private func save() {
        if street.trimmingCharacters(in: .whitespaces).isEmpty { error = "Укажите улицу"; return }
        if lat == nil || lng == nil { error = "Выберите адрес из подсказок"; return }
        saving = true; error = nil
        let body = NewAddressBody(
            label: label.trimmingCharacters(in: .whitespaces).isEmpty ? "Адрес" : label,
            city: cityName.isEmpty ? nil : cityName,
            street: street,
            house: house.isEmpty ? nil : house,
            apartment: apartment.isEmpty ? nil : apartment,
            entrance: entrance.isEmpty ? nil : entrance,
            floor: floor.isEmpty ? nil : floor,
            intercom: intercom.isEmpty ? nil : intercom,
            lat: lat, lng: lng
        )
        // Локальный объект — чтобы сразу выбрать созданный адрес (id уточнится при перезагрузке списка).
        let optimistic = Address(
            id: Int.min, label: label, city: cityName.isEmpty ? nil : cityName,
            street: street, house: house.isEmpty ? nil : house,
            apartment: apartment.isEmpty ? nil : apartment, entrance: entrance.isEmpty ? nil : entrance,
            floor: floor.isEmpty ? nil : floor, intercom: intercom.isEmpty ? nil : intercom,
            lat: lat, lng: lng, isDefault: nil
        )
        Task {
            do {
                try await API.shared.postVoid("api/v1/profile/addresses", body: body)
                await MainActor.run { Haptics.success(); onSaved(optimistic); dismiss() }
            } catch {
                await MainActor.run { Haptics.error(); self.error = error.localizedDescription; saving = false }
            }
        }
    }
}

// MARK: - Строка товара (read-only, без степпера — как в макете checkout)

private struct CheckoutRow: View {
    let line: CartLine
    private var lineTotal: Decimal { Money.parse(line.unitPrice) * Decimal(line.qty) }

    var body: some View {
        HStack(spacing: YMSpace.md) {
            PhotoPlaceholder(url: API.imageURL(line.photo), label: "ФОТО", radius: 14, tone: line.productId)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.name).font(.system(size: 14.5, weight: .bold)).foregroundStyle(YMColor.text).lineLimit(1)
                let sub = subtitle
                if !sub.isEmpty {
                    Text(sub).font(YMFont.caption).foregroundStyle(YMColor.muted).lineLimit(1)
                }
            }
            Spacer(minLength: YMSpace.sm)
            Text(quantityLabel).font(.system(size: 13, weight: .bold)).foregroundStyle(YMColor.muted)
            Text(Money.format(lineTotal)).font(.system(size: 14.5, weight: .heavy)).foregroundStyle(YMColor.text).fixedSize()
        }
    }

    private var subtitle: String {
        if !line.modsLabel.isEmpty { return line.modsLabel }
        if let u = line.unit, !u.isEmpty { return u }
        return ""
    }
    private var quantityLabel: String {
        line.isFractional ? fmtQty(line.qty, line.unit) : "× \(Int(line.qty.rounded()))"
    }
}
