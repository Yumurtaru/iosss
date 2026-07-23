import SwiftUI
import MapKit

//
//  OrgView.swift — карточка организации (магазин / услуга).
//  Блок: Организация + Товар/Услуга + Листинги. Дизайн 1:1 с OrgPhone.dc.html.
//
//  ПУБЛИЧНЫЕ INIT-СИГНАТУРЫ (для централизованной навигации):
//    OrgView(shop: Shop)             // из списка/карточки — есть базовые данные для hero
//    OrgView(shopSlug: String)       // из deep-link — грузим ShopDetail по slug
//
//  Экран самодостаточен: внутренний переход организация → товар/услуга
//  реализован локально через NavigationLink (флоу живёт внутри своего NavigationStack,
//  если экран открыт как корень; при пуше извне переиспользует внешний стек).
//
//  API (реальные методы старого клиента):
//    GET  api/v1/shops/{slug}            -> ShopDetail
//    GET  api/v1/shops/{slug}/products   -> [Product]
//    GET  api/v1/shops/{slug}/services   -> ServicesResponse (masters/services)
//
//  Деньги — только Decimal через Money. Мини-карта — MapKit. Токены — YM*.
//

// MARK: - ViewModel

@MainActor
final class OrgViewModel: ObservableObject {
    @Published var detail: ShopDetail?
    @Published var products: [Product] = []
    @Published var services: [ServiceItem] = []
    /// Категории товаров магазина (для меню-табов и фильтра) — грузятся отдельным
    /// запросом по shopId, как на Android (Repo.categories(shopId)). НЕ путать с
    /// detail.categories (категории-теги организации).
    @Published var productCategories: [Category] = []
    @Published var loading = true
    @Published var error: String?

    /// В избранном ли эта организация (синхронизируется с сервером при загрузке).
    @Published var isFav = false
    /// Флаг: isFav меняется программно (загрузка с сервера) — не слать тоггл в ответ.
    var favSyncing = false

    // Отзывы (грузятся в фоне для всех типов организаций).
    @Published var reviews: [Review] = []
    @Published var reviewsLoading = true
    @Published var reviewsError: String?

    /// Slug — единственный ключ загрузки (у Shop и у deep-link он общий).
    let slug: String
    /// Опорные данные для мгновенного hero до прихода detail.
    let seed: Shop?

    init(shop: Shop) { self.slug = shop.slug ?? ""; self.seed = shop }
    init(shopSlug: String) { self.slug = shopSlug; self.seed = nil }

    /// Услуга ли это. Приоритет — серверный признак `mode == "service"` (как на Android);
    /// фолбэк на эвристику (есть услуги и нет товаров) — на случай старого ответа без `mode`.
    var isService: Bool {
        if let m = detail?.mode?.lowercased() { return m == "service" }
        if let sm = seed?.shopMode?.lowercased() { return sm == "service" }
        return !services.isEmpty && products.isEmpty
    }

