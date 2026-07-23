//
//  DiscoverView.swift — Поиск / Категории / Избранное (premium-клиент)
//
//  Три раздела «Обзора» из макета DiscoverPhone (search | categories | favorites).
//  Строго на дизайн-токенах (YMColor/YMFont/YMSpace/YMRadius), light + dark,
//  Dynamic Type, Reduce Motion. ♥ — пружина + Haptics.
//
//  ТОЧКИ ВХОДА (для навигации / RootTabView):
//    • DiscoverView(mode: .search)      — таб «Поиск»
//    • DiscoverView(mode: .categories)  — раздел «Категории»
//    • DiscoverView(mode: .favorites)   — таб «Избранное»
//  Алиасы для читаемости точек входа табов:
//    • SearchScreen()      == DiscoverView(mode: .search)
//    • CategoriesScreen()  == DiscoverView(mode: .categories)
//    • FavoritesScreen()   == DiscoverView(mode: .favorites)
//
//  ПРИВЯЗКА К API (как в старом Search/Profile):
//    • Поиск:        GET  api/v1/search/smart?q=&price_min=&price_max=&rating=&sort=  → {shops, products}
//    • Категории:    GET  api/v1/org-categories/with-counts?type=store|service|restaurant → [OrgCategory]
//    • Избранное:    GET  api/v1/favorites → [Shop]  ·  GET api/v1/product-favorites → [Product]
//    • Toggle fav:   POST/DELETE api/v1/favorites/{id}  ·  POST/DELETE api/v1/product-favorites/{id}
//  Локальная история/недавние — SearchHistoryStore / RecentStore.
//

import SwiftUI

enum DiscoverMode { case search, categories, favorites }

// MARK: - Точки входа-алиасы (читаемость в RootTabView / навигации)

struct SearchScreen: View { var body: some View { DiscoverView(mode: .search) } }
struct CategoriesScreen: View { var body: some View { DiscoverView(mode: .categories) } }
struct FavoritesScreen: View { var body: some View { DiscoverView(mode: .favorites) } }

// MARK: - DiscoverView

struct DiscoverView: View {
    let mode: DiscoverMode
    init(mode: DiscoverMode) { self.mode = mode }

