import SwiftUI

//
//  ListingView.swift — листинги: категория организаций / товары магазина / сортировка.
//  Дизайн 1:1 с ListingPhone.dc.html (screen = category | shop | sort).
//
//  ПУБЛИЧНЫЕ INIT-СИГНАТУРЫ (для централизованной навигации):
//    ListingView(orgType: String, title: String, cityId: Int?)
//        // screen "category": список организаций по типу (restaurant|store|service|all)
//    ListingView(shop: Shop)
//        // screen "shop": 2-в-ряд сетка товаров магазина
//
//  screen "sort" — bottom-sheet, показывается внутри как модалка (SortSheet).
//
//  API (реальные методы старого клиента):
//    GET  api/v1/organizations?type=&city_id=   -> [Shop]   (список по типу)
//    GET  api/v1/shops                          -> [Shop]   (все)
//    GET  api/v1/shops/{slug}/products          -> [Product](товары магазина)
//
//  Внутренние переходы (организация → OrgView, товар → ProductView) — локально.
//  Деньги — Decimal через Money. Токены — YM*.
//

// MARK: - Sort options

enum ListingSort: String, CaseIterable, Identifiable {
    case rating   = "По рейтингу"
    case nearest  = "Ближе ко мне"
    case fastest  = "Быстрее доставка"
    case cheapest = "Сначала недорогие"
    var id: String { rawValue }
    /// Значение параметра sort для сервера: он сортирует ВСЮ выборку, а не одну
    /// загруженную страницу.
    var apiValue: String {
        switch self {
        case .rating:   return "rating"
        case .nearest:  return "distance"
        case .fastest:  return "cook_time"
        case .cheapest: return "price"
        }
    }
    var icon: String {
        switch self {
        case .rating:   return "star.fill"
        case .nearest:  return "location.fill"
        case .fastest:  return "bolt.fill"
        case .cheapest: return "rublesign"
        }
    }
}

// MARK: - ViewModel

@MainActor
final class ListingViewModel: ObservableObject {
    enum Screen { case category, shop }

    @Published var orgs: [Shop] = []
    @Published var products: [Product] = []
    @Published var loading = true
    @Published var error: String?
    @Published var sort: ListingSort = .rating
    // Фильтры-чипы: индекс → активность (по набору для контекста).
    @Published var activeFilters: Set<String> = []

    // Категории раздела (Магазины/Услуги). Ряд-чипов + выбранная категория (nil = «Все»).
    @Published var categories: [OrgCategory] = []
    @Published var pickedCategoryId: Int?

    /// Координаты для «Ближе ко мне» — из АДРЕСА ДОСТАВКИ, не из GPS: разрешение
    /// на геолокацию приложение не просит, да и человеку важно, что ближе к его
    /// дому. Нет адреса — пункт сортировки не показываем, чтобы он не
    /// притворялся рабочим.
    @Published var geo: (lat: Double, lng: Double)?
    var hasGeo: Bool { geo != nil }
    /// Пункты сортировки, доступные прямо сейчас.
    var sortOptions: [ListingSort] { ListingSort.allCases.filter { $0 != .nearest || hasGeo } }

    let screen: Screen
    let orgType: String        // restaurant | store | service | all
    let cityId: Int?
    let shop: Shop?
    let title: String

    /// Показывать ряд категорий: только раздел организаций типа store/service
    /// (сервер org-categories/with-counts отдаёт данные лишь для них).
    var showCategoryRow: Bool {
        screen == .category && (orgType == "store" || orgType == "service")
    }

    init(orgType: String, title: String, cityId: Int?) {
        screen = .category; self.orgType = orgType; self.cityId = cityId
        self.shop = nil; self.title = title
    }
    init(shop: Shop) {
        screen = .shop; self.shop = shop; orgType = "store"; cityId = nil
        self.title = shop.name ?? "Магазин"
    }

    /// Фильтры-чипы по контексту.
    var filterChips: [String] {
        screen == .shop ? ["Скидки", "Халяль", "Новинки"] : ["Открыто", "Бесплатная доставка", "4.5+"]
    }

