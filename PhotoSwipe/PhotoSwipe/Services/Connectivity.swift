import Foundation
import Network

/// Whether the device is online. Posts `becameOnline` when a connection
/// comes back, so pending syncs and downloads can resume.
@MainActor
final class Connectivity: ObservableObject {
    static let shared = Connectivity()
    static let becameOnline = Notification.Name("Connectivity.becameOnline")

    @Published private(set) var isOnline = true

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                let wasOnline = self.isOnline
                self.isOnline = online
                if online && !wasOnline {
                    NotificationCenter.default.post(name: Self.becameOnline, object: nil)
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "Connectivity"))
    }
}
