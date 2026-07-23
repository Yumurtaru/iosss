import Foundation
import UIKit

final class Push {
    static let shared = Push()
    var fcmToken: String?

    /// Запросить разрешение на уведомления (вызывать после входа / в настройках).
    func requestAuthorization() {
        (UIApplication.shared.delegate as? AppDelegate)?.requestPushAuth()
    }

    /// Отправить токен на бэкенд (если вошли и токен получен).
    func registerIfPossible() async {
        guard let token = fcmToken, UserDefaults.standard.string(forKey: "token") != nil else { return }
        try? await API.shared.postVoid("api/v1/push/register", body: PushBody(token: token, platform: "ios"))
    }
}
