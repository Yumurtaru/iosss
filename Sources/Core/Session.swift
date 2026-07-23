import Foundation
import Combine


final class Session: ObservableObject {
    static let shared = Session()
    @Published private(set) var token: String?
    @Published var cityId: Int? { didSet { UserDefaults.standard.set(cityId ?? 0, forKey: "cityId") } }
    @Published var cityName: String? { didSet { UserDefaults.standard.set(cityName, forKey: "cityName") } }

    var isLoggedIn: Bool { token != nil }

    private init() {
        token = UserDefaults.standard.string(forKey: "token")
        let c = UserDefaults.standard.integer(forKey: "cityId"); cityId = c == 0 ? nil : c
        cityName = UserDefaults.standard.string(forKey: "cityName")
        // При 401 (истёкший токен) аккуратно выходим из аккаунта.
        API.shared.onUnauthorized = { [weak self] in self?.signOut() }
    }
    /// refresh — токен продления (30 дней): API тихо обновляет access при 401 (security-аудит).
    func signIn(_ token: String, refresh: String? = nil) {
        self.token = token
        UserDefaults.standard.set(token, forKey: "token")
        if let r = refresh, !r.isEmpty { UserDefaults.standard.set(r, forKey: "refresh_token") }
        // После входа: спросить разрешение на push (если ещё не спрашивали) и отправить
        // device-токен на бэкенд — токен привязывается к вошедшему пользователю.
        Push.shared.requestAuthorization()
        Task { await Push.shared.registerIfPossible() }
    }
    func signOut() {
        token = nil
        UserDefaults.standard.removeObject(forKey: "token")
        UserDefaults.standard.removeObject(forKey: "refresh_token")
    }
}
