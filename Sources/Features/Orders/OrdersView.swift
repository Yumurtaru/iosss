import SwiftUI

//  OrdersView.swift
//  Yumurta — premium iOS-клиент. Экран 6 (list) — точка входа таба «Заказы».
//
//  Init-сигнатура: OrdersView(onOpen: (Int) -> Void)
//    onOpen(orderId) — открыть деталь заказа (навигацию решает вызывающая сторона).
//
//  Данные 1:1 со старым клиентом (3 IOS-client OrdersView):
//    GET api/v1/orders → [Order]  (id, dailyNumber, status, total:Double?, createdAt, shopName, shopLogo).
//  Деньги — Double? в модели → Money.format(Money.parse(x)) (Decimal, канон нового клиента).
//
//  Signature-элемент: «золотая живая лента статуса» — GoldStatusRibbon (прогресс + мягкий пульс),
//  сквозной визуальный язык через список / таймлайн / шапку чата / пин курьера.

// MARK: - Общая машина статусов заказа (единый источник для списка, детали и таймлайна)

/// Каноническая машина статусов: new → accepted → preparing → ready → in_delivery → done; cancelled.
/// Сервер отдаёт разные синонимы — нормализуем в один из 6 шагов (+ cancelled).
enum OrderFlow {
    /// Упорядоченные шаги «нормального» пути (без cancelled).
    static let steps: [String] = ["new", "accepted", "preparing", "ready", "in_delivery", "done"]

    /// Заголовки шагов для таймлайна.
    static func stepTitle(_ key: String) -> String {
        switch key {
        case "new":         return "Заказ оформлен"
        case "accepted":    return "Заведение приняло заказ"
        case "preparing":   return "Готовится"
        case "ready":       return "Готов к выдаче"
        case "in_delivery": return "Курьер в пути"
        case "done":        return "Доставлен"
        default:            return OrderStatus.label(key)
        }
    }

    /// Нормализация сырого статуса сервера в индекс шага (0…5). -1 = неизвестно.
    static func stepIndex(_ raw: String?) -> Int {
        switch normalize(raw) {
        case "new":         return 0
        case "accepted":    return 1
        case "preparing":   return 2
        case "ready":       return 3
        case "in_delivery": return 4
        case "done":        return 5
        default:            return -1
        }
    }

    /// Сведение синонимов сервера к канону машины.
    static func normalize(_ raw: String?) -> String {
        switch (raw ?? "").lowercased() {
        case "new", "pending", "created":                 return "new"
        case "accepted", "confirmed":                     return "accepted"
        case "preparing", "cooking", "processing":        return "preparing"
        case "ready", "cooked", "ready_for_pickup":       return "ready"
        case "in_delivery", "delivering", "on_the_way",
             "en_route", "shipping":                      return "in_delivery"
        case "done", "delivered", "completed", "finished":return "done"
        case "cancelled", "canceled", "rejected":         return "cancelled"
        default:                                          return (raw ?? "").lowercased()
        }
    }

    static func isCancelled(_ raw: String?) -> Bool { normalize(raw) == "cancelled" }
    static func isDone(_ raw: String?) -> Bool { normalize(raw) == "done" }
    static func isEnRoute(_ raw: String?) -> Bool { normalize(raw) == "in_delivery" }
    static func isActive(_ raw: String?) -> Bool { !isDone(raw) && !isCancelled(raw) }

    /// Прогресс 0…1 по машине (для золотой ленты).
    static func progress(_ raw: String?) -> Double {
        if isCancelled(raw) { return 1 }
        let i = stepIndex(raw)
        guard i >= 0 else { return 0.05 }
        return Double(i) / Double(steps.count - 1)
    }

    /// Семантический цвет статуса (light+dark из токенов).
    static func color(_ raw: String?) -> Color {
        if isCancelled(raw) { return YMColor.statusCancel }
        if isDone(raw)      { return YMColor.statusDone }
        if isEnRoute(raw)   { return YMColor.statusEnRoute } // золото
        return YMColor.statusPending
    }

    /// StatusPill.Kind по статусу.
    static func pillKind(_ raw: String?) -> StatusPill.Kind {
        if isCancelled(raw) { return .cancel }
        if isDone(raw)      { return .done }
        if isEnRoute(raw)   { return .enRoute }
        return .pending
    }
}

// MARK: - GoldStatusRibbon (signature: золотая живая лента статуса)

