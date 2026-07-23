import SwiftUI

// MARK: - HomeViewModel

/// Модель Главной. Тянет данные ровно теми же вызовами/типами, что старый клиент
/// (см. 3 IOS-client HomeView): cities, banners, popular ([CatalogItem]),
/// организации ([Shop]) через /organizations|/shops. Деньги — Decimal (Money).
@MainActor
final class HomeViewModel: ObservableObject {
    @Published var banners: [Banner] = []
    @Published var popular: [CatalogItem] = []      // «Популярное в городе»
    @Published var recommendations: [CatalogItem] = [] // «Рекомендуем вам» (персонально)
    @Published var shops: [Shop] = []               // список организаций
    @Published var kind: OrgKind = .all
    @Published var loading = true
    @Published var error: String?

    private var didInitialLoad = false

    /// OrgKind → серверный typeFilter (как в старом клиенте: all|restaurant|store|service).
    private func typeParam(_ k: OrgKind) -> String {
        switch k {
        case .all:         return "all"
        case .restaurants: return "restaurant"
        case .shops:       return "store"
        case .services:    return "service"
        }
    }

    func firstLoad(session: Session) async {
        guard !didInitialLoad else { return }
        didInitialLoad = true
        await load(session: session)
    }

    /// Полная загрузка (первый вход и pull-to-refresh).
    func load(session: Session) async {
        loading = true; error = nil
        // Города: если город ещё не выбран (нет id) — берём первый как в старом клиенте.
        if session.cityId == nil,
           let cities: [City] = try? await API.shared.list("api/v1/cities"),
           let first = cities.first {
            session.cityId = first.id
            session.cityName = session.cityName ?? first.name
        }
        async let bannersTask: [Banner] = (try? await API.shared.list("api/v1/banners")) ?? []
        banners = await bannersTask
        await loadRecommendations(session: session)
        await loadSections(session: session)
        await loadShops(session: session)
        loading = false
    }

    /// «Рекомендуем вам» — персональные товары: GET api/v1/recommendations?city_id=
    /// -> RecommendationsResp, товары в .popular. Для гостей сервер отдаёт пусто.
    /// Не зависит от чипа-типа (как в Android) — только от города.
    private func loadRecommendations(session: Session) async {
        var q: [String: String] = [:]
        if let cid = session.cityId { q["city_id"] = String(cid) }
        let resp: RecommendationsResp? = try? await API.shared.get("api/v1/recommendations", query: q)
        recommendations = resp?.popular ?? []
    }

    /// Смена типа-чипа: перегружаем только зависящие от типа секции/список.
    func changeKind(_ k: OrgKind, session: Session) async {
        kind = k
        loading = true; error = nil
        await loadSections(session: session)
        await loadShops(session: session)
        loading = false
    }

    // «Популярное в городе» — /api/v1/popular (как в старом клиенте), фильтр по type/city.
    private func loadSections(session: Session) async {
        var q: [String: String] = [:]
        if let cid = session.cityId { q["city_id"] = String(cid) }
        if kind != .all { q["type"] = typeParam(kind) }
        popular = (try? await API.shared.list("api/v1/popular", query: q)) ?? []
    }