    var body: some View {
        switch mode {
        case .search:     SearchSection()
        case .categories: CategoriesSection()
        case .favorites:  FavoritesSection()
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ПОИСК
// ─────────────────────────────────────────────────────────────────────────────

/// Ответ /search/smart (как в старом клиенте): {shops, products}.
private struct SearchSmartResult: Decodable { let shops: [Shop]?; let products: [Product]? }

private struct SearchSection: View {
    @EnvironmentObject private var session: Session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    @State private var q = ""
    @State private var shops: [Shop] = []
    @State private var products: [Product] = []
    @State private var loading = false
    @State private var searchTask: Task<Void, Never>?
    @State private var history: [String] = SearchHistoryStore.load()
    @State private var recent: [RecentProduct] = RecentStore.load()

    // Локальные избранные (оптимистично; toggle синхронизируется с сервером).
    @State private var favShops: Set<Int> = []
    @State private var favProducts: Set<Int> = []

    // Навигация внутри своего NavigationStack (флоу как в OrgView/ListingView).
    @State private var pushedShop: Shop?
    @State private var pushedProduct: Int?

    private var trimmed: String { q.trimmingCharacters(in: .whitespaces) }
    private var showResults: Bool { !shops.isEmpty || !products.isEmpty }
    private var showSuggestState: Bool { trimmed.count < 2 }

    // Живые подсказки из истории + недавних (совпадение выделяется жирным).
    private var suggestions: [String] {
        guard trimmed.count >= 1 else { return [] }
        let ql = trimmed.lowercased()
        var pool = history
        pool.append(contentsOf: recent.map { $0.name })
        var seen = Set<String>(); var out: [String] = []
        for s in pool where s.lowercased().contains(ql) {
            let key = s.lowercased()
            if seen.insert(key).inserted { out.append(s) }
            if out.count >= 6 { break }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !suggestions.isEmpty {
                            suggestionsBlock
                        } else if showSuggestState {
                            recentAndPopularBlock
                        }
                        if showResults { resultsBlock }
                        else if loading { loadingBlock }
                        else if !showSuggestState && trimmed.count >= 2 {
                            emptyResults
                        }
                    }
                    .padding(.top, YMSpace.sm)
                    .padding(.bottom, YMSpace.xxxl)
                }
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationBarHidden(true)
            .navigationDestination(isPresented: Binding(
                get: { pushedShop != nil }, set: { if !$0 { pushedShop = nil } }
            )) { if let s = pushedShop { OrgView(shop: s) } }
            .navigationDestination(isPresented: Binding(
                get: { pushedProduct != nil }, set: { if !$0 { pushedProduct = nil } }
            )) { if let id = pushedProduct { ProductView(id: id) } }
        }
        .task { await loadFavIds() }
        .onChange(of: q) { _ in scheduleSearch() }
    }

    // ── Поле ввода с золотой рамкой + «Отмена» ──
    private var searchBar: some View {
        HStack(spacing: YMSpace.md) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(focused ? YMColor.accent : YMColor.muted)
                TextField("Рестораны, товары, услуги…", text: $q)
                    .font(YMFont.body)
                    .foregroundStyle(YMColor.text)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                    .onSubmit { recordHistory() }
                if !q.isEmpty {
                    Button { q = ""; clearResults() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(YMColor.muted)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 15)
            .frame(height: 46)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                    .strokeBorder(focused ? YMColor.accent : YMColor.hairline, lineWidth: focused ? 1.5 : 1)
            )
            if focused || !q.isEmpty {
                Button("Отмена") {
                    q = ""; clearResults(); focused = false
                }
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(YMColor.accent)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.sm)
        .padding(.bottom, YMSpace.md)
        .animation(YMMotion.adaptive(YMMotion.snappy, reduceMotion: reduceMotion), value: focused)
    }

    // ── Подсказки (совпадение выделено) ──
    private var suggestionsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionKicker("Подсказки")
            ForEach(suggestions, id: \.self) { s in
                Button {
                    q = s; focused = false; recordHistory()
                } label: {
                    HStack(spacing: YMSpace.md) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundStyle(YMColor.muted)
                        highlighted(s)
                            .font(.system(size: 14.5))
                            .foregroundStyle(YMColor.text)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(YMColor.muted)
                    }
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // ── Недавние + недавно смотрели ──
    private var recentAndPopularBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !history.isEmpty {
                HStack {
                    sectionKicker("Недавние запросы")
                    Spacer()
                    Button("Очистить") { SearchHistoryStore.clear(); history = [] }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(YMColor.accent)
                        .padding(.trailing, YMSpace.xl)
                }
                FlowChips(items: history) { term in q = term; recordHistory() }
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.bottom, YMSpace.md)
            }
            if !recent.isEmpty {
                sectionKicker("Недавно смотрели")
                ForEach(recent) { r in
                    Button { pushedProduct = r.id } label: {
                        HStack(spacing: YMSpace.md) {
                            PhotoPlaceholder(url: API.imageURL(r.photo), label: "ФОТО", radius: 12, tone: r.id)
                                .frame(width: 44, height: 44)
                            Text(r.name).font(YMFont.body).foregroundStyle(YMColor.text).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(Money.format(Money.parse(r.price)))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(YMColor.muted)
                        }
                        .padding(.horizontal, YMSpace.xl)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // ── Результаты: Товары (горизонтально) + Организации (строки со ★) ──
    private var resultsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !products.isEmpty {
                sectionKicker("Результаты · Товары")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: YMSpace.md) {
                        ForEach(Array(products.enumerated()), id: \.element.id) { idx, p in
                            productResultCard(p, tone: idx)
                        }
                    }
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.vertical, YMSpace.sm)
                }
            }
            if !shops.isEmpty {
                sectionKicker("Организации")
                ForEach(Array(shops.enumerated()), id: \.element.id) { idx, s in
                    orgResultRow(s, tone: idx)
                }
            }
        }
    }

    private func productResultCard(_ p: Product, tone: Int) -> some View {
        Button { pushedProduct = p.id } label: {
            VStack(alignment: .leading, spacing: 7) {
                PhotoPlaceholder(url: API.imageURL(p.photo), label: "ФОТО", radius: 16, tone: tone)
                    .frame(width: 150, height: 96)
                    .overlay(alignment: .topTrailing) {
                        HeartButton(isFav: favProduct(p.id), size: 26, favColor: YMColor.statusCancel).padding(6)
                    }
                Text(p.name ?? "—")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(YMColor.text).lineLimit(1)
                Text(Money.format(Money.parse(p.price)))
                    .font(.system(size: 12))
                    .foregroundStyle(YMColor.muted)
            }
            .frame(width: 150, alignment: .leading)
        }
        .buttonStyle(CardPressStyle())
    }

    private func orgResultRow(_ s: Shop, tone: Int) -> some View {
        Button { pushedShop = s } label: {
            HStack(spacing: YMSpace.md) {
                PhotoPlaceholder(url: API.imageURL(s.logo ?? s.cover), label: "ЛОГО", radius: 12, tone: tone)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name ?? "—").font(.system(size: 14, weight: .bold)).foregroundStyle(YMColor.text).lineLimit(1)
                    if let cat = s.category, !cat.isEmpty {
                        Text(cat).font(.system(size: 12)).foregroundStyle(YMColor.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let r = s.rating, r > 0 {
                    HStack(spacing: 4) {
                        Text("★").foregroundStyle(YMColor.accent)
                        Text(String(format: "%.1f", r)).foregroundStyle(YMColor.text)
                    }
                    .font(.system(size: 13, weight: .bold))
                }
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var loadingBlock: some View {
        VStack(spacing: YMSpace.md) {
            ForEach(0..<4, id: \.self) { _ in
                SkeletonBox().frame(height: 56)
            }
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.md)
    }

    private var emptyResults: some View {
        VStack(spacing: YMSpace.sm) {
            Text("Ничего не найдено").font(YMFont.title3).foregroundStyle(YMColor.text)
            Text("Попробуйте изменить запрос.").font(YMFont.callout).foregroundStyle(YMColor.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // ── helpers ──
    private func sectionKicker(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 12, weight: .heavy)).tracking(0.6)
            .foregroundStyle(YMColor.muted)
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.md).padding(.bottom, YMSpace.sm)
    }

    /// Текст с выделенным вхождением запроса (bold).
    private func highlighted(_ s: String) -> Text {
        let ql = trimmed.lowercased()
        guard !ql.isEmpty, let r = s.lowercased().range(of: ql) else { return Text(s) }
        let start = s.distance(from: s.startIndex, to: r.lowerBound)
        let idxLo = s.index(s.startIndex, offsetBy: start)
        let idxHi = s.index(idxLo, offsetBy: ql.count)
        let pre = String(s[s.startIndex..<idxLo])
        let mid = String(s[idxLo..<idxHi])
        let post = String(s[idxHi..<s.endIndex])
        return Text(pre) + Text(mid).fontWeight(.heavy) + Text(post)
    }

    private func favProduct(_ id: Int) -> Binding<Bool> {
        Binding(get: { favProducts.contains(id) }, set: { on in
            if on { favProducts.insert(id) } else { favProducts.remove(id) }
            Task { await toggleProductFav(id, on: on) }
        })
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = trimmed
        guard query.count >= 2 else { clearResults(); return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await runSearch(query)
        }
    }

    private func runSearch(_ query: String) async {
        loading = true
        var params: [String: String] = ["q": query]
        if let cid = session.cityId { params["city_id"] = String(cid) }   // глобально по городу
        do {
            let r: SearchSmartResult = try await API.shared.get("api/v1/search/smart", query: params)
            shops = r.shops ?? []; products = r.products ?? []
        } catch { shops = []; products = [] }
        loading = false
    }

    private func recordHistory() {
        let query = trimmed
        guard query.count >= 2 else { return }
        SearchHistoryStore.add(query)
        history = SearchHistoryStore.load()
        scheduleSearch()
    }

    private func clearResults() { shops = []; products = []; loading = false }

    private func loadFavIds() async {
        if let ids: [Int] = try? await API.shared.list("api/v1/product-favorites/ids") {
            favProducts = Set(ids)
        }
        if let favs: [Shop] = try? await API.shared.list("api/v1/favorites") {
            favShops = Set(favs.map { $0.id })
        }
    }

    private func toggleProductFav(_ id: Int, on: Bool) async {
        do {
            if on { try await API.shared.postVoid("api/v1/product-favorites/\(id)") }
            else  { try await API.shared.deleteVoid("api/v1/product-favorites/\(id)") }
        } catch {
            // откат при ошибке
            await MainActor.run { if on { favProducts.remove(id) } else { favProducts.insert(id) } }
        }
    }
}

/// Пилюли-чипы истории (перенос строк).
private struct FlowChips: View {
    let items: [String]
    var onTap: (String) -> Void
    var body: some View {
        // ScrollView горизонтально — простой и предсказуемый layout под Dynamic Type.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: YMSpace.sm) {
                ForEach(items, id: \.self) { term in
                    Button { onTap(term) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath").font(.system(size: 11))
                            Text(term).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        }
                        .foregroundStyle(YMColor.text)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous)
                            .strokeBorder(YMColor.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - КАТЕГОРИИ
// ─────────────────────────────────────────────────────────────────────────────

private enum CatTab: String, CaseIterable, Hashable {
    case shops, services, food
    var title: String { self == .shops ? "Магазины" : self == .services ? "Услуги" : "Еда" }
    /// type-параметр сервера org-categories/with-counts.
    var apiType: String { self == .shops ? "store" : self == .services ? "service" : "restaurant" }
}

private struct CategoriesSection: View {
    @EnvironmentObject private var session: Session
    @State private var tab: CatTab = .shops
    @State private var cats: [OrgCategory] = []
    @State private var loading = true
    @State private var pushedShop: Shop?
    // Листинг организаций выбранной категории (orgType + заголовок).
    @State private var pushedListing: (orgType: String, title: String)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Категории")
                        .font(.system(size: 28, weight: .heavy)).tracking(-0.6)
                        .foregroundStyle(YMColor.text)
                        .padding(.horizontal, YMSpace.xl)
                        .padding(.top, YMSpace.sm).padding(.bottom, YMSpace.md)

                    YMSegmented(options: CatTab.allCases, selection: $tab) { $0.title }
                        .padding(.horizontal, YMSpace.xl)
                        .padding(.bottom, YMSpace.lg)

                    if loading {
                        grid(count: 6) { SkeletonBox(radius: 18).frame(height: 104) }
                    } else if cats.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: YMSpace.md),
                                            GridItem(.flexible(), spacing: YMSpace.md)],
                                  spacing: YMSpace.md) {
                            ForEach(Array(cats.enumerated()), id: \.element.id) { idx, cat in
                                CategoryTile(category: cat, tone: idx) {
                                    Haptics.selection()
                                    pushedListing = (orgType: tab.apiType,
                                                     title: cat.name ?? tab.title)
                                }
                            }
                        }
                        .padding(.horizontal, YMSpace.xl)
                    }
                }
                .padding(.bottom, YMSpace.xxxl)
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationBarHidden(true)
            .navigationDestination(isPresented: Binding(
                get: { pushedListing != nil }, set: { if !$0 { pushedListing = nil } }
            )) {
                if let l = pushedListing {
                    ListingView(orgType: l.orgType, title: l.title, cityId: session.cityId)
                }
            }
        }
        .task { await load() }
        .onChange(of: tab) { _ in Task { await load() } }
    }

    @ViewBuilder private func grid<Content: View>(count: Int, @ViewBuilder _ cell: @escaping () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: YMSpace.md),
                            GridItem(.flexible(), spacing: YMSpace.md)], spacing: YMSpace.md) {
            ForEach(0..<count, id: \.self) { _ in cell() }
        }
        .padding(.horizontal, YMSpace.xl)
    }

    private var emptyState: some View {
        VStack(spacing: YMSpace.sm) {
            Text("Категорий пока нет").font(YMFont.title3).foregroundStyle(YMColor.text)
            Text("В этом разделе для вашего города пока пусто.")
                .font(YMFont.callout).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl).padding(.top, 50)
    }

    private func load() async {
        loading = true
        var q: [String: String] = ["type": tab.apiType]
        if let cid = session.cityId { q["city_id"] = String(cid) }
        cats = (try? await API.shared.list("api/v1/org-categories/with-counts", query: q)) ?? []
        loading = false
    }
}

