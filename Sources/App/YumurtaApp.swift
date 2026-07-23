import SwiftUI

/// Ключи @AppStorage (единая точка правды для персистентных настроек UI).
enum AppStorageKey {
    static let theme     = "appearance"   // "system" | "light" | "dark"
    static let onboarded = "onboarded"
    static let cityId    = "cityId"
    static let cityName  = "cityName"
}

@main
struct YumurtaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = Session.shared
    @StateObject private var cart = Cart.shared
    @StateObject private var net = NetworkMonitor.shared
    @StateObject private var router = DeepLinkRouter.shared
    @StateObject private var coord = NavCoordinator.shared

    @AppStorage(AppStorageKey.theme) private var theme = "system"
    @AppStorage(AppStorageKey.onboarded) private var onboarded = false

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(session)
                .environmentObject(cart)
                .environmentObject(net)
                .environmentObject(router)
                .environmentObject(coord)
                .tint(YMColor.accent)
                .preferredColorScheme(colorScheme)
                .fullScreenCover(isPresented: Binding(
                    get: { !onboarded },
                    set: { if !$0 { onboarded = true } }
                )) {
                    OnboardingView(onFinish: { onboarded = true })
                        // ВАЖНО: модальные экраны в этом проекте НЕ наследуют
                        // environmentObject автоматически — пробрасываем явно,
                        // иначе @EnvironmentObject session в онбординге падает на старте.
                        .environmentObject(session)
                        .environmentObject(cart)
                        .environmentObject(net)
                        .environmentObject(router)
                        .environmentObject(coord)
                        .preferredColorScheme(colorScheme)
                }
                .onOpenURL { url in router.handle(url: url) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { router.handle(url: url) }
                }
                .task {
                    Push.shared.requestAuthorization()
                    await Push.shared.registerIfPossible()
                }
        }
    }

    /// Тема применяется глобально через preferredColorScheme.
    private var colorScheme: ColorScheme? {
        switch theme {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil   // system
        }
    }
}
