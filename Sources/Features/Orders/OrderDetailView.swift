import SwiftUI
import MapKit
import SafariServices

//  OrderDetailView.swift
//  Yumurta — premium iOS-клиент. Экран 6 (detail) «Заказ №…».
//
//  Init-сигнатура: OrderDetailView(id: Int, onChat: @escaping (Int) -> Void)
//    id     — orderId.
//    onChat — открыть чат с заведением по этому заказу (навигацию решает вызывающая сторона).
//
//  Данные 1:1 со старым клиентом:
//    GET  api/v1/orders/{id}          → OrderDetail  (status, items, суммы Double?…)
//    GET  api/v1/orders/{id}/track    → TrackData    (courierLat/Lng, courierName/Phone, etaMinutes, status)
//    GET  api/v1/orders/{id}/reorder  → ReorderData  (повтор заказа: shopId/Name/Slug + items)
//  Деньги — Double? → Money.format(Money.parse(x)) (Decimal).
//
//  Таймлайн статусов строится машиной OrderFlow (new→accepted→preparing→ready→in_delivery→done; cancelled).
//  Пин курьера и таймлайн говорят на том же «золотом» визуальном языке, что лента в списке.

// MARK: - CourierPoint (аннотация карты)

private struct CourierPoint: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

// MARK: - Локальные типы действий (Models.swift не трогаем — контракт аддитивный)

/// Обёртка ссылки оплаты для .sheet(item:) (openURL/SafariView).
struct PayLink: Identifiable {
    let id = UUID()
    let url: URL
}

/// Тело отзыва: POST api/v1/reviews {order_id, rating, text}.
/// camelCase → snake_case через API.encoder (.convertToSnakeCase) — 1:1 с Android createReview.
private struct OrderReviewBody: Encodable {
    let orderId: Int
    let rating: Int
    let text: String?
}

// MARK: - OrderDetailViewModel

@MainActor
final class OrderDetailViewModel: ObservableObject {
    let id: Int
    @Published var order: OrderDetail?
    @Published var track: TrackData?
    @Published var loading = true
    @Published var reorderInFlight = false
    @Published var reorderDone = false     // сервер повторил заказ → корзина обновлена

    // Действия по заказу (паритет с Android): отмена / онлайн-оплата / отзыв / NPS.
    @Published var actionBusy = false      // общий busy для одиночных действий (cancel/pay/review/nps)
    @Published var toast: String?          // единый тост-результат действия
    @Published var reviewSent = false      // локальный флаг «отзыв отправлен» (сервер флага не отдаёт)
    @Published var npsSent = false         // локальный флаг «NPS отправлен»
    @Published var payLink: PayLink?       // ссылка YooKassa → открыть во внешнем браузере

    private var pollTimer: Timer?

    init(id: Int) { self.id = id }

    func load() async {
        loading = true
        async let o: OrderDetail? = try? await API.shared.get("api/v1/orders/\(id)")
        async let t: TrackData?   = try? await API.shared.get("api/v1/orders/\(id)/track")
        order = await o
        track = await t
        loading = false
    }

    /// Перезагрузка после действия (отмена меняет статус → перерисовать таймлайн/кнопки).
    func reload() async {
        if let o: OrderDetail = try? await API.shared.get("api/v1/orders/\(id)") { order = o }
        if let t: TrackData   = try? await API.shared.get("api/v1/orders/\(id)/track") { track = t }
    }

    // MARK: Действия

    /// Отмена заказа: POST api/v1/orders/{id}/cancel (без тела). По успеху — перезагрузка.
    func cancel() async {
        guard !actionBusy else { return }
        actionBusy = true; defer { actionBusy = false }
        do {
            try await API.shared.postVoid("api/v1/orders/\(id)/cancel")
            Haptics.success(); toast = "Заказ отменён"
            await reload()
        } catch {
            Haptics.error(); toast = (error as? LocalizedError)?.errorDescription ?? "Не удалось отменить заказ"
        }
    }