/// Плитка категории 104pt: эмодзи/иконка, название, счётчик.
private struct CategoryTile: View {
    let category: OrgCategory
    var tone: Int = 0
    var onTap: () -> Void = {}

    // Счётчик «128 магазинов» с корректным склонением.
    private var countLine: String? {
        guard let n = category.count, n > 0 else { return nil }
        return "\(n) \(plural(n))"
    }
    private func plural(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return "магазин" }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return "магазина" }
        return "магазинов"
    }

    var body: some View {
        Button(action: { Haptics.light(); onTap() }) {
            VStack(alignment: .leading, spacing: 0) {
                Text(category.icon?.isEmpty == false ? category.icon! : "🏷️")
                    .font(.system(size: 26))
                Spacer(minLength: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.name ?? "—")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(YMColor.text).lineLimit(1)
                    if let c = countLine {
                        Text(c).font(.system(size: 11.5)).foregroundStyle(YMColor.muted).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 104)
            .padding(14)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(YMColor.hairline, lineWidth: 1))
        }
        .buttonStyle(CardPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel([category.name, countLine].compactMap { $0 }.joined(separator: ", "))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ИЗБРАННОЕ
// ─────────────────────────────────────────────────────────────────────────────

private enum FavTab: String, CaseIterable, Hashable {
    case orgs, products
    var title: String { self == .orgs ? "Организации" : "Товары" }
}

private struct FavoritesSection: View {
    @State private var tab: FavTab = .orgs
    @State private var shops: [Shop] = []
    @State private var products: [Product] = []
    @State private var loading = true
    @State private var favShops: Set<Int> = []
    @State private var favProducts: Set<Int> = []
    @State private var pushedShop: Shop?
    @State private var pushedProduct: Int?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Избранное")
                        .font(.system(size: 28, weight: .heavy)).tracking(-0.6)
                        .foregroundStyle(YMColor.text)
                        .padding(.horizontal, YMSpace.xl)
                        .padding(.top, YMSpace.sm).padding(.bottom, YMSpace.md)

                    YMSegmented(options: FavTab.allCases, selection: $tab) { $0.title }
                        .padding(.horizontal, YMSpace.xl)
                        .padding(.bottom, YMSpace.lg)

                    if loading {
                        VStack(spacing: YMSpace.lg) {
                            ForEach(0..<3, id: \.self) { _ in SkeletonBox(radius: 20).frame(height: 178) }
                        }
                        .padding(.horizontal, YMSpace.xl)
                    } else if tab == .orgs {
                        if shops.isEmpty { empty("Нет избранных организаций") }
                        else {
                            VStack(spacing: YMSpace.lg) {
                                ForEach(Array(shops.enumerated()), id: \.element.id) { idx, s in
                                    FavOrgCard(shop: s, tone: idx, isFav: favShop(s.id)) { pushedShop = s }
                                }
                            }
                            .padding(.horizontal, YMSpace.xl)
                        }
                    } else {
                        if products.isEmpty { empty("Нет избранных товаров") }
                        else {
                            VStack(spacing: YMSpace.lg) {
                                ForEach(Array(products.enumerated()), id: \.element.id) { idx, p in
                                    FavProductCard(product: p, tone: idx, isFav: favProduct(p.id)) { pushedProduct = p.id }
                                }
                            }
                            .padding(.horizontal, YMSpace.xl)
                        }
                    }
                }
                .padding(.bottom, YMSpace.xxxl)
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationBarHidden(true)
            .navigationDestination(isPresented: Binding(
                get: { pushedShop != nil }, set: { if !$0 { pushedShop = nil } }
            )) { if let s = pushedShop { OrgView(shop: s) } }
            .navigationDestination(isPresented: Binding(
                get: { pushedProduct != nil }, set: { if !$0 { pushedProduct = nil } }
            )) { if let id = pushedProduct { ProductView(id: id) } }
        }
        .task { await load() }
    }

    private func empty(_ title: String) -> some View {
        VStack(spacing: YMSpace.sm) {
            Text("💔").font(.system(size: 44))
            Text(title).font(YMFont.title3).foregroundStyle(YMColor.text)
            Text("Добавляйте организации и товары тапом по ♥.")
                .font(YMFont.callout).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl).padding(.top, 40)
    }

    private func favShop(_ id: Int) -> Binding<Bool> {
        Binding(get: { favShops.contains(id) }, set: { on in
            if on { favShops.insert(id) } else { favShops.remove(id) }
            Task { await toggleShopFav(id, on: on) }
        })
    }
    private func favProduct(_ id: Int) -> Binding<Bool> {
        Binding(get: { favProducts.contains(id) }, set: { on in
            if on { favProducts.insert(id) } else { favProducts.remove(id) }
            Task { await toggleProductFav(id, on: on) }
        })
    }

    private func load() async {
        loading = true
        shops = (try? await API.shared.list("api/v1/favorites")) ?? []
        products = (try? await API.shared.list("api/v1/product-favorites")) ?? []
        favShops = Set(shops.map { $0.id })
        favProducts = Set(products.map { $0.id })
        loading = false
    }
    private func toggleShopFav(_ id: Int, on: Bool) async {
        do {
            if on { try await API.shared.postVoid("api/v1/favorites/\(id)") }
            else  { try await API.shared.deleteVoid("api/v1/favorites/\(id)") }
        } catch { await MainActor.run { if on { favShops.remove(id) } else { favShops.insert(id) } } }
    }
    private func toggleProductFav(_ id: Int, on: Bool) async {
        do {
            if on { try await API.shared.postVoid("api/v1/product-favorites/\(id)") }
            else  { try await API.shared.deleteVoid("api/v1/product-favorites/\(id)") }
        } catch { await MainActor.run { if on { favProducts.remove(id) } else { favProducts.insert(id) } } }
    }
}