    func load() async {
        guard !slug.isEmpty else { error = "Нет данных заведения"; loading = false; return }
        loading = true; error = nil
        do {
            async let d: ShopDetail = API.shared.get("api/v1/shops/\(slug)")
            async let p: [Product] = API.shared.list("api/v1/shops/\(slug)/products")
            detail = try await d
            products = (try? await p) ?? []
        } catch is CancellationError {
            // отмена — молча
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
        // Категории товаров магазина: отдельный запрос по shopId (паритет с Android
        // Repo.categories(shopId)). GET api/v1/categories?shop_id=<id> -> [Category].
        // Нужны для меню-табов и фильтра filteredProducts (product.categoryId == cat.id).
        if let shopId = detail?.id {
            Task { @MainActor in
                if let cats: [Category] = try? await API.shared.list("api/v1/categories", query: ["shop_id": String(shopId)]) {
                    productCategories = cats
                }
            }
        }
        // Услуги догружаем в фоне (нужны только для фолбэк-эвристики isService).
        Task { @MainActor in
            if let r: ServicesResponse = try? await API.shared.get("api/v1/shops/\(slug)/services") {
                services = r.services ?? []
            }
        }
        // Избранное организации — в фоне (сердечко станет красным, если она уже в избранном).
        Task { @MainActor in await loadFavState() }
        // Отзывы — в фоне, не задерживая показ карточки.
        Task { @MainActor in await loadReviews() }
    }

    /// Синхронизация состояния избранного с сервером. Тот же механизм, что в DiscoverView:
    /// GET api/v1/favorites -> [Shop], isFav = содержит ли этот shop.id.
    func loadFavState() async {
        guard let shopId = detail?.id else { return }
        if let favs: [Shop] = try? await API.shared.list("api/v1/favorites") {
            let fav = favs.contains { $0.id == shopId }
            // Программная установка: onChange увидит favSyncing == true и не пошлёт тоггл.
            favSyncing = true
            isFav = fav
            DispatchQueue.main.async { self.favSyncing = false }
        }
    }

    /// Оптимистичный тоггл избранного: POST api/v1/favorites/{id} (добавить) /
    /// DELETE api/v1/favorites/{id} (убрать). Откат при ошибке. isFav уже переключён биндингом.
    func toggleFav() async {
        guard !favSyncing, let shopId = detail?.id else { return }
        let on = isFav
        do {
            if on { try await API.shared.postVoid("api/v1/favorites/\(shopId)") }
            else  { try await API.shared.deleteVoid("api/v1/favorites/\(shopId)") }
        } catch {
            isFav.toggle()   // откат
        }
    }

    /// Отзывы заведения: GET api/v1/shops/{slug}/reviews -> [Review].
    func loadReviews() async {
        guard !slug.isEmpty else { reviewsLoading = false; return }
        reviewsLoading = true; reviewsError = nil
        do {
            reviews = try await API.shared.list("api/v1/shops/\(slug)/reviews")
        } catch is CancellationError {
        } catch {
            reviewsError = error.localizedDescription
        }
        reviewsLoading = false
    }
}

// MARK: - OrgView

struct OrgView: View {
    @StateObject private var vm: OrgViewModel
    @StateObject private var cart = Cart.shared
    @EnvironmentObject private var coord: NavCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var activeCat: Int = 0
    @State private var pushedProduct: Int?
    @State private var pushedService: ServiceItem?
    @State private var showAuth = false

    private let heroHeight: CGFloat = 308

    init(shop: Shop) { _vm = StateObject(wrappedValue: OrgViewModel(shop: shop)) }
    init(shopSlug: String) { _vm = StateObject(wrappedValue: OrgViewModel(shopSlug: shopSlug)) }

    var body: some View {
        ZStack(alignment: .top) {
            YMColor.bg.ignoresSafeArea()

            if vm.loading && vm.detail == nil {
                loadingState
            } else if let e = vm.error, vm.detail == nil {
                errorState(e)
            } else {
                content
                // Липкая корзина + чат-FAB поверх контента.
                bottomBar
            }

            topControls
        }
        .navigationBarHidden(true)
        .task { if vm.detail == nil { await vm.load() } }
        // Внутренние переходы флоу (организация → товар / услуга).
        .navigationDestination(isPresented: Binding(
            get: { pushedProduct != nil },
            set: { if !$0 { pushedProduct = nil } }
        )) { if let id = pushedProduct { ProductView(id: id) } }
        .navigationDestination(isPresented: Binding(
            get: { pushedService != nil },
            set: { if !$0 { pushedService = nil } }
        )) { if let s = pushedService { ProductView(service: s, shopName: vm.detail?.name) } }
        // Вход для гостя при попытке записи на услугу (self-contained шит).
        .sheet(isPresented: $showAuth) {
            AuthView { showAuth = false }
                .environmentObject(Session.shared)
        }
    }