/// Золотой прогресс-бар с мягким пульсом — сквозной сигнатурный элемент.
/// progress 0…1. Пульс мягко «дышит» на активной части (у статуса «В пути»),
/// деградирует при Reduce Motion (статичная золотая заливка без свечения).
struct GoldStatusRibbon: View {
    var progress: Double
    /// Пульсировать ли (обычно только для активных «в пути» заказов).
    var pulsing: Bool = false
    var height: CGFloat = 6
    var cancelled: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    private var clamped: Double { min(max(progress, 0), 1) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                // Дорожка
                Capsule().fill(YMColor.surface2)
                // Золотая заливка (градиент для «премиального» блеска)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: cancelled
                                ? [YMColor.statusCancel, YMColor.statusCancel]
                                : [YMPalette.goldBright, YMPalette.gold, YMPalette.goldDeep],
                            startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: max(w * clamped, height))
                    // Мягкое золотое свечение-пульс на активной ленте.
                    .shadow(color: (pulsing && !cancelled && !reduceMotion)
                            ? YMPalette.gold.opacity(breathe ? 0.55 : 0.15) : .clear,
                            radius: breathe ? 10 : 4)
                    .opacity((pulsing && !reduceMotion) ? (breathe ? 1 : 0.82) : 1)
            }
        }
        .frame(height: height)
        .onAppear {
            guard pulsing, !cancelled, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
        .accessibilityHidden(true)
    }
}

/// Цветная точка статуса с мягким пульсирующим кольцом (пульс — у «В пути»).
/// Деградирует при Reduce Motion в статичную точку.
struct StatusDot: View {
    var color: Color
    var pulsing: Bool = false
    var size: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ring = false

    var body: some View {
        ZStack {
            if pulsing && !reduceMotion {
                Circle()
                    .stroke(color.opacity(ring ? 0 : 0.5), lineWidth: 2)
                    .frame(width: size + (ring ? 12 : 0), height: size + (ring ? 12 : 0))
            }
            Circle().fill(color).frame(width: size, height: size)
        }
        .frame(width: size + 12, height: size + 12)
        .onAppear {
            guard pulsing, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { ring = true }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - OrdersViewModel

@MainActor
final class OrdersViewModel: ObservableObject {
    @Published var orders: [Order] = []
    @Published var loading = true
    @Published var loadFailed = false
    private var didLoad = false

    /// Первый вход в таб — грузим со скелетоном. Возврат в таб (в т.ч. после
    /// оформления заказа) — тихо обновляем список, чтобы новый заказ появился
    /// в «Активных» без pull-to-refresh. Скелетон при этом не мигает: он
    /// показывается только когда orders пуст (см. content).
    func firstLoad() async {
        if !didLoad { didLoad = true }
        await load()
    }

    func load() async {
        loading = true; loadFailed = false
        do {
            orders = try await API.shared.list("api/v1/orders")
        } catch {
            loadFailed = true
        }
        loading = false
    }

    var active: [Order]  { orders.filter { OrderFlow.isActive($0.status) } }
    var history: [Order] { orders.filter { !OrderFlow.isActive($0.status) } }
}

// MARK: - OrdersView (screen: list)

struct OrdersView: View {
    /// Открыть деталь заказа по id.
    let onOpen: (Int) -> Void

    @EnvironmentObject private var session: Session
    @EnvironmentObject private var coord: NavCoordinator
    @StateObject private var vm = OrdersViewModel()
    @State private var tab: Tab = .active
    // Деталь заказа пушится внутри собственного стека таба (self-contained).
    @State private var pushedOrder: Int?

    enum Tab: Hashable { case active, history }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: YMSpace.md) {
                    // Табы Активные / История
                    YMSegmented(options: [Tab.active, Tab.history], selection: $tab) {
                        $0 == .active ? "Активные" : "История"
                    }
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.top, YMSpace.xs)

                    content
                }
                .padding(.bottom, YMSpace.xxxl)
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle("Заказы")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await vm.load() }
            .task { if session.isLoggedIn { await vm.firstLoad() } }
            .onChange(of: session.isLoggedIn) { logged in if logged { Task { await vm.load() } } }
            // Деталь заказа → чат уходит в глобальный координатор.
            .navigationDestination(isPresented: Binding(
                get: { pushedOrder != nil },
                set: { if !$0 { pushedOrder = nil } }
            )) {
                if let id = pushedOrder {
                    OrderDetailView(id: id, onChat: { orderId in coord.openChat(orderId: orderId) })
                }
            }
        }
        // «Следить за заказом» из флоу корзины: RootTabView переключил таб,
        // здесь ПЕРЕЗАГРУЖАЕМ список (новый заказ должен появиться в «Активных»),
        // открываем деталь и сбрасываем сигнал.
        .onChange(of: coord.pendingOrderDetail) { pending in
            if let id = pending {
                tab = .active            // новый заказ активен — показываем нужный таб
                pushedOrder = id
                coord.pendingOrderDetail = nil
                Task { await vm.load() } // всегда свежий список после оформления
            }
        }
    }

    /// Открыть деталь заказа (внутренний пуш + внешний колбэк для совместимости).
    private func openDetail(_ id: Int) {
        pushedOrder = id
        onOpen(id)
    }

    @ViewBuilder private var content: some View {
        if !session.isLoggedIn {
            emptyState(icon: "person.crop.circle.badge.questionmark",
                       title: "Войдите в аккаунт",
                       hint: "Чтобы видеть свои заказы и статусы доставки.")
        } else if vm.loading && vm.orders.isEmpty {
            VStack(spacing: YMSpace.md) {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonBox(radius: YMRadius.card).frame(height: 128)
                }
            }
            .padding(.horizontal, YMSpace.xl)
        } else {
            let list = tab == .active ? vm.active : vm.history
            if list.isEmpty {
                emptyState(icon: tab == .active ? "bag" : "clock.arrow.circlepath",
                           title: tab == .active ? "Активных заказов нет" : "История пуста",
                           hint: tab == .active
                                ? "Оформите заказ — здесь появится живой статус доставки."
                                : "Завершённые заказы будут храниться здесь.")
            } else {
                ForEach(list) { order in
                    OrderCard(order: order) { openDetail(order.id) }
                        .padding(.horizontal, YMSpace.xl)
                }
            }
        }
    }

    private func emptyState(icon: String, title: String, hint: String) -> some View {
        VStack(spacing: YMSpace.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                    .fill(YMColor.surface2).frame(width: 96, height: 96)
                Image(systemName: icon)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(YMColor.accent)
            }
            Text(title).font(YMFont.title3).foregroundStyle(YMColor.text)
            Text(hint)
                .font(YMFont.callout).foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, YMSpace.xxxl)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
    }
}