    // Список организаций. Рестораны/магазины/услуги → /organizations; «Все» → /shops.
    private func loadShops(session: Session) async {
        do {
            var q: [String: String] = [:]
            if let cid = session.cityId { q["city_id"] = String(cid) }
            switch kind {
            case .all:
                shops = try await API.shared.list("api/v1/shops", query: q)
            case .restaurants:
                q["type"] = "restaurant"
                shops = try await API.shared.list("api/v1/organizations", query: q)
            case .shops:
                q["type"] = "store"
                shops = try await API.shared.list("api/v1/organizations", query: q)
            case .services:
                q["type"] = "service"
                shops = try await API.shared.list("api/v1/organizations", query: q)
            }
        } catch is CancellationError {
            // отмена (быстрый повторный запрос) — молча
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - HomeView

struct HomeView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: DeepLinkRouter
    @StateObject private var vm = HomeViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Локальное состояние избранного (сеть избранного — следующая волна).
    @State private var favShops: Set<Int> = []
    @State private var favPopular: Set<String> = []
    @State private var appeared = false

    // Навигация внутри собственного стека таба (флоу как в Discover/Listing).
    @State private var pushedShop: Shop?
    @State private var pushedProduct: Int?
    // Раздел «Магазины»/«Услуги»/«Рестораны» листингом (там ряд категорий для store/service).
    @State private var pushedListing: (orgType: String, title: String)?

    // Смена города с шапки Главной.
    @State private var showCitySheet = false
    // Профиль открывается из шапки (кнопка в правом углу) — модально.
    @State private var showProfile = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    header
                    // Поиск на Главной — витрина (text=nil), тап через собственный onTap
                    // компонента уводит на вкладку «Поиск» (индекс 1).
                    SearchField(onTap: { Haptics.light(); router.requestedTab = 1 })
                        .padding(.horizontal, YMSpace.xl)
                        .padding(.top, 14)

                    // Сторис-лента (баннеры города). Пусто/ошибка → сама рисует EmptyView.
                    StoriesView(cityId: session.cityId)
                        .padding(.top, 6)

                    ChipRow(selected: $vm.kind) { k in
                        Task { await vm.changeKind(k, session: session) }
                    }
                    .padding(.top, 12)

                    PromoBanner()
                        .padding(.top, 12)

                    if vm.loading {
                        loadingSkeleton
                    } else if let e = vm.error, vm.shops.isEmpty, vm.popular.isEmpty {
                        errorState(e)
                    } else {
                        content
                    }

                    Color.clear.frame(height: 24)
                }
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationBarHidden(true)
            .refreshable { await vm.load(session: session) }
            .task { await vm.firstLoad(session: session) }
            // Город выбирается в онбординге ПОСЛЕ первой загрузки главной (HomeView рендерится
            // под онбордингом). Поэтому при смене cityId (онбординг / шторка города) —
            // перезагружаем данные под новый город, иначе организации не появляются.
            .onChange(of: session.cityId) { _ in
                Task { await vm.load(session: session) }
            }
            // Переходы из карточек: организация → OrgView, популярный товар → ProductView.
            .navigationDestination(isPresented: Binding(
                get: { pushedShop != nil }, set: { if !$0 { pushedShop = nil } }
            )) { if let s = pushedShop { OrgView(shop: s) } }
            .navigationDestination(isPresented: Binding(
                get: { pushedProduct != nil }, set: { if !$0 { pushedProduct = nil } }
            )) { if let id = pushedProduct { ProductView(id: id) } }
            // Раздел «Магазины»/«Услуги»/«Рестораны» листингом (ряд категорий для store/service).
            .navigationDestination(isPresented: Binding(
                get: { pushedListing != nil }, set: { if !$0 { pushedListing = nil } }
            )) {
                if let l = pushedListing {
                    ListingView(orgType: l.orgType, title: l.title, cityId: session.cityId)
                }
            }
            // Смена города с шапки: выбор → Session (id/name) + перезагрузка данных.
            .sheet(isPresented: $showCitySheet) {
                CityPickerSheet(
                    currentId: session.cityId,
                    currentName: session.cityName
                ) { id, name in
                    session.cityName = name
                    session.cityId = id            // смена cityId → onChange выше перезагрузит данные
                    showCitySheet = false
                }
            }
            // Профиль модально (вкладки профиля больше нет — доступ из шапки).
            .sheet(isPresented: $showProfile) {
                ProfileView()
                    .environmentObject(session)
                    .environmentObject(Cart.shared)
                    .environmentObject(DeepLinkRouter.shared)
                    .environmentObject(NavCoordinator.shared)
            }
        }
    }

    // MARK: Header (kicker «ВАШ ГОРОД» + город ▾ + аватар)

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Ваш город".uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(YMColor.accent)
                Button {
                    Haptics.selection()
                    showCitySheet = true   // шторка выбора города
                } label: {
                    HStack(spacing: 5) {
                        Text(session.cityName ?? "Москва")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(YMColor.text)
                        Text("▾")
                            .font(.system(size: 12))
                            .foregroundStyle(YMColor.muted)
                            .offset(y: 1)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            avatar
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, 6)
    }

    // Кнопка профиля в правом углу шапки (профиль убран из нижних вкладок).
    private var avatar: some View {
        Button {
            Haptics.selection()
            showProfile = true
        } label: {
            Image(systemName: "person.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(YMColor.accent)
                .frame(width: 42, height: 42)
                .background(YMColor.surface2, in: Circle())
                .overlay(Circle().strokeBorder(YMColor.accent, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: Content

    private var content: some View {
        VStack(spacing: 0) {
            // «Популярное в городе» — горизонтальная карусель PopularCard.
            if !vm.popular.isEmpty {
                SectionHeader(title: "Популярное в городе", actionTitle: "Все") {
                    router.requestedTab = 1
                }
                .padding(.top, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: YMSpace.md) {
                        ForEach(Array(vm.popular.enumerated()), id: \.element.uid) { idx, item in
                            PopularCard(
                                title: item.name ?? "—",
                                tag: item.category ?? item.shopName,
                                rating: nil,
                                photoURL: API.imageURL(item.photo),
                                tone: idx,
                                isFav: favBinding(popular: item.uid)
                            ) {
                                pushedProduct = item.id   // → карточка товара
                            }
                        }
                    }
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.top, 4)
                }
            }

            // «Рекомендуем вам» — персональные товары (рисуем только если непусто).
            if !vm.recommendations.isEmpty {
                SectionHeader(title: "Рекомендуем вам", actionTitle: nil, action: nil)
                    .padding(.top, 18)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: YMSpace.md) {
                        ForEach(Array(vm.recommendations.enumerated()), id: \.element.uid) { idx, item in
                            PopularCard(
                                title: item.name ?? "—",
                                tag: item.category ?? item.shopName,
                                rating: nil,
                                photoURL: API.imageURL(item.photo),
                                tone: idx,
                                isFav: favBinding(popular: item.uid)
                            ) {
                                pushedProduct = item.id   // → карточка товара
                            }
                        }
                    }
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.top, 4)
                }
            }

            // «Рестораны» / организации — вертикальный список OrgCard.
            if !vm.shops.isEmpty {
                SectionHeader(title: sectionTitle, actionTitle: "Все") {
                    // «Все» → раздел листингом; для «Все» (kind=.all) уводим на Поиск, как раньше.
                    if let type = sectionOrgType {
                        pushedListing = (orgType: type, title: sectionTitle)
                    } else {
                        router.requestedTab = 1
                    }
                }
                .padding(.top, 18)
                LazyVStack(spacing: YMSpace.lg) {
                    ForEach(Array(vm.shops.enumerated()), id: \.element.id) { idx, shop in
                        OrgCard(shop: shop, tone: idx, isFav: favBinding(shop: shop.id)) {
                            pushedShop = shop   // → карточка организации
                        }
                        .opacity(appeared || reduceMotion ? 1 : 0)
                        .offset(y: appeared || reduceMotion ? 0 : 12)
                        .animation(
                            YMMotion.adaptive(YMMotion.spring.delay(Double(idx) * 0.04),
                                              reduceMotion: reduceMotion),
                            value: appeared
                        )
                    }
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.top, 4)
                .onAppear { appeared = true }
            }

            if vm.popular.isEmpty && vm.shops.isEmpty {
                emptyState
            }
        }
    }

    private var sectionTitle: String {
        switch vm.kind {
        case .all, .restaurants: return "Рестораны"
        case .shops:             return "Магазины"
        case .services:          return "Услуги"
        }
    }

    /// orgType раздела для листинга; nil для «Все» (там показываем общий Поиск).
    private var sectionOrgType: String? {
        switch vm.kind {
        case .all:         return nil
        case .restaurants: return "restaurant"
        case .shops:       return "store"
        case .services:    return "service"
        }
    }

    // MARK: States

    private var loadingSkeleton: some View {
        VStack(spacing: YMSpace.lg) {
            // карусель
            HStack(spacing: YMSpace.md) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonBox(radius: YMRadius.card).frame(width: 146, height: 104)
                        SkeletonBox().frame(width: 110, height: 12)
                        SkeletonBox().frame(width: 70, height: 10)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // крупные карточки
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonBox(radius: YMRadius.card).frame(height: 150)
                    SkeletonBox().frame(width: 160, height: 16)
                    SkeletonBox().frame(width: 200, height: 12)
                }
            }
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, 20)
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
            Button("Повторить") { Task { await vm.load(session: session) } }
                .buttonStyle(YMSecondaryButtonStyle())
                .frame(maxWidth: 200)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl)
        .padding(.top, 60)
    }

    private var emptyState: some View {
        VStack(spacing: YMSpace.sm) {
            Text("Пока пусто")
                .font(YMFont.title3)
                .foregroundStyle(YMColor.text)
            Text("В вашем городе для выбранного раздела пока нет заведений.")
                .font(YMFont.callout)
                .foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl)
        .padding(.top, 50)
    }

    // MARK: Fav bindings (локально)

    private func favBinding(shop id: Int) -> Binding<Bool> {
        Binding(get: { favShops.contains(id) },
                set: { if $0 { favShops.insert(id) } else { favShops.remove(id) } })
    }
    private func favBinding(popular uid: String) -> Binding<Bool> {
        Binding(get: { favPopular.contains(uid) },
                set: { if $0 { favPopular.insert(uid) } else { favPopular.remove(uid) } })
    }
}