    /// Категории раздела (грузим один раз при входе, только для store/service).
    func loadCategories() async {
        guard showCategoryRow else { return }
        var q: [String: String] = ["type": orgType]
        if let cid = cityId { q["city_id"] = String(cid) }
        categories = (try? await API.shared.list("api/v1/org-categories/with-counts", query: q)) ?? []
    }

    /// Выбор категории в ряду (nil = «Все») → перезагрузка списка организаций.
    func pickCategory(_ id: Int?) async {
        guard pickedCategoryId != id else { return }
        pickedCategoryId = id
        await load()
    }

    /// Подтянуть координаты адреса доставки (один раз за сессию экрана).
    func loadGeo() async {
        guard screen == .category, geo == nil, Session.shared.isLoggedIn else { return }
        let list: [Address] = (try? await API.shared.list("api/v1/profile/addresses")) ?? []
        let pick = list.first { $0.isDefaultBool && $0.lat != nil && $0.lng != nil }
            ?? list.first { $0.lat != nil && $0.lng != nil }
        if let a = pick, let la = a.lat, let ln = a.lng { geo = (la, ln) }
    }

    func load() async {
        loading = true; error = nil
        switch screen {
        case .category:
            do {
                var q: [String: String] = [:]
                if let cid = cityId { q["city_id"] = String(cid) }
                // Фильтры и сортировку считает СЕРВЕР — иначе они применялись бы
                // только к загруженной странице. Локальный проход в sortedOrgs
                // оставлен: он совпадает с серверным и спасает на старом сервере.
                q["sort"] = sort.apiValue
                if let g = geo { q["lat"] = String(g.lat); q["lng"] = String(g.lng) }
                if activeFilters.contains("Открыто") { q["open"] = "1" }
                if activeFilters.contains("Бесплатная доставка") { q["free_delivery"] = "1" }
                if orgType == "all" {
                    orgs = try await API.shared.list("api/v1/shops", query: q)
                } else {
                    q["type"] = orgType
                    if let catId = pickedCategoryId { q["category_id"] = String(catId) }
                    orgs = try await API.shared.list("api/v1/organizations", query: q)
                }
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        case .shop:
            guard let slug = shop?.slug else { error = "Нет данных магазина"; loading = false; return }
            do {
                products = try await API.shared.list("api/v1/shops/\(slug)/products")
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
        }
        loading = false
    }

    /// Тот же фильтр и та же сортировка, что уже применил сервер. Проход
    /// оставлен намеренно: на старом сервере без is_open / free_delivery /
    /// avg_check / distance_km он просто ничего не отбрасывает.
    var sortedOrgs: [Shop] {
        var list = orgs
        if activeFilters.contains("Открыто") { list = list.filter { $0.isOpen ?? true } }
        if activeFilters.contains("4.5+") { list = list.filter { ($0.rating ?? 0) >= 4.5 } }
        // nil = поля нет (старый сервер) → заведение не отбрасываем.
        if activeFilters.contains("Бесплатная доставка") { list = list.filter { $0.freeDelivery ?? true } }
        switch sort {
        case .rating:   list.sort { ($0.rating ?? 0) > ($1.rating ?? 0) }
        // Без координат и без среднего чека — в конец списка, а не в начало.
        case .nearest:  list.sort { ($0.distanceKm ?? .greatestFiniteMagnitude) < ($1.distanceKm ?? .greatestFiniteMagnitude) }
        case .fastest:  list.sort { ($0.avgCookTime ?? Int.max) < ($1.avgCookTime ?? Int.max) }
        case .cheapest: list.sort { ($0.avgCheck ?? .greatestFiniteMagnitude) < ($1.avgCheck ?? .greatestFiniteMagnitude) }
        }
        return list
    }

    var filteredProducts: [Product] {
        var list = products
        if activeFilters.contains("Халяль") { list = list.filter { $0.isHalal == true } }
        if activeFilters.contains("Скидки") { list = list.filter { ($0.oldPrice ?? 0) > ($0.price ?? 0) } }
        // TODO(API): «Новинки» требует поля created_at/isNew в Product — его нет.
        if sort == .cheapest { list.sort { ($0.price ?? 0) < ($1.price ?? 0) } }
        return list
    }
}

// MARK: - ListingView

/// Куда уводит экран листинга: карточка организации или карточка товара.
/// Один enum вместо двух @State — см. комментарий у route ниже.
private enum ListingRoute {
    case shop(Shop)
    case product(Int)
}

struct ListingView: View {
    @StateObject private var vm: ListingViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showSort = false
    // ОДНО состояние перехода на экран. Пока их было два (организация и товар),
    // закрытие гасило только одно: второе оставалось заполненным после «назад»,
    // и следующая же перерисовка (смена режима списка, сортировка, обновление)
    // снова открывала прошлый экран — причём не тот, на который нажали.
    @State private var route: ListingRoute?
    @State private var showBecomeSeller = false

    init(orgType: String, title: String, cityId: Int?) {
        _vm = StateObject(wrappedValue: ListingViewModel(orgType: orgType, title: title, cityId: cityId))
    }
    init(shop: Shop) {
        _vm = StateObject(wrappedValue: ListingViewModel(shop: shop))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if vm.showCategoryRow && !vm.categories.isEmpty {
                categoryRow
            }
            filterRow
            if vm.loading {
                loadingState
            } else if let e = vm.error, isEmpty {
                errorState(e)
            } else {
                listBody
            }
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationBarHidden(true)
        .task {
            await vm.loadCategories()
            // Координаты адреса доставки — до первой загрузки, чтобы сервер сразу
            // вернул distance_km и сортировка «Ближе ко мне» работала с первого раза.
            await vm.loadGeo()
            await vm.load()
        }
        // Смена сортировки и набора фильтров — это НОВЫЙ запрос к серверу:
        // он применяет их ко всей выборке, а не к загруженной странице.
        .onChange(of: vm.sort) { _ in Task { await vm.load() } }
        .onChange(of: vm.activeFilters) { _ in Task { await vm.load() } }
        .sheet(isPresented: $showSort) {
            SortSheet(selection: $vm.sort, options: vm.sortOptions)
                .presentationDetents([.height(360)])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showBecomeSeller) {
            NavigationStack { BecomeSellerView() }
        }
        // ОДИН destination на одно состояние route: гасить нечего, кроме него,
        // поэтому «хвоста» от прошлого перехода не остаётся.
        // (Свой NavigationStack этот экран не создаёт — он сам открыт внутри
        // стека вкладки, поэтому здесь isPresented, а не path.)
        .navigationDestination(isPresented: Binding(
            get: { route != nil }, set: { if !$0 { route = nil } }
        )) {
            switch route {
            case .shop(let s):     OrgView(shop: s)
            case .product(let id): ProductView(id: id)
            case .none:            EmptyView()
            }
        }
    }

    private var isEmpty: Bool {
        vm.screen == .category ? vm.orgs.isEmpty : vm.products.isEmpty
    }

    // MARK: Header (‹ title/subtitle)

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button { Haptics.light(); dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(YMColor.text)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.title)
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(YMColor.text)
                    .lineLimit(1)
                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 12))
                        .foregroundStyle(YMColor.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, YMSpace.lg)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var subtitle: String? {
        if vm.screen == .shop {
            return [vm.shop?.category, vm.shop?.address].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        let n = vm.orgs.count
        return n > 0 ? "\(n) \(orgWord(n))" : nil
    }

    private func orgWord(_ n: Int) -> String {
        let n1 = n % 10, n2 = n % 100
        if n2 >= 11 && n2 <= 14 { return "заведений" }
        if n1 == 1 { return "заведение" }
        if n1 >= 2 && n1 <= 4 { return "заведения" }
        return "заведений"
    }

    // MARK: Category row (раздел Магазины/Услуги → фильтр по категории)

    private var categoryRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // «Все» — сброс категории.
                Chip(label: "Все", active: vm.pickedCategoryId == nil) {
                    Haptics.selection()
                    Task { await vm.pickCategory(nil) }
                }
                ForEach(vm.categories) { cat in
                    Chip(label: cat.name ?? "—", active: vm.pickedCategoryId == cat.id) {
                        Haptics.selection()
                        Task { await vm.pickCategory(cat.id) }
                    }
                }
            }
            .padding(.horizontal, YMSpace.xl)
        }
        .padding(.bottom, 12)
    }

    // MARK: Filter + sort row

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Кнопка сортировки → bottom-sheet.
                Button { Haptics.selection(); showSort = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 12, weight: .bold))
                        Text(vm.sort.rawValue)
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(YMColor.text)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous)
                        .strokeBorder(YMColor.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)

                // Фильтры-чипы.
                ForEach(vm.filterChips, id: \.self) { chip in
                    let active = vm.activeFilters.contains(chip)
                    Chip(label: chip, active: active) {
                        Haptics.selection()
                        if active { vm.activeFilters.remove(chip) } else { vm.activeFilters.insert(chip) }
                    }
                }
            }
            .padding(.horizontal, YMSpace.xl)
        }
        .padding(.bottom, 12)
    }

    // MARK: Body

    @ViewBuilder private var listBody: some View {
        if vm.screen == .category {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(Array(vm.sortedOrgs.enumerated()), id: \.element.id) { idx, shop in
                        OrgListRow(shop: shop) {
                            Haptics.light()
                            route = .shop(shop)
                        }
                        // Промо-карточка «Стать продавцом» после каждых 3 заведений.
                        if (idx + 1) % 3 == 0 {
                            BecomeSellerPromoCard { showBecomeSeller = true }
                        }
                    }
                    if vm.sortedOrgs.isEmpty { emptyState }
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.bottom, 24)
            }
        } else {
            // shop: 2-в-ряд сетка товаров.
            ScrollView {
                let cols = Array(repeating: GridItem(.flexible(), spacing: 12), count: 2)
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(vm.filteredProducts) { p in
                        ProductGridCard(product: p) {
                            Haptics.light()
                            route = .product(p.id)
                        } onAdd: {
                            route = .product(p.id)
                        }
                    }
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.bottom, 24)
                if vm.filteredProducts.isEmpty { emptyState }
            }
        }
    }

    // MARK: States

    private var loadingState: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(0..<5, id: \.self) { _ in
                    SkeletonBox(radius: YMRadius.card).frame(height: 96)
                }
            }
            .padding(.horizontal, YMSpace.xl)
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: YMSpace.md) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(YMColor.muted)
            Text(message)
                .font(YMFont.callout)
                .foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
            Button("Повторить") { Task { await vm.load() } }
                .buttonStyle(YMSecondaryButtonStyle())
                .frame(maxWidth: 200)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, YMSpace.xxxl)
    }

    private var emptyState: some View {
        VStack(spacing: YMSpace.sm) {
            Text("Ничего не найдено")
                .font(YMFont.title3)
                .foregroundStyle(YMColor.text)
            Text("Попробуйте изменить фильтры.")
                .font(YMFont.callout)
                .foregroundStyle(YMColor.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
}

// MARK: - OrgListRow (строка организации в листинге)

/// Строка организации: фото 76, статус, доставка, расстояние.
struct OrgListRow: View {
    let shop: Shop
    var onTap: () -> Void = {}

    private var isOpen: Bool { shop.isOpen ?? true }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomLeading) {
                    PhotoPlaceholder(url: API.imageURL(shop.cover ?? shop.banner ?? shop.logo),
                                     label: "ФОТО", radius: YMRadius.control, tone: shop.id)
                        .frame(width: 76, height: 76)
                    if let t = shop.deliveryTime, !t.isEmpty {
                        Text(t)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.black.opacity(0.55), in: Capsule())
                            .padding(6)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(shop.name ?? "—")
                            .font(.system(size: 15.5, weight: .heavy))
                            .foregroundStyle(YMColor.text)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if let r = shop.rating, r > 0 {
                            HStack(spacing: 4) {
                                Text("★").foregroundStyle(YMColor.accent)
                                Text(String(format: "%.1f", r)).foregroundStyle(YMColor.text)
                            }
                            .font(.system(size: 13, weight: .bold))
                        }
                    }
                    if let cat = shop.category, !cat.isEmpty {
                        Text(cat)
                            .font(.system(size: 12.5))
                            .foregroundStyle(YMColor.muted)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Text(isOpen ? "Открыто" : "Закрыто")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(isOpen ? YMColor.statusDone : YMColor.statusCancel)
                        // Способы получения — готовой строкой с сервера.
                        if let fulfillment = shop.fulfillmentLabel, !fulfillment.isEmpty {
                            Text("· \(fulfillment)")
                                .font(.system(size: 11.5))
                                .foregroundStyle(YMColor.muted)
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .opacity(isOpen ? 1 : 0.55)   // закрытую организацию приглушаем (кроме статуса)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                .strokeBorder(YMColor.hairline, lineWidth: 1))
        }
        .buttonStyle(CardPressStyle())
    }
}

// MARK: - ProductGridCard (2-в-ряд товар магазина)

/// Карточка товара для сетки магазина: фото, цена, ХАЛЯЛЬ, золотой «+».
struct ProductGridCard: View {
    let product: Product
    var onTap: () -> Void = {}
    var onAdd: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    PhotoPlaceholder(url: API.imageURL(product.photo),
                                     label: "ФОТО", radius: YMRadius.card, tone: product.id)
                        .frame(height: 120)
                        .frame(maxWidth: .infinity)
                    if product.isHalal == true {
                        HalalBadge().padding(8)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(product.name ?? "—")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(YMColor.text)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let unit = product.unit, !unit.isEmpty {
                        Text(unit)
                            .font(.system(size: 11.5))
                            .foregroundStyle(YMColor.muted)
                            .lineLimit(1)
                    }
                }
                HStack {
                    Text(Money.format(Money.dec(product.price)))
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(YMColor.text)
                    Spacer()
                    Button {
                        Haptics.light()
                        onAdd()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundStyle(YMColor.onAccent)
                            .frame(width: 30, height: 30)
                            .background(YMColor.accent, in: Circle())
                            .shadow(color: YMPalette.gold.opacity(0.5), radius: 8, y: 2)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                .strokeBorder(YMColor.hairline, lineWidth: 1))
        }
        .buttonStyle(CardPressStyle())
    }
}