/// Карточка избранной организации: фото 120pt, ♥ (золото), бейдж статуса, ★.
private struct FavOrgCard: View {
    let shop: Shop
    var tone: Int = 0
    @Binding var isFav: Bool
    var onTap: () -> Void = {}

    private var isOpen: Bool { shop.isOpen ?? true }

    var body: some View {
        Button(action: { Haptics.light(); onTap() }) {
            VStack(alignment: .leading, spacing: 0) {
                PhotoPlaceholder(url: API.imageURL(shop.cover ?? shop.banner ?? shop.logo),
                                 label: "ОБЛОЖКА", radius: 0, tone: tone)
                    .frame(height: 120).frame(maxWidth: .infinity).clipped()
                    .opacity(isOpen ? 1 : 0.55)   // закрытую приглушаем
                    .overlay(alignment: .topLeading) {
                        StatusPill(text: isOpen ? "Открыто" : "Закрыто",
                                   kind: isOpen ? .open : .cancel, solid: true).padding(11)
                    }
                    .overlay(alignment: .topTrailing) {
                        HeartButton(isFav: $isFav, size: 34, favColor: YMColor.statusCancel).padding(11)
                    }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(shop.name ?? "—")
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundStyle(YMColor.text).lineLimit(1)
                        Spacer(minLength: 8)
                        if let r = shop.rating, r > 0 {
                            HStack(spacing: 4) {
                                Text("★").foregroundStyle(YMColor.accent)
                                Text(String(format: "%.1f", r)).foregroundStyle(YMColor.text)
                            }
                            .font(.system(size: 13.5, weight: .bold))
                        }
                    }
                    HStack(spacing: 6) {
                        if let cat = shop.category, !cat.isEmpty {
                            Text(cat).font(.system(size: 13)).foregroundStyle(YMColor.muted).lineLimit(1)
                        }
                        if let t = shop.deliveryTime, !t.isEmpty {
                            Circle().fill(YMColor.muted).frame(width: 3, height: 3)
                            Text(t).font(.system(size: 13)).foregroundStyle(YMColor.muted)
                        }
                    }
                }
                .padding(.horizontal, 15).padding(.top, 12).padding(.bottom, 14)
                .opacity(isOpen ? 1 : 0.55)   // текст закрытой организации тоже тусклый
            }
        }
        .buttonStyle(CardPressStyle())
        .ymCard(radius: 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(shop.name ?? "Организация"), \(isOpen ? "открыто" : "закрыто")")
    }
}