    /// Онлайн-оплата: POST api/v1/orders/{id}/pay-online → PayOnlineResp(confirmation_url).
    /// По успеху — открываем confirmation_url (система/SafariView через openURL).
    func payOnline() async {
        guard !actionBusy else { return }
        actionBusy = true; defer { actionBusy = false }
        do {
            let resp: PayOnlineResp = try await API.shared.post("api/v1/orders/\(id)/pay-online")
            if let link = resp.confirmationUrl, let url = URL(string: link) {
                Haptics.light(); payLink = PayLink(url: url)
            } else {
                Haptics.warning(); toast = "Не удалось открыть оплату"
            }
        } catch {
            Haptics.error(); toast = (error as? LocalizedError)?.errorDescription ?? "Ошибка оплаты"
        }
    }

    /// Отзыв: POST api/v1/reviews {order_id, rating, text}. Контракт 1:1 с Android createReview.
    func sendReview(rating: Int, text: String) async {
        guard !actionBusy else { return }
        actionBusy = true; defer { actionBusy = false }
        do {
            try await API.shared.postVoid("api/v1/reviews",
                body: OrderReviewBody(orderId: id, rating: rating, text: text.isEmpty ? nil : text))
            Haptics.success(); reviewSent = true; toast = "Спасибо за отзыв!"
        } catch {
            Haptics.error(); toast = (error as? LocalizedError)?.errorDescription ?? "Не удалось отправить отзыв"
        }
    }

    /// NPS (опционально): POST api/v1/orders/{id}/nps {score, comment}. Тело — общий NpsBody.
    func sendNps(score: Int, comment: String) async {
        guard !actionBusy else { return }
        actionBusy = true; defer { actionBusy = false }
        do {
            try await API.shared.postVoid("api/v1/orders/\(id)/nps",
                body: NpsBody(score: score, comment: comment.isEmpty ? nil : comment))
            Haptics.success(); npsSent = true; toast = "Спасибо за оценку!"
        } catch {
            Haptics.error(); toast = (error as? LocalizedError)?.errorDescription ?? "Не удалось отправить оценку"
        }
    }

    /// Живой опрос трекинга (8с) — только пока заказ активен (в пути / готовится).
    func startTrackingIfActive() {
        guard OrderFlow.isActive(order?.status ?? track?.status) else { return }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if let t: TrackData = try? await API.shared.get("api/v1/orders/\(self.id)/track") {
                    self.track = t
                }
            }
        }
    }

    func stopTracking() { pollTimer?.invalidate(); pollTimer = nil }

    /// Повторить заказ: сервер возвращает состав → кладём в корзину (single-store cart).
    func repeatOrder(cart: Cart) async {
        reorderInFlight = true; defer { reorderInFlight = false }
        // GET api/v1/orders/{id}/reorder → ReorderData (как в старом клиенте: Reorder.perform).
        guard let data: ReorderData = try? await API.shared.get("api/v1/orders/\(id)/reorder"),
              let shopId = data.shopId, let items = data.items, !items.isEmpty else {
            // TODO(API): если эндпоинт reorder отсутствует/пуст — деградируем без падения (ниже баннер).
            Haptics.warning(); return
        }
        // Конвертация ReorderItem → CartLine (single-store: одна корзина = один магазин).
        let lines: [CartLine] = items.compactMap { it in
            guard let pid = it.productId else { return nil }
            return CartLine(key: "reorder-\(pid)",
                            productId: pid,
                            name: it.name ?? "Товар",
                            unitPrice: it.price ?? 0,
                            qty: it.qty ?? 1,
                            modifierIds: [],
                            modsLabel: "",
                            photo: it.photo)
        }
        guard !lines.isEmpty else { Haptics.warning(); return }
        cart.setLines(lines, shopId: shopId, shopName: data.shopName, shopSlug: data.shopSlug)
        Haptics.success()
        reorderDone = true
    }
}

