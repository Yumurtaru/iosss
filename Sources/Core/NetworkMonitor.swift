import Network
import Combine

/// Следит за наличием сети для офлайн-баннера.
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    @Published var online = true
    private let monitor = NWPathMonitor()
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.online = (path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "network.monitor"))
    }
}