    // MARK: Content (parallax hero + sheet)

    private var content: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Параллакс-hero: тянется при оттягивании вниз, уезжает вверх при скролле.
                GeometryReader { geo in
                    let minY = geo.frame(in: .named("scroll")).minY
                    let stretch = max(0, minY)
                    PhotoPlaceholder(
                        url: API.imageURL(vm.detail?.cover ?? vm.detail?.banner ?? seedCover),
                        label: "ОБЛОЖКА · ПАРАЛЛАКС",
                        radius: 0, tone: 0
                    )
                    .frame(width: geo.size.width, height: heroHeight + stretch)
                    .clipped()
                    .overlay(
                        // Градиент-фейд к фону снизу.
                        LinearGradient(
                            colors: [.clear, .clear, YMColor.bg],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .offset(y: reduceMotion ? -min(0, minY) : (minY > 0 ? -minY : -minY * 0.5))
                }
                .frame(height: heroHeight)

                sheet
                    .padding(.top, -34)   // sheet поднимается на hero (нахлёст r28)
            }
        }
        .coordinateSpace(name: "scroll")
        .ignoresSafeArea(edges: .top)
    }

    private var seedCover: String? { vm.seed?.cover ?? vm.seed?.banner ?? vm.seed?.logo }

    // MARK: Sheet (поднятая шторка r28)

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Хедер: логотип 72×72 r20 слева, название + статус — рядом справа.
            HStack(alignment: .center, spacing: 14) {
                PhotoPlaceholder(url: API.imageURL(vm.detail?.logo ?? vm.seed?.logo),
                                 label: "ЛОГО", radius: 20, tone: 1)
                    .frame(width: 72, height: 72)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(YMColor.hairline, lineWidth: 1))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.15), radius: 10, y: 4)

                // Название 25/heavy + бейдж «Открыто» — справа от логотипа.
                VStack(alignment: .leading, spacing: 8) {
                    Text(vm.detail?.name ?? vm.seed?.name ?? "—")
                        .font(.system(size: 25, weight: .heavy))
                        .foregroundStyle(YMColor.text)
                        .lineLimit(2)
                    StatusPill(text: isOpen ? "Открыто" : "Закрыто",
                               kind: isOpen ? .open : .cancel, solid: false)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 20)

            // Баннер нерабочего времени: «Сейчас закрыто. Откроется <день> в <время>» + предзаказ.
            // Кнопки заказа/корзины остаются рабочими (предзаказ = обычное оформление).
            if !isOpen {
                ClosedBanner(opensLabel: OrgHours.nextOpenLabel(vm.detail?.hours))
                    .padding(.top, 12)
            }

            // Подзаголовок «Тип · кухня · теги».
            if let sub = subtitle, !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 13.5))
                    .foregroundStyle(YMColor.muted)
                    .padding(.top, 6)
            }

            // ★рейтинг · оценки · время.
            HStack(spacing: 12) {
                if let r = rating, r > 0 {
                    HStack(spacing: 5) {
                        Text("★").foregroundStyle(YMColor.accent)
                        Text(String(format: "%.1f", r)).foregroundStyle(YMColor.text)
                        if let rc = vm.seed?.reviewsCount, rc > 0 {
                            Text("· \(rc) оценок").foregroundStyle(YMColor.muted)
                        }
                    }
                    .font(.system(size: 13.5, weight: .semibold))
                }
                if let t = deliveryTime, !t.isEmpty {
                    HStack(spacing: 4) {
                        Text("🕑")
                        Text(t).foregroundStyle(YMColor.muted)
                    }
                    .font(.system(size: 13.5))
                }
            }
            .padding(.top, 10)

            // Способ получения (Доставка/Самовывоз/За столик) выбирается на оформлении,
            // на странице организации сегмент не показываем.

            // Карточка адреса + мини-карта + маршрут.
            addressCard
                .padding(.top, 16)

            // Услуга (запись) или меню.
            if vm.isService {
                OrgBookingSection(slug: vm.slug, detail: vm.detail) { showAuth = true }
                    .padding(.top, 20)
            } else {
                menuSection.padding(.top, 20)
            }

            // Отзывы — для всех типов организаций. Сводка нажимаема → полный экран ReviewsScreen.
            OrgReviewsSection(
                slug: vm.slug,
                reviews: vm.reviews,
                loading: vm.reviewsLoading,
                error: vm.reviewsError,
                avgRating: rating,
                reviewsCount: vm.detail?.reviewsCount ?? vm.seed?.reviewsCount
            )
            .padding(.top, 20)

            // Отступ под липкую корзину + FAB.
            Color.clear.frame(height: cart.count > 0 ? 150 : 96)
        }
        .padding(.horizontal, YMSpace.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            YMColor.bg
                .clipShape(RoundedRectangle(cornerRadius: YMRadius.sheet, style: .continuous))
        )
    }

    // MARK: Address card + mini-map

    private var addressCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Мини-карта: золотой пин по lat/lng.
            if let lat = vm.detail?.lat, let lng = vm.detail?.lng {
                OrgMiniMap(lat: lat, lng: lng)
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(YMColor.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(vm.detail?.address ?? "Адрес уточняется")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(YMColor.text)
                    if let city = vm.seed?.category { // fallback; при наличии дистанции — покажется тут
                        Text(city)
                            .font(.system(size: 12))
                            .foregroundStyle(YMColor.muted)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    Haptics.light()
                    openRoute()
                } label: {
                    Text("↗ Маршрут")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(YMColor.onAccent)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(YMColor.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(vm.detail?.lat == nil && (vm.detail?.address?.isEmpty ?? true))
            }
            .padding(14)
        }
        .background(YMColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
            .strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    // MARK: Menu (магазин)

    private var menuSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Липкая навигация по разделам меню — золотое подчёркивание активного.
            if !categories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 18) {
                        catTab("Популярное", 0)
                        ForEach(categories) { c in catTab(c.name ?? "—", c.id) }
                    }
                    .padding(.bottom, 4)
                }
            }

            LazyVStack(spacing: 12) {
                ForEach(shownProducts) { p in
                    DishRow(product: p) {
                        Haptics.light()
                        pushedProduct = p.id
                    } onAdd: {
                        pushedProduct = p.id   // «+» ведёт на карточку (модификаторы/степпер там)
                    }
                }
                if shownProducts.isEmpty {
                    Text("В этом разделе пока пусто")
                        .font(YMFont.callout)
                        .foregroundStyle(YMColor.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .padding(.top, 12)
        }
    }

    // MARK: Category tab (золотое подчёркивание)

    private func catTab(_ title: String, _ id: Int) -> some View {
        let active = activeCat == id
        return Button {
            Haptics.selection()
            withAnimation(YMMotion.adaptive(YMMotion.snappy, reduceMotion: reduceMotion)) { activeCat = id }
        } label: {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 14.5, weight: active ? .heavy : .semibold))
                    .foregroundStyle(active ? YMColor.text : YMColor.muted)
                Rectangle()
                    .fill(active ? YMColor.accent : .clear)
                    .frame(height: 2.5)
                    .clipShape(Capsule())
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Top controls (‹ ↗ ♡)

    private var topControls: some View {
        HStack {
            circleControl("chevron.left") { Haptics.light(); dismiss() }
            Spacer()
            HStack(spacing: 10) {
                circleControl("square.and.arrow.up") { share() }
                // Избранное организации — красное сердечко (heart.fill, YMColor.statusCancel).
                HeartButton(isFav: $vm.isFav, size: 38, favColor: YMColor.statusCancel)
                    .onChange(of: vm.isFav) { _ in Task { await vm.toggleFav() } }
            }
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, 8)
    }

    private func circleControl(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Color.black.opacity(0.4), in: Circle())
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Bottom bar (StickyCartBar + чат-FAB)

    private var bottomBar: some View {
        VStack(spacing: 12) {
            Spacer()
            // Чат-FAB над корзиной.
            HStack {
                Spacer()
                Button {
                    Haptics.light()
                    // Чат в этом API привязан к заказу — из карточки организации
                    // открываем общий список чатов (диалоги по заказам заведения).
                    coord.openChatList()
                } label: {
                    Text("💬")
                        .font(.system(size: 22))
                        .frame(width: 52, height: 52)
                        .background(YMColor.surface, in: Circle())
                        .overlay(Circle().strokeBorder(YMColor.hairline, lineWidth: 1))
                        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, YMSpace.xl)

            if cart.count > 0 {
                StickyCartBar(count: cart.count, total: Money.dec(cart.total)) {
                    // Открыть глобальный флоу корзины (Корзина → Оформление → Успех).
                    coord.openCart()
                }
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 16) {
            SkeletonBox(radius: 0).frame(height: heroHeight).ignoresSafeArea(edges: .top)
            VStack(alignment: .leading, spacing: 12) {
                SkeletonBox().frame(width: 72, height: 72)
                SkeletonBox().frame(width: 180, height: 24)
                SkeletonBox().frame(width: 240, height: 14)
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonBox(radius: YMRadius.card).frame(height: 96)
                }
            }
            .padding(.horizontal, YMSpace.xl)
            Spacer()
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

    // MARK: Derived

    /// Открыто ли сейчас. Приоритет — расчёт по ShopDetail.hours (как на Android isOpenNow),
    /// т.к. при входе по deep-link seed отсутствует. Фолбэк на seed.isOpen из списка, иначе «открыто».
    private var isOpen: Bool {
        if let d = vm.detail, let computed = OrgHours.isOpenNow(d.hours) { return computed }
        return vm.seed?.isOpen ?? true
    }
    private var rating: Double? { vm.detail?.rating ?? vm.seed?.rating }
    private var deliveryTime: String? { vm.detail?.deliveryTime ?? vm.seed?.deliveryTime }
    private var subtitle: String? {
        // «Тип · кухня · теги» — из категории Shop / категорий ShopDetail.
        var parts: [String] = []
        if let cat = vm.seed?.category, !cat.isEmpty { parts.append(cat) }
        if let cats = vm.detail?.categories, !cats.isEmpty {
            parts.append(cats.prefix(2).compactMap { $0.name }.joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    /// Категории для меню-табов — КАТЕГОРИИ ТОВАРОВ магазина (по shopId), а не
    /// теги-категории организации (detail.categories). Их id совпадают с product.categoryId.
    private var categories: [Category] { vm.productCategories }

    private var shownProducts: [Product] {
        activeCat == 0 ? vm.products : vm.products.filter { $0.categoryId == activeCat }
    }

    // MARK: Actions

    /// Deep-link в Яндекс.Карты с fallback на web.
    private func openRoute() {
        guard let lat = vm.detail?.lat, let lng = vm.detail?.lng else {
            // Fallback по адресу-строке.
            let addr = vm.detail?.address ?? vm.detail?.name ?? ""
            let q = addr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let web = URL(string: "https://yandex.ru/maps/?text=\(q)") { openURL(web) }
            return
        }
        let appURL = URL(string: "yandexmaps://build_route_on_map/?lat_to=\(lat)&lon_to=\(lng)")
        let webURL = URL(string: "https://yandex.ru/maps/?rtext=~\(lat),\(lng)&rtt=auto")
        if let app = appURL {
            UIApplication.shared.open(app, options: [:]) { ok in
                if !ok, let web = webURL { openURL(web) }
            }
        } else if let web = webURL {
            openURL(web)
        }
    }

    private func share() {
        Haptics.light()
        guard let slug = vm.detail?.slug ?? vm.seed?.slug,
              let url = URL(string: "\(API.base)/shop/\(slug)") else { return }
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // Presenter из активной сцены (self-contained экран).
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .rootViewController?
            .present(av, animated: true)
    }
}

// MARK: - DishRow (строка блюда)

/// Строка блюда: фото 88×88, название + ХАЛЯЛЬ, описание, цена, круглая золотая «+».
struct DishRow: View {
    let product: Product
    var onTap: () -> Void = {}
    var onAdd: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(product.name ?? "—")
                            .font(.system(size: 15.5, weight: .bold))
                            .foregroundStyle(YMColor.text)
                            .lineLimit(1)
                        if product.isHalal == true {
                            HalalBadge()
                        }
                    }
                    if let d = product.description, !d.isEmpty {
                        Text(d)
                            .font(.system(size: 12.5))
                            .foregroundStyle(YMColor.muted)
                            .lineLimit(2)
                    }
                    Text(Money.format(Money.dec(product.price)))
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(YMColor.text)
                        .padding(.top, 2)
                }
                Spacer(minLength: 8)
                ZStack(alignment: .bottomTrailing) {
                    PhotoPlaceholder(url: API.imageURL(product.photo),
                                     label: "ФОТО", radius: YMRadius.control, tone: product.id)
                        .frame(width: 88, height: 88)
                    // Круглая золотая «+» со свечением.
                    Button {
                        Haptics.light()
                        onAdd()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundStyle(YMColor.onAccent)
                            .frame(width: 30, height: 30)
                            .background(YMColor.accent, in: Circle())
                            .shadow(color: YMPalette.gold.opacity(0.5), radius: 10, y: 3)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 8, y: 8)
                }
            }
            .padding(12)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                .strokeBorder(YMColor.hairline, lineWidth: 1))
        }
        .buttonStyle(CardPressStyle())
    }
}