// MARK: - OrderDetailView (screen: detail)

struct OrderDetailView: View {
    let id: Int
    /// Открыть чат с заведением по этому заказу.
    var onChat: (Int) -> Void

    @EnvironmentObject private var cart: Cart
    @EnvironmentObject private var router: DeepLinkRouter
    @StateObject private var vm: OrderDetailViewModel

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 55.751, longitude: 37.618),
        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))

    init(id: Int, onChat: @escaping (Int) -> Void) {
        self.id = id
        self.onChat = onChat
        _vm = StateObject(wrappedValue: OrderDetailViewModel(id: id))
    }

    private var courierCoord: CLLocationCoordinate2D? {
        guard let lat = vm.track?.courierLat, let lng = vm.track?.courierLng else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    var body: some View {
        ScrollView {
            if vm.loading && vm.order == nil {
                VStack(spacing: YMSpace.md) {
                    SkeletonBox().frame(height: 200)
                    SkeletonBox().frame(height: 240)
                }
                .padding(YMSpace.xl)
            } else if let o = vm.order {
                VStack(spacing: YMSpace.lg) {
                    if OrderFlow.isActive(o.status), courierCoord != nil {
                        mapCard
                        courierPlate
                    }
                    timelineCard(o)
                    if canPay(o) { payCard(o) }          // онлайн-оплата (неоплаченный online-заказ)
                    itemsCard(o)
                    if canReview(o) {                     // отзыв + NPS (для доставленных)
                        reviewCard(o)
                        npsCard(o)
                    }
                    actionButtons(o)
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.vertical, YMSpace.lg)
            } else {
                emptyBox
            }
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load(); vm.startTrackingIfActive() }
        .onDisappear { vm.stopTracking() }
        .onChange(of: courierCoord?.latitude) { _ in recenter() }
        // Диалог подтверждения отмены заказа.
        .alert("Отменить заказ?", isPresented: $showCancelAlert) {
            Button("Не сейчас", role: .cancel) {}
            Button("Отменить заказ", role: .destructive) { Task { await vm.cancel() } }
        } message: {
            Text("Заказ №\(navNumber) будет отменён. Действие необратимо.")
        }
        // Ссылка YooKassa — открываем во внешнем браузере (SafariView-эквивалент).
        .sheet(item: $vm.payLink) { link in SafariSheet(url: link.url) }
        // Тост-результат действия (отмена / оплата / отзыв / NPS).
        .overlay(alignment: .bottom) { toastOverlay }
    }

    @State private var showCancelAlert = false
    @State private var reviewRating = 5
    @State private var reviewText = ""
    @State private var npsScore = -1

    private var navNumber: String {
        if let n = vm.order?.dailyNumber { return "\(n)" }
        return "\(id)"
    }

    // MARK: Доступность действий по реальным статусам (сверено с OrderFlow/Android)

    /// Отмена: только ранние шаги (new/accepted) — до готовки/доставки; не для done/cancelled.
    private func canCancel(_ o: OrderDetail) -> Bool {
        let n = OrderFlow.normalize(o.status)
        return n == "new" || n == "accepted"
    }

    /// Онлайн-оплата: тип оплаты online, заказ не отменён/не завершён.
    /// В контракте OrderDetail нет payment_status → показываем для активного online-заказа
    /// (сервер повторную оплату оплаченного заказа отклонит; UI аддитивен).
    private func canPay(_ o: OrderDetail) -> Bool {
        let pt = (o.paymentType ?? "").lowercased()
        let isOnline = pt == "online" || pt == "online_card" || pt.contains("card")
        return isOnline && OrderFlow.isActive(o.status)
    }

    /// Отзыв/NPS: только для доставленного заказа.
    private func canReview(_ o: OrderDetail) -> Bool { OrderFlow.isDone(o.status) }

    @ViewBuilder private var toastOverlay: some View {
        if let msg = vm.toast {
            Text(msg)
                .font(YMFont.subhead).foregroundStyle(YMColor.text)
                .padding(.horizontal, YMSpace.lg).padding(.vertical, YMSpace.sm)
                .background(YMColor.surface2, in: Capsule())
                .overlay(Capsule().strokeBorder(YMColor.hairline, lineWidth: 1))
                .padding(.bottom, YMSpace.xxxl)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onAppear {
                    Task { try? await Task.sleep(nanoseconds: 2_200_000_000); await MainActor.run { vm.toast = nil } }
                }
        }
    }

    private var navTitle: String {
        if let n = vm.order?.dailyNumber { return "Заказ №\(n)" }
        return "Заказ №\(id)"
    }

    private func recenter() {
        guard let c = courierCoord else { return }
        // Сглаживание маркера (как в старом TrackView): плавно двигаем центр между опросами.
        withAnimation(.easeInOut(duration: 1.0)) { region.center = c }
    }

    // MARK: Карта с золотым пином курьера

    private var mapCard: some View {
        ZStack {
            Map(coordinateRegion: $region,
                annotationItems: courierCoord.map { [CourierPoint(coordinate: $0)] } ?? []) { p in
                MapAnnotation(coordinate: p.coordinate) {
                    CourierPin()   // золотой пульсирующий пин — единый визуальный язык
                }
            }
            .allowsHitTesting(false)
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
            .strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    // MARK: Плашка курьера

    private var courierPlate: some View {
        HStack(spacing: YMSpace.md) {
            LogoBadge(url: nil,
                      letter: (vm.track?.courierName ?? "К").prefix(1).uppercased(),
                      size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Курьер · \(vm.track?.courierName ?? "в пути")")
                    .font(YMFont.headline).foregroundStyle(YMColor.text)
                HStack(spacing: 6) {
                    StatusDot(color: YMColor.accent, pulsing: true, size: 6)
                    Text(etaLine).font(YMFont.subhead).foregroundStyle(YMColor.accent)
                }
            }
            Spacer(minLength: 8)
            if let phone = vm.track?.courierPhone, !phone.isEmpty {
                Button {
                    Haptics.light()
                    if let url = URL(string: "tel://\(phone.filter { $0.isNumber || $0 == "+" })") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(YMColor.onAccent)
                        .frame(width: 44, height: 44)
                        .background(YMColor.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Позвонить курьеру")
            }
        }
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
    }

    private var etaLine: String {
        let mins = vm.track?.etaMinutes
        let base = OrderStatus.label(vm.track?.status ?? vm.order?.status)
        if let m = mins, m > 0 { return "\(base) · \(m) мин до вас" }
        return base
    }

    // MARK: Таймлайн статусов

    private func timelineCard(_ o: OrderDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Статус заказа")
                .font(YMFont.title3).foregroundStyle(YMColor.text)
                .padding(.bottom, YMSpace.md)

            // Золотая живая лента-резюме над таймлайном (единый язык со списком).
            GoldStatusRibbon(progress: OrderFlow.progress(o.status),
                             pulsing: OrderFlow.isEnRoute(o.status),
                             cancelled: OrderFlow.isCancelled(o.status))
                .padding(.bottom, YMSpace.lg)

            if OrderFlow.isCancelled(o.status) {
                HStack(spacing: YMSpace.sm) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(YMColor.statusCancel)
                    Text("Заказ отменён").font(YMFont.headline).foregroundStyle(YMColor.statusCancel)
                }
            } else {
                let current = OrderFlow.stepIndex(o.status)
                ForEach(Array(OrderFlow.steps.enumerated()), id: \.offset) { idx, key in
                    TimelineRow(
                        title: OrderFlow.stepTitle(key),
                        time: stepTime(idx: idx, current: current, o: o),
                        state: idx < current ? .done : (idx == current ? .active : .todo),
                        isLast: idx == OrderFlow.steps.count - 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
    }

    /// Подпись времени шага: для оформления — реальное createdAt; для активного — «сейчас»;
    /// для будущего — ETA (если есть). Детальных штампов по каждому шагу сервер не отдаёт.
    private func stepTime(idx: Int, current: Int, o: OrderDetail) -> String {
        if idx == 0 { return DateFmt.time(o.createdAt) }
        if idx == current { return "сейчас" }
        if idx == OrderFlow.steps.count - 1, let m = vm.track?.etaMinutes, m > 0, current < idx {
            return "ожидается ~\(m) мин"
        }
        // TODO(API): нет per-step timestamps (status_timeline) — время промежуточных шагов не показываем.
        return ""
    }

    // MARK: Состав + суммы

    private func itemsCard(_ o: OrderDetail) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            Text("Состав").font(YMFont.title3).foregroundStyle(YMColor.text)
                .padding(.bottom, YMSpace.xs)
            ForEach(o.items ?? []) { it in
                HStack(spacing: YMSpace.sm) {
                    Text(qtyLabel(it))
                        .font(.system(size: 14, weight: .heavy)).foregroundStyle(YMColor.accent)
                    Text(it.name ?? "—").font(YMFont.body).foregroundStyle(YMColor.text)
                    Spacer(minLength: 8)
                    Text(Money.format(Money.parse(it.price)))
                        .font(YMFont.body).foregroundStyle(YMColor.muted)
                }
            }
            Divider().overlay(YMColor.hairline).padding(.vertical, YMSpace.xs)
            sumRow("Товары", o.subtotal)
            if let d = o.deliveryPrice, d > 0 { sumRow("Доставка", d) }
            if let f = o.serviceFee, f > 0 { sumRow("Сервисный сбор", f) }
            if let t = o.tip, t > 0 { sumRow("Чаевые курьеру", t) }
            if let d = o.discount, d > 0 {
                sumRow(o.promoCode.map { "Скидка (\($0))" } ?? "Скидка", d, negative: true, green: true)
            }
            if let ps = o.pointsSpent, ps > 0 { sumRow("Оплачено баллами", ps, negative: true, green: true) }
            HStack {
                Text("Итого").font(YMFont.headline).foregroundStyle(YMColor.text)
                Spacer()
                Text(Money.format(Money.parse(o.total)))
                    .font(.system(size: 17, weight: .heavy)).foregroundStyle(YMColor.text)
            }
            .padding(.top, YMSpace.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
    }

    private func qtyLabel(_ it: OrderItem) -> String {
        let q = it.qty ?? 1
        let n = q == q.rounded() ? String(Int(q)) : String(format: "%g", q)
        return "\(n)×"
    }

    private func sumRow(_ title: String, _ value: Double?, negative: Bool = false, green: Bool = false) -> some View {
        HStack {
            Text(title).font(YMFont.callout).foregroundStyle(YMColor.muted)
            Spacer()
            Text((negative ? "−" : "") + Money.format(Money.parse(value)))
                .font(YMFont.callout)
                .foregroundStyle(green ? YMColor.statusDone : YMColor.muted)
        }
    }

    // MARK: Баннер онлайн-оплаты

    private func payCard(_ o: OrderDetail) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            Text("Заказ не оплачен").font(YMFont.headline).foregroundStyle(YMColor.text)
            Text("К оплате: \(Money.format(Money.parse(o.total)))")
                .font(YMFont.callout).foregroundStyle(YMColor.muted)
            Button {
                Task { await vm.payOnline() }
            } label: {
                HStack {
                    if vm.actionBusy { ProgressView().tint(YMColor.onAccent) }
                    else { Label("Оплатить картой", systemImage: "creditcard.fill") }
                }
            }
            .buttonStyle(YMPrimaryButtonStyle())
            .disabled(vm.actionBusy)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
        .overlay(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
            .strokeBorder(YMColor.accent.opacity(0.35), lineWidth: 1))
    }

    // MARK: Блок отзыва (звёзды 1–5 + комментарий)

    private func reviewCard(_ o: OrderDetail) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.md) {
            Text("Оцените заказ").font(YMFont.title3).foregroundStyle(YMColor.text)
            if vm.reviewSent {
                Text("Спасибо за отзыв!").font(YMFont.body).foregroundStyle(YMColor.muted)
            } else {
                HStack(spacing: YMSpace.sm) {
                    ForEach(1...5, id: \.self) { i in
                        Image(systemName: i <= reviewRating ? "star.fill" : "star")
                            .font(.system(size: 28))
                            .foregroundStyle(i <= reviewRating ? YMColor.accent : YMColor.hairline)
                            .onTapGesture { Haptics.light(); reviewRating = i }
                            .accessibilityLabel("\(i) из 5")
                    }
                }
                TextField("Комментарий (необязательно)", text: $reviewText, axis: .vertical)
                    .lineLimit(2...5)
                    .font(YMFont.body).foregroundStyle(YMColor.text)
                    .padding(YMSpace.md)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                        .strokeBorder(YMColor.hairline, lineWidth: 1))
                Button {
                    Task { await vm.sendReview(rating: reviewRating, text: reviewText) }
                } label: {
                    HStack {
                        if vm.actionBusy { ProgressView().tint(YMColor.onAccent) }
                        else { Text("Отправить отзыв") }
                    }
                }
                .buttonStyle(YMPrimaryButtonStyle())
                .disabled(vm.actionBusy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
    }

    // MARK: Блок NPS (0–10, опционально)

    private func npsCard(_ o: OrderDetail) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            Text("Оцените сервис").font(YMFont.title3).foregroundStyle(YMColor.text)
            Text("Насколько вероятно, что порекомендуете нас? (0–10)")
                .font(YMFont.caption).foregroundStyle(YMColor.muted)
            if vm.npsSent {
                Text("Спасибо за оценку!").font(YMFont.body).foregroundStyle(YMColor.muted)
                    .padding(.top, YMSpace.xs)
            } else {
                HStack(spacing: 6) {
                    ForEach(0...10, id: \.self) { i in
                        let on = npsScore == i
                        Text("\(i)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(on ? YMColor.onAccent : YMColor.text)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(on ? YMColor.accent : YMColor.surface2,
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(on ? YMColor.accent : YMColor.hairline, lineWidth: 1))
                            .onTapGesture { Haptics.light(); npsScore = i }
                    }
                }
                .padding(.top, YMSpace.xs)
                Button {
                    Task { await vm.sendNps(score: npsScore, comment: "") }
                } label: {
                    Text("Отправить оценку")
                        .font(YMFont.headline)
                        .foregroundStyle(npsScore >= 0 ? YMColor.accent : YMColor.muted)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                            .strokeBorder(YMColor.accent.opacity(npsScore >= 0 ? 0.5 : 0.2), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .disabled(vm.actionBusy || npsScore < 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
    }

    // MARK: Кнопки действий

    private func actionButtons(_ o: OrderDetail) -> some View {
        VStack(spacing: YMSpace.md) {
            Button {
                Haptics.light(); onChat(id)
            } label: {
                Label("Чат с рестораном", systemImage: "bubble.left.and.bubble.right.fill")
            }
            .buttonStyle(YMPrimaryButtonStyle())

            Button {
                Task {
                    await vm.repeatOrder(cart: cart)
                    if vm.reorderDone { router.requestedTab = 3 }  // открыть таб «Заказы»/корзину
                }
            } label: {
                HStack {
                    if vm.reorderInFlight { ProgressView().tint(YMColor.accent) }
                    else { Label("Повторить заказ", systemImage: "arrow.clockwise") }
                }
                .font(YMFont.headline).foregroundStyle(YMColor.accent)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                    .strokeBorder(YMColor.accent.opacity(0.4), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .disabled(vm.reorderInFlight)

            // «Отменить заказ» — только для ранних статусов, сдержанный красный контур + подтверждение.
            if canCancel(o) {
                Button {
                    Haptics.light(); showCancelAlert = true
                } label: {
                    HStack {
                        if vm.actionBusy { ProgressView().tint(YMColor.statusCancel) }
                        else { Text("Отменить заказ") }
                    }
                    .font(YMFont.headline).foregroundStyle(YMColor.statusCancel)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                        .strokeBorder(YMColor.statusCancel.opacity(0.55), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .disabled(vm.actionBusy)
            }
        }
    }

    private var emptyBox: some View {
        VStack(spacing: YMSpace.md) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40)).foregroundStyle(YMColor.muted)
            Text("Заказ не найден").font(YMFont.title3).foregroundStyle(YMColor.text)
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }
}

// MARK: - TimelineRow (кружки шагов + соединительная линия)

private struct TimelineRow: View {
    enum StepState { case done, active, todo }
    let title: String
    let time: String
    let state: StepState
    let isLast: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .top, spacing: YMSpace.md) {
            VStack(spacing: 0) {
                circle
                if !isLast {
                    Rectangle()
                        .fill(state == .done ? YMColor.accent : YMColor.hairline)
                        .frame(width: 2, height: 34)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: state == .todo ? .regular : .semibold))
                    .foregroundStyle(state == .todo ? YMColor.muted : YMColor.text)
                if !time.isEmpty {
                    Text(time).font(YMFont.caption).foregroundStyle(YMColor.muted)
                }
            }
            .padding(.top, 3)
            Spacer(minLength: 0)
        }
        .onAppear {
            guard state == .active, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    @ViewBuilder private var circle: some View {
        switch state {
        case .done:
            ZStack {
                Circle().fill(YMColor.accent)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy)).foregroundStyle(YMColor.onAccent)
            }
            .frame(width: 26, height: 26)
        case .active:
            ZStack {
                Circle().fill(YMColor.accent.opacity(0.15))
                Circle().strokeBorder(YMColor.accent, lineWidth: 2)
                Circle().fill(YMColor.accent).frame(width: 9, height: 9)
            }
            .frame(width: 26, height: 26)
            .shadow(color: (pulse && !reduceMotion) ? YMPalette.gold.opacity(0.5) : .clear,
                    radius: pulse ? 8 : 0)
            .scaleEffect((pulse && !reduceMotion) ? 1.06 : 1)
        case .todo:
            Circle()
                .fill(YMColor.surface2)
                .overlay(Circle().strokeBorder(YMColor.hairline, lineWidth: 1))
                .frame(width: 26, height: 26)
        }
    }
}

// MARK: - CourierPin (золотой пульсирующий пин курьера)

/// Пин курьера на карте — золотой, с мягко пульсирующим кольцом (тот же язык, что лента/точка).
/// Деградирует при Reduce Motion в статичный пин.
struct CourierPin: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle()
                    .fill(YMPalette.gold.opacity(pulse ? 0 : 0.35))
                    .frame(width: pulse ? 46 : 18, height: pulse ? 46 : 18)
            }
            Circle().fill(YMColor.bg).frame(width: 26, height: 26)
            Circle().fill(YMColor.accent).frame(width: 20, height: 20)
            Image(systemName: "bicycle")
                .font(.system(size: 10, weight: .heavy)).foregroundStyle(YMColor.onAccent)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityLabel("Курьер на карте")
    }
}

// MARK: - SafariSheet (встроенный браузер для оплаты YooKassa)

/// Открывает confirmation_url YooKassa во встроенном SFSafariViewController —
/// пользователь не теряет приложение (как в старом клиенте PayLink).
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let c = SFSafariViewController(url: url)
        c.preferredControlTintColor = UIColor(YMColor.accent)
        return c
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