// MARK: - CityPickerSheet (смена города с Главной)

/// Шторка выбора города: GET api/v1/cities -> [City]. Поиск по названию,
/// текущий город подсвечен золотом + галочкой. Пусто/ошибка → показываем хотя бы
/// текущий город, чтобы список никогда не был пустым (паритет с Android CityPickerSheet).
private struct CityPickerSheet: View {
    let currentId: Int?
    let currentName: String?
    var onPick: (Int, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cities: [City] = []
    @State private var query = ""
    @State private var loading = true

    // Fallback: если сервер пуст/ошибка — хотя бы текущий город.
    private var source: [City] {
        if !cities.isEmpty { return cities }
        if let name = currentName, !name.isEmpty {
            return [City(id: currentId ?? 0, name: name, region: nil)]
        }
        return []
    }
    private var filtered: [City] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return source }
        return source.filter { ($0.name ?? "").range(of: q, options: .caseInsensitive) != nil }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: YMSpace.md) {
                TextField("Поиск города", text: $query)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, YMSpace.lg)
                    .padding(.vertical, 12)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                        .strokeBorder(YMColor.hairline, lineWidth: 1))
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.top, YMSpace.md)

                if loading {
                    VStack(spacing: YMSpace.sm) {
                        ForEach(0..<6, id: \.self) { _ in
                            SkeletonBox(radius: YMRadius.control).frame(height: 54)
                        }
                    }
                    .padding(.horizontal, YMSpace.xl)
                } else if filtered.isEmpty {
                    Text("Город не найден")
                        .font(YMFont.callout)
                        .foregroundStyle(YMColor.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    ScrollView {
                        LazyVStack(spacing: YMSpace.sm) {
                            ForEach(filtered) { city in
                                cityRow(city)
                            }
                        }
                        .padding(.horizontal, YMSpace.xl)
                        .padding(.bottom, YMSpace.xl)
                    }
                }
                Spacer(minLength: 0)
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle("Выбор города")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                        .foregroundStyle(YMColor.accent)
                }
            }
            .task { await loadCities() }
        }
    }

    private func cityRow(_ city: City) -> some View {
        let name = city.name ?? "—"
        let selected: Bool = {
            if let id = currentId { return id == city.id }
            return name.caseInsensitiveCompare(currentName ?? "") == .orderedSame
        }()
        return Button {
            Haptics.selection()
            onPick(city.id, name)
        } label: {
            HStack {
                Text(name)
                    .font(.system(size: 16, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? YMColor.accent : YMColor.text)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(YMColor.accent)
                }
            }
            .padding(.horizontal, YMSpace.lg)
            .padding(.vertical, 14)
            .background(selected ? YMColor.accent.opacity(0.10) : YMColor.surface2,
                        in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                .strokeBorder(selected ? YMColor.accent.opacity(0.5) : YMColor.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func loadCities() async {
        let list: [City] = (try? await API.shared.list("api/v1/cities")) ?? []
        cities = list
        loading = false
    }
}
