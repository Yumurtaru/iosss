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

    func load() async {
        loading = true; error = nil
        switch screen {
        case .category:
            do {
                var q: [String: String] = [:]
                if let cid = cityId { q["city_id"] = String(cid) }
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

    /// Локальная сортировка/фильтрация организаций (клиентская — сервер сортировку по этим ключам не отдаёт).
    var sortedOrgs: [Shop] {
        var list = orgs
        if activeFilters.contains("Открыто") { list = list.filter { $0.isOpen ?? true } }
        if activeFilters.contains("4.5+") { list = list.filter { ($0.rating ?? 0) >= 4.5 } }
        // TODO(API): «Бесплатная доставка» и «Ближе/Быстрее» требуют полей deliveryFee/lat в списке — их нет.
        switch sort {
        case .rating:   list.sort { ($0.rating ?? 0) > ($1.rating ?? 0) }
        case .nearest:  break   // TODO(API): нет дистанции в списке организаций.
        case .fastest:  break   // TODO(API): нет числового времени доставки в списке.
        case .cheapest: break   // TODO(API): нет цены/чека в списке организаций.
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

struct ListingView: View {
    @StateObject private var vm: ListingViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showSort = false
    @State private var pushedShop: Shop?
    @State private var pushedProduct: Int?

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
            await vm.load()
        }
        .sheet(isPresented: $showSort) {
            SortSheet(selection: $vm.sort)
                .presentationDetents([.height(360)])
                .presentationDragIndicator(.visible)
        }
        .navigationDestination(isPresented: Binding(
            get: { pushedShop != nil }, set: { if !$0 { pushedShop = nil } }
        )) { if let s = pushedShop { OrgView(shop: s) } }
        .navigationDestination(isPresented: Binding(
            get: { pushedProduct != nil }, set: { if !$0 { pushedProduct = nil } }
        )) { if let id = pushedProduct { ProductView(id: id) } }
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
                    ForEach(vm.sortedOrgs) { shop in
                        OrgListRow(shop: shop) {
                            Haptics.light()
                            pushedShop = shop
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
                            pushedProduct = p.id
                        } onAdd: {
                            pushedProduct = p.id
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
                        // TODO(API): цена доставки и расстояние в списке организаций отсутствуют.
                        Text("· Доставка уточняется")
                            .font(.system(size: 11.5))
                            .foregroundStyle(YMColor.muted)
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

    init(selection: Binding<ListingSort>) {
        _selection = selection
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
                ForEach(Array(ListingSort.allCases.enumerated()), id: \.element.id) { i, opt in
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
                    if i < ListingSort.allCases.count - 1 {
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