/// Карточка избранного товара: фото 120pt, ♥, цена золотом.
private struct FavProductCard: View {
    let product: Product
    var tone: Int = 0
    @Binding var isFav: Bool
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: { Haptics.light(); onTap() }) {
            VStack(alignment: .leading, spacing: 0) {
                PhotoPlaceholder(url: API.imageURL(product.photo), label: "ФОТО", radius: 0, tone: tone)
                    .frame(height: 120).frame(maxWidth: .infinity).clipped()
                    .overlay(alignment: .topTrailing) {
                        HeartButton(isFav: $isFav, size: 34, favColor: YMColor.statusCancel).padding(11)
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.name ?? "—")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(YMColor.text).lineLimit(1)
                    HStack(spacing: 8) {
                        Text(Money.format(Money.parse(product.price)))
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(YMColor.accent)
                        if let old = product.oldPrice, old > (product.price ?? 0) {
                            Text(Money.format(Money.parse(old)))
                                .font(.system(size: 12))
                                .strikethrough()
                                .foregroundStyle(YMColor.muted)
                        }
                    }
                }
                .padding(.horizontal, 15).padding(.top, 12).padding(.bottom, 14)
            }
        }
        .buttonStyle(CardPressStyle())
        .ymCard(radius: 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(product.name ?? "Товар")
    }
}