// MARK: - SortSheet (bottom-sheet сортировки)

/// Bottom-sheet «Сортировка»: выбранный — золотой ✓, кнопка «Применить».
struct SortSheet: View {
    @Binding var selection: ListingSort
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ListingSort

    /// Доступные пункты: «Ближе ко мне» появляется только когда есть адрес
    /// доставки, от которого считать расстояние.
    let options: [ListingSort]

    init(selection: Binding<ListingSort>, options: [ListingSort] = ListingSort.allCases) {
        _selection = selection
        self.options = options
        _draft = State(initialValue: selection.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Сортировка")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(YMColor.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 20)
                .padding(.horizontal, YMSpace.xl)

            VStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element.id) { i, opt in
                    Button {
                        Haptics.selection()
                        draft = opt
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: opt.icon)
                                .font(.system(size: 15))
                                .foregroundStyle(draft == opt ? YMColor.accent : YMColor.muted)
                                .frame(width: 24)
                            Text(opt.rawValue)
                                .font(.system(size: 15, weight: draft == opt ? .heavy : .semibold))
                                .foregroundStyle(YMColor.text)
                            Spacer()
                            if draft == opt {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .heavy))
                                    .foregroundStyle(YMColor.accent)
                            }
                        }
                        .padding(.vertical, 15)
                        .padding(.horizontal, YMSpace.xl)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if i < options.count - 1 {
                        Divider().overlay(YMColor.hairline).padding(.horizontal, YMSpace.xl)
                    }
                }
            }
            .padding(.top, 8)

            Button {
                Haptics.medium()
                selection = draft
                dismiss()
            } label: {
                Text("Применить")
            }
            .buttonStyle(YMPrimaryButtonStyle())
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, 12)

            Spacer(minLength: 8)
        }
        .background(YMColor.bg.ignoresSafeArea())
    }
}