// MARK: - HalalBadge (переиспользуемый бейдж «ХАЛЯЛЬ»)

/// Зелёный бейдж «ХАЛЯЛЬ» — семантика статуса «done» (зелёный), мягкая заливка.
struct HalalBadge: View {
    var body: some View {
        Text("ХАЛЯЛЬ")
            .font(.system(size: 10, weight: .heavy))
            .tracking(0.3)
            .foregroundStyle(YMColor.statusDone)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(YMColor.statusDone.opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// MARK: - OrgMiniMap (MapKit, золотой пин)

/// Мини-карта организации: неинтерактивная превью с золотым пином по lat/lng.
struct OrgMiniMap: View {
    let lat: Double
    let lng: Double

    struct Pin: Identifiable { let id = UUID(); let coord: CLLocationCoordinate2D }

    var body: some View {
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        let region = MKCoordinateRegion(center: coord,
                                        span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008))
        Map(coordinateRegion: .constant(region),
            interactionModes: [],
            annotationItems: [Pin(coord: coord)]) { pin in
            MapAnnotation(coordinate: pin.coord) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(YMColor.accent)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - ClosedBanner (баннер нерабочего времени + предзаказ)

/// Заметный баннер при входе в закрытую организацию.
/// `opensLabel` = nil → только «Сейчас закрыто» (нет данных о часах).
struct ClosedBanner: View {
    let opensLabel: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("🕑")
                Text(opensLabel != nil ? "Сейчас закрыто. Откроется \(opensLabel!)" : "Сейчас закрыто")
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(YMColor.text)
            }
            Text("Можно оформить предзаказ — приготовим и доставим к открытию.")
                .font(.system(size: 12.5))
                .foregroundStyle(YMColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(YMColor.statusPending.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(YMColor.statusPending.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - OrgHours (расчёт открыто-сейчас + ближайшее открытие)

/// Логика рабочих часов по [ShopHour] (dayOfWeek 1=Пн..7=Вс, 0/7=Вс; isClosed==1 — выходной).
/// Без падений при пустых/битых данных. Паритет с Android isOpenNow/nextOpenLabel.
enum OrgHours {
    /// Открыто ли сейчас. nil = нет данных (вызывающий решает — считать открытым).
    static func isOpenNow(_ hours: [ShopHour]?) -> Bool? {
        guard let hours, !hours.isEmpty else { return nil }
        let cal = Calendar.current
        let now = Date()
        let dow = weekdayToServer(cal.component(.weekday, from: now)) // 1=Пн..7=Вс
        guard let today = hours.first(where: { norm($0.dayOfWeek) == dow }) else { return nil }
        if today.isClosed == 1 { return false }
        guard let open = today.openTime?.prefix(5).description,
              let close = today.closeTime?.prefix(5).description,
              !open.isEmpty, !close.isEmpty else { return nil }
        let cur = String(format: "%02d:%02d", cal.component(.hour, from: now), cal.component(.minute, from: now))
        // Обычный интервал или «через полночь» (close <= open).
        return close > open ? (cur >= open && cur <= close) : (cur >= open || cur <= close)
    }

    /// «сегодня в HH:MM» / «завтра в HH:MM» / «в <день недели> в HH:MM». nil = нет данных.
    static func nextOpenLabel(_ hours: [ShopHour]?) -> String? {
        guard let hours, !hours.isEmpty else { return nil }
        let cal = Calendar.current
        let now = Date()
        let todayDow = weekdayToServer(cal.component(.weekday, from: now))
        let cur = String(format: "%02d:%02d", cal.component(.hour, from: now), cal.component(.minute, from: now))
        for offset in 0...7 {
            let dow = ((todayDow - 1 + offset) % 7) + 1
            guard let entry = hours.first(where: { norm($0.dayOfWeek) == dow }) else { continue }
            if entry.isClosed == 1 { continue }
            guard let open = entry.openTime?.prefix(5).description, !open.isEmpty else { continue }
            if offset == 0 && cur >= open { continue } // сегодня уже поздно — ищем дальше
            let whenLabel: String
            switch offset {
            case 0: whenLabel = "сегодня"
            case 1: whenLabel = "завтра"
            default: whenLabel = "в " + ruWeekday(dow)
            }
            return "\(whenLabel) в \(open)"
        }
        return nil
    }

    /// Calendar.weekday (1=Вс..7=Сб) → серверный формат (1=Пн..7=Вс).
    private static func weekdayToServer(_ w: Int) -> Int { w == 1 ? 7 : w - 1 }
    /// Нормализуем серверный dayOfWeek к 1..7 (0=Вс → 7).
    private static func norm(_ dow: Int?) -> Int { let d = dow ?? 7; return d == 0 ? 7 : d }
    /// День недели в предложном падеже (1=Пн..7=Вс).
    private static func ruWeekday(_ dow: Int) -> String {
        switch dow {
        case 1: return "понедельник"; case 2: return "вторник"; case 3: return "среду"
        case 4: return "четверг"; case 5: return "пятницу"; case 6: return "субботу"
        default: return "воскресенье"
        }
    }
}

// MARK: - Money.dec (Double → Decimal, точно)

extension Money {
    /// Модели этого клиента хранят деньги как `Double?` (LenientDouble на сервере
    /// отдаёт числа/строки). `Money.parse(_:)` не имеет ветки для Double и вернул бы 0,
    /// поэтому конвертируем через строковое представление — без ошибки плавающей точки
    /// (Decimal(double) даёт мусорные хвосты). nil → 0.
    static func dec(_ value: Double?) -> Decimal {
        guard let v = value else { return 0 }
        // "%g" не годится для больших сумм; печатаем полное десятичное, без экспоненты.
        return Decimal(string: String(format: "%.2f", v)) ?? 0
    }
}
