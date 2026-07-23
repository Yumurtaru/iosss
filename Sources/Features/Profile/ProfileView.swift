//
//  ProfileView.swift — Профиль (premium-клиент)
//
//  Макет ProfilePhone: аватар 72 (золотой градиент), имя, телефон, 📍 город;
//  быстрые статы (заказы/избранное/записи); переключатель темы (Система/Светлая/Тёмная);
//  меню: Адреса, Уведомления (бейдж), Оплата, Мои записи, Поддержка, Выйти (красный),
//  удаление аккаунта. Токены, light+dark, Dynamic Type, Reduce Motion.
//
//  ИНИЦИАЛИЗАТОР (для навигации из RootTabView):
//    ProfileView(onOpenAddresses: (() -> Void)? = nil,
//                onOpenBookings:  (() -> Void)? = nil,
//                onOpenNotifications: (() -> Void)? = nil,
//                onOpenPayment:   (() -> Void)? = nil,
//                onOpenSupport:   (() -> Void)? = nil)
//  Если колбэк не передан — экран сам открывает соответствующий раздел через
//  внутренний NavigationStack (AddressesView / BookingsView).
//
//  ТЕМА: пишет в @AppStorage(AppStorageKey.theme) == "appearance" — ТОТ ЖЕ ключ,
//  который читает YumurtaApp.colorScheme (значения "system"|"light"|"dark").
//
//  ПРИВЯЗКА К API (как в старом ProfileView):
//    • GET  api/v1/profile                → Profile
//    • GET  api/v1/orders                 → [Order]   (счётчик «заказы»)
//    • GET  api/v1/favorites + product-favorites (счётчик «в избранном»)
//    • POST api/v1/auth/logout            (выход) → Session.signOut()
//    • DELETE api/v1/profile              (удаление аккаунта) → см. TODO(API) ниже
//

