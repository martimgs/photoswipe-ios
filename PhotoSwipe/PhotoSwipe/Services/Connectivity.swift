import Foundation
import Network

/// Whether the device is online. Posts `becameOnline` when a connection
/// comes back, so pending syncs and downloads can resume.
///
/// Debug builds can simulate being offline (Settings → Developer), since
/// the iOS Simulator has no airplane mode.
@MainActor
final class Connectivity: ObservableObject {
    static let shared = Connectivity()
    static let becameOnline = Notification.Name("Connectivity.becameOnline")
    static let simulateOfflineKey = "debug.simulateOffline"

    @Published private(set) var isOnline = true

    /// Debug only. Treats the device as offline for all Dropbox work.
    @Published var simulateOffline = false {
        didSet {
            #if DEBUG
            UserDefaults.standard.set(simulateOffline, forKey: Self.simulateOfflineKey)
            update()
            #endif
        }
    }

    private var networkAvailable = true
    private let monitor = NWPathMonitor()

    private init() {
        #if DEBUG
        simulateOffline = UserDefaults.standard.bool(forKey: Self.simulateOfflineKey)
        #endif
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in
                self?.networkAvailable = available
                self?.update()
            }
        }
        monitor.start(queue: DispatchQueue(label: "Connectivity"))
        update()
    }

    private func update() {
        #if DEBUG
        let online = networkAvailable && !simulateOffline
        #else
        let online = networkAvailable
        #endif
        let wasOnline = isOnline
        isOnline = online
        if online && !wasOnline {
            NotificationCenter.default.post(name: Self.becameOnline, object: nil)
        }
    }
}