// MARK: - OrderCard

/// Карточка заказа: лого, название, №, состав·сумма, строка статуса с цветной точкой
/// (пульс у «В пути») + ETA, и золотая живая лента прогресса.
private struct OrderCard: View {
    let order: Order
    var onTap: () -> Void

    private var money: String { Money.format(Money.parse(order.total)) }
    private var number: String { "№\(order.dailyNumber ?? order.id)" }
    private var enRoute: Bool { OrderFlow.isEnRoute(order.status) }
    private var cancelled: Bool { OrderFlow.isCancelled(order.status) }

    /// Подпись справа в строке статуса.
    /// Для отменённых/доставленных — их статус; иначе — реальная дата/время заказа
    /// из created_at в формате «DD.MM, HH:mm» (паритет с Android formatOrderWhen).
    private var etaText: String {
        if cancelled { return "отменён" }
        if OrderFlow.isDone(order.status) { return "доставлен" }
        return Self.formatOrderWhen(order.createdAt)
    }

    /// «2026-07-03 16:00:00» / ISO → «03.07, 16:00». Разбор текстом (без зависимости от локали
    /// парсера) — как в Android: если не удалось — показываем строку как есть.
    static func formatOrderWhen(_ createdAt: String?) -> String {
        guard let s = createdAt, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        let time = s.range(of: #"\d{2}:\d{2}"#, options: .regularExpression).map { String(s[$0]) }
        var day: String?
        if let r = s.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            let parts = s[r].split(separator: "-")          // [yyyy, MM, dd]
            if parts.count == 3 { day = "\(parts[2]).\(parts[1])" }
        }
        let joined = [day, time].compactMap { $0 }.joined(separator: ", ")
        return joined.isEmpty ? s.trimmingCharacters(in: .whitespaces) : joined
    }

    var body: some View {
        Button(action: { Haptics.light(); onTap() }) {
            VStack(alignment: .leading, spacing: YMSpace.md) {
                // ── Верх: лого + название/№ + сумма ──
                HStack(spacing: YMSpace.md) {
                    LogoBadge(url: API.imageURL(order.shopLogo),
                              letter: (order.shopName ?? "?").prefix(1).uppercased(),
                              size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(order.shopName ?? "Заказ")
                            .font(YMFont.headline).foregroundStyle(YMColor.text).lineLimit(1)
                        Text(number)
                            .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    }
                    Spacer(minLength: 8)
                    Text(money).font(.system(size: 16, weight: .heavy)).foregroundStyle(YMColor.text)
                }

                // ── Строка статуса: точка (пульс у «В пути») + текст + ETA ──
                HStack(spacing: YMSpace.sm) {
                    StatusDot(color: OrderFlow.color(order.status), pulsing: enRoute)
                    Text(OrderStatus.label(order.status))
                        .font(YMFont.subhead)
                        .foregroundStyle(OrderFlow.color(order.status))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(etaText).font(YMFont.caption).foregroundStyle(YMColor.muted)
                }

                // ── Золотая живая лента статуса ──
                GoldStatusRibbon(progress: OrderFlow.progress(order.status),
                                 pulsing: enRoute,
                                 cancelled: cancelled)
            }
            .padding(YMSpace.lg)
        }
        .buttonStyle(CardPressStyle())
        .ymCard(radius: YMRadius.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(order.shopName ?? "Заказ") \(number), \(OrderStatus.label(order.status)), \(money)")
    }
}

// MARK: - LogoBadge (общий: круглый логотип заведения / буква-заглушка)

/// Круглый логотип заведения: реальное фото через AsyncImage, иначе буква на золотом фоне.
struct LogoBadge: View {
    var url: URL?
    var letter: String
    var size: CGFloat = 46

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [YMPalette.goldBright, YMPalette.goldDeep],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(letter)
                .font(.system(size: size * 0.42, weight: .heavy))
                .foregroundStyle(YMPalette.goldInk)
            if let url {
                AsyncImage(url: url) { phase in
                    if case let .success(img) = phase { img.resizable().scaledToFill() }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(YMColor.hairline, lineWidth: 1))
    }
}