import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var session: Session

    // Внешняя навигация (опционально). nil → внутренний NavigationStack push.
    private let onOpenAddresses: (() -> Void)?
    private let onOpenBookings: (() -> Void)?
    private let onOpenNotifications: (() -> Void)?
    private let onOpenPayment: (() -> Void)?
    private let onOpenSupport: (() -> Void)?

    init(onOpenAddresses: (() -> Void)? = nil,
         onOpenBookings: (() -> Void)? = nil,
         onOpenNotifications: (() -> Void)? = nil,
         onOpenPayment: (() -> Void)? = nil,
         onOpenSupport: (() -> Void)? = nil) {
        self.onOpenAddresses = onOpenAddresses
        self.onOpenBookings = onOpenBookings
        self.onOpenNotifications = onOpenNotifications
        self.onOpenPayment = onOpenPayment
        self.onOpenSupport = onOpenSupport
    }

    @AppStorage(AppStorageKey.theme) private var theme = "system"
    /// Тема экрана из выбранного оформления (реактивно через @AppStorage).
    private var themeScheme: ColorScheme? {
        switch theme { case "light": return .light; case "dark": return .dark; default: return nil }
    }

    @State private var profile: Profile?
    @State private var ordersCount = 0
    @State private var favCount = 0
    @State private var bookingsCount = 0
    @State private var unreadNotifs = 0

    // Внутренняя навигация по разделам профиля (стек маршрутов).
    @State private var path = NavigationPath()

    @State private var showLogoutConfirm = false
    @State private var showDeleteConfirm = false

    private var displayName: String { profile?.name?.isEmpty == false ? profile!.name! : "Профиль" }
    private var avatarLetter: String { String((profile?.name ?? "U").prefix(1)).uppercased() }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 0) {
                    if session.isLoggedIn {
                        header
                        stats
                        themeSwitcher
                        menu
                        deleteAccountButton
                    } else {
                        loggedOut
                    }
                }
                .padding(.bottom, YMSpace.xxxl)
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle("Профиль")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ProfileRoute.self) { route in
                profileDestination(route)
            }
        }
        // Профиль открывается модально (sheet) и НЕ наследует preferredColorScheme
        // корневого экрана — применяем тему здесь же, чтобы смена «Светлая/Тёмная»
        // менялась на экране профиля сразу, без переоткрытия.
        .preferredColorScheme(themeScheme)
        .task { if session.isLoggedIn { await load() } }
        .onChange(of: session.isLoggedIn) { logged in
            if logged { Task { await load() } } else { profile = nil }
        }
        .confirmationDialog("Выйти из аккаунта?", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) { logout() }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog("Удалить аккаунт? Это действие необратимо.",
                            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Удалить аккаунт", role: .destructive) { deleteAccount() }
            Button("Отмена", role: .cancel) {}
        }
    }

    // ── Экраны разделов профиля (единый билдер для NavigationPath) ──
    @ViewBuilder
    private func profileDestination(_ route: ProfileRoute) -> some View {
        switch route {
        case .addresses:    AddressesView()
        case .bookings:     BookingsView()
        case .notifications: NotificationsView()
        case .editProfile:  EditProfileView()
        case .settings:     SettingsView()
        case .support:      SupportView()
        case .plus:         PlusView()
        case .loyalty:      LoyaltyView()
        case .bonuses:      BonusesView()
        case .referral:     ReferralView()
        case .gift:         GiftCardView()
        case .jobs:         JobsView()
        case .applications: ApplicationsView()
        case .returns:      ReturnsView()
        case .auth:         AuthView()
        }
    }

    // ── Шапка: аватар 72 (золотой градиент), имя, телефон, город ──
    private var header: some View {
        HStack(spacing: YMSpace.lg) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [YMPalette.gold, YMPalette.goldDeep],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 72, height: 72)
                    .shadow(color: YMPalette.gold.opacity(0.5), radius: 24, y: 10)
                Text(avatarLetter)
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(YMPalette.goldInk)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.system(size: 22, weight: .heavy)).tracking(-0.4)
                    .foregroundStyle(YMColor.text).lineLimit(1)
                if let phone = profile?.phone, !phone.isEmpty {
                    Text(phone).font(.system(size: 13.5)).foregroundStyle(YMColor.muted)
                }
                if let city = session.cityName, !city.isEmpty {
                    HStack(spacing: 5) {
                        Text("📍")
                        Text(city).font(.system(size: 12.5, weight: .bold))
                    }
                    .foregroundStyle(YMColor.accent)
                    .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.md)
        .padding(.bottom, YMSpace.xs)
    }

    // ── Быстрые статы ──
    private var stats: some View {
        HStack(spacing: 10) {
            statCard(value: ordersCount, label: pluralOrders(ordersCount))
            statCard(value: favCount, label: "в избранном")
            statCard(value: bookingsCount, label: pluralBookings(bookingsCount))
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.lg)
    }

    private func statCard(value: Int, label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(YMColor.accent)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14).padding(.horizontal, 10)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    // ── Переключатель темы (пишет в реальный @AppStorage-ключ root) ──
    private var themeSwitcher: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Оформление")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(YMColor.text)
            YMSegmentedControl(options: ThemeOption.allCases.map { $0.title },
                               index: Binding(
                                   get: { ThemeOption(storage: theme).index },
                                   set: { theme = ThemeOption(index: $0).storage }
                               ))
        }
        .padding(14)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.lg)
    }

    // ── Программы и бонусы ──
    private var loyaltyMenu: some View {
        VStack(spacing: 0) {
            // Yumurta Plus и «Уровень лояльности» временно скрыты по требованию.
            menuRow(icon: "💰", label: "Бонусы") { path.append(ProfileRoute.bonuses) }
            divider
            menuRow(icon: "🎁", label: "Подарочная карта") { path.append(ProfileRoute.gift) }
            divider
            menuRow(icon: "🤝", label: "Пригласить друга") { path.append(ProfileRoute.referral) }
            divider
            menuRow(icon: "↩️", label: "Возвраты") { path.append(ProfileRoute.returns) }
            divider
            menuRow(icon: "💼", label: "Вакансии") { path.append(ProfileRoute.jobs) }
            divider
            menuRow(icon: "📝", label: "Мои отклики") { path.append(ProfileRoute.applications) }
        }
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.lg)
    }

    // ── Меню ──
    private var menu: some View {
        VStack(spacing: YMSpace.lg) {
            loyaltyMenu
            VStack(spacing: 0) {
                menuRow(icon: "✏️", label: "Редактировать профиль") { path.append(ProfileRoute.editProfile) }
                divider
                menuRow(icon: "📍", label: "Адреса доставки") { openAddresses() }
                divider
                menuRow(icon: "🔔", label: "Уведомления", badge: unreadNotifs > 0 ? "\(unreadNotifs)" : nil) {
                    path.append(ProfileRoute.notifications)
                }
                divider
                menuRow(icon: "📅", label: "Мои записи") { openBookings() }
                divider
                menuRow(icon: "⚙️", label: "Настройки") { path.append(ProfileRoute.settings) }
                divider
                menuRow(icon: "🛟", label: "Поддержка") { path.append(ProfileRoute.support) }
                divider
                menuRow(icon: "🚪", label: "Выйти", danger: true, chevron: false) { showLogoutConfirm = true }
            }
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
            .padding(.horizontal, YMSpace.xl)
        }
    }

    private var divider: some View {
        Rectangle().fill(YMColor.hairline).frame(height: 1).padding(.leading, 64)
    }

    private func menuRow(icon: String, label: String, badge: String? = nil,
                         danger: Bool = false, chevron: Bool = true,
                         action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.light(); action() }) {
            HStack(spacing: YMSpace.lg) {
                Text(icon)
                    .font(.system(size: 16))
                    .frame(width: 34, height: 34)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(label)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(danger ? YMColor.statusCancel : YMColor.text)
                Spacer(minLength: 8)
                if let badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(YMPalette.goldInk)
                        .frame(minWidth: 20, minHeight: 20)
                        .padding(.horizontal, 6)
                        .background(YMColor.accent, in: Capsule())
                }
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(YMColor.muted)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // ── Удаление аккаунта ──
    private var deleteAccountButton: some View {
        Button { showDeleteConfirm = true } label: {
            Text("Удалить аккаунт")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(YMColor.statusCancel)
        }
        .padding(.top, YMSpace.xl)
    }

    // ── Не залогинен ──
    private var loggedOut: some View {
        VStack(spacing: YMSpace.lg) {
            Text("👤").font(.system(size: 48))
            Text("Вы не вошли").font(YMFont.title3).foregroundStyle(YMColor.text)
            Text("Войдите, чтобы видеть профиль, записи и избранное.")
                .font(YMFont.callout).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
                .padding(.horizontal, YMSpace.xxxl)
            Button { Haptics.light(); path.append(ProfileRoute.auth) } label: {
                Text("Войти в аккаунт").frame(maxWidth: .infinity)
            }
            .buttonStyle(YMPrimaryButtonStyle())
            .padding(.horizontal, YMSpace.xxxl)
            .padding(.top, YMSpace.md)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    // ── Actions ──
    private func openAddresses() {
        if let cb = onOpenAddresses { cb() } else { path.append(ProfileRoute.addresses) }
    }
    private func openBookings() {
        if let cb = onOpenBookings { cb() } else { path.append(ProfileRoute.bookings) }
    }

    private func logout() {
        Task { try? await API.shared.postVoid("api/v1/auth/logout") }
        session.signOut()
        profile = nil
    }

    private func deleteAccount() {
        // TODO(API): эндпоинт удаления аккаунта (напр. DELETE api/v1/profile) в контракте
        // ещё не подтверждён. Пока — graceful: пытаемся вызвать, при отсутствии просто выходим.
        Task {
            try? await API.shared.deleteVoid("api/v1/profile")
            await MainActor.run { session.signOut(); profile = nil }
        }
    }

    private func load() async {
        profile = try? await API.shared.get("api/v1/profile")
        var q: [String: String] = [:]
        if let cid = session.cityId { q["city_id"] = String(cid) }
        let orders: [Order] = (try? await API.shared.list("api/v1/orders", query: q)) ?? []
        ordersCount = orders.count
        let favShops: [Shop] = (try? await API.shared.list("api/v1/favorites")) ?? []
        let favProducts: [Product] = (try? await API.shared.list("api/v1/product-favorites")) ?? []
        favCount = favShops.count + favProducts.count
        // TODO(API): счётчик «записи» (appointments) не имеет GET-эндпоинта списка (только POST).
        // Пока показываем 0; появится api/v1/appointments (GET) — подставить .count.
        bookingsCount = 0
        let notifs: [AppNotification] = (try? await API.shared.list("api/v1/notifications")) ?? []
        unreadNotifs = notifs.filter { !$0.read }.count
    }

    private func pluralOrders(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return "заказ" }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return "заказа" }
        return "заказов"
    }
    private func pluralBookings(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return "запись" }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return "записи" }
        return "записей"
    }
}

/// Разделы профиля для NavigationPath (значения-маршруты).
private enum ProfileRoute: Hashable {
    case addresses, bookings, notifications, editProfile, settings, support
    case plus, loyalty, bonuses, referral, gift, jobs, applications, returns, auth
}

/// Опция темы ↔ значение @AppStorage(AppStorageKey.theme) ("system"|"light"|"dark").
private enum ThemeOption: CaseIterable {
    case system, light, dark
    var title: String { self == .system ? "Система" : self == .light ? "Светлая" : "Тёмная" }
    var storage: String { self == .system ? "system" : self == .light ? "light" : "dark" }
    var index: Int { self == .system ? 0 : self == .light ? 1 : 2 }

    init(storage: String) {
        switch storage {
        case "light": self = .light
        case "dark":  self = .dark
        default:      self = .system
        }
    }
    init(index: Int) {
        switch index {
        case 1:  self = .light
        case 2:  self = .dark
        default: self = .system
        }
    }
}
