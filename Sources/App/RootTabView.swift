import SwiftUI

/// Корневой таб-бар premium-клиента: Главная / Поиск / Избранное / Заказы / Профиль.
/// Активная вкладка — золото (YMColor.accent через .tint). Фон бара — материал.
///
/// Навигация:
///  • Каждый таб — самодостаточный экран со своим NavigationStack
///    (HomeView / SearchScreen / FavoritesScreen / OrdersView / ProfileView).
///    Внутренние переходы (организация → товар, заказ → деталь → чат) живут
///    внутри соответствующего стека — RootTabView их не дублирует.
///  • Кросс-таб переходы (плашка поиска → таб Поиск, «Повторить заказ» → Заказы)
///    идут через DeepLinkRouter.requestedTab.
///  • Глобальный флоу корзины (Корзина→Оформление→Успех) и чат показываются
///    ПОВЕРХ активного таба через NavCoordinator (Cart — синглтон, доступ к нему
///    нужен из любого экрана: StickyCartBar в Org и т.д.).
struct RootTabView: View {
    @EnvironmentObject private var cart: Cart
    @EnvironmentObject private var net: NetworkMonitor
    @EnvironmentObject private var router: DeepLinkRouter
    @EnvironmentObject private var coord: NavCoordinator
    @State private var tab = 0

    init() {
        // Фон таб-бара — системный материал (blur), тонкая золотая линия сверху.
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().standardAppearance = appearance
    }

    var body: some View {
        VStack(spacing: 0) {
            if !net.online {
                Text("Нет подключения к интернету")
                    .font(YMFont.caption).fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(YMColor.statusCancel)
            }
            TabView(selection: $tab) {
                HomeView()
                    .tabItem { Label("Главная", systemImage: "house.fill") }
                    .tag(0)

                SearchScreen()
                    .tabItem { Label("Поиск", systemImage: "magnifyingglass") }
                    .tag(1)

                // Корзина как вкладка (Корзина → Оформление → Успех) через CartFlow.
                CartFlow(
                    onClose: { tab = 0 },
                    onTrackOrder: { id in coord.pendingOrderDetail = id; tab = 3 }
                )
                    .tabItem { Label("Корзина", systemImage: "cart.fill") }
                    .tag(2)
                    .badge(cart.count == 0 ? 0 : cart.count)

                OrdersView(onOpen: { _ in })
                    .tabItem { Label("Заказы", systemImage: "bag.fill") }
                    .tag(3)

                // Профиль убран из вкладок — открывается из шапки Главной.
                FavoritesScreen()
                    .tabItem { Label("Избранное", systemImage: "heart.fill") }
                    .tag(4)
            }
        }
        .tint(YMColor.accent)
        .animation(.easeInOut, value: net.online)
        .onChange(of: router.requestedTab) { newTab in
            if let t = newTab { tab = t; router.requestedTab = nil }
        }
        // «Следить за заказом» из флоу корзины → таб «Заказы» открывает деталь сам.
        .onChange(of: coord.pendingOrderDetail) { pending in
            if pending != nil { tab = 3 }
        }
        // ── Глобальный флоу корзины (Корзина → Оформление → Успех) ──
        .fullScreenCover(isPresented: $coord.showCart) {
            CartFlow(
                onClose: { coord.showCart = false },
                onTrackOrder: { id in coord.pendingOrderDetail = id }
            )
            .environmentObject(cart)
            .environmentObject(router)
            .environmentObject(coord)
            .environmentObject(Session.shared)
        }
        // ── Глобальный диалог конфликта корзины (single-store) ──
        .cartConflictDialog(
            isPresented: $coord.cartConflict,
            currentShop: coord.conflictCurrentShop,
            newShop: coord.conflictNewShop,
            onConfirm: { coord.conflictConfirm?(); coord.conflictConfirm = nil }
        )
        // ── Глобальный чат (из Org-FAB и из деталей заказа) ──
        .sheet(isPresented: Binding(
            get: { coord.chatOrderId != nil },
            set: { if !$0 { coord.chatOrderId = nil } }
        )) {
            NavigationStack {
                Group {
                    if let id = coord.chatOrderId, id > 0 {
                        ChatView(orderId: id)
                    } else {
                        ChatView.list          // id == -1 → общий список чатов
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Закрыть") { coord.chatOrderId = nil }
                    }
                }
            }
            .environmentObject(Session.shared)
        }
    }
}
