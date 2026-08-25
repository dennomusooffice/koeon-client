import Combine
import Foundation
import Network

@MainActor
final class ConnectionMonitor: ObservableObject {
    @Published private(set) var pathDescription = "Unknown"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "org.example.koeon.path-monitor")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let value: String
            if path.status != .satisfied {
                value = "Offline"
            } else if path.usesInterfaceType(.wifi) {
                value = "Wi-Fi"
            } else if path.usesInterfaceType(.cellular) {
                value = "Cellular"
            } else if path.usesInterfaceType(.wiredEthernet) {
                value = "Ethernet"
            } else {
                value = "Online"
            }
            Task { @MainActor in self?.pathDescription = value }
        }
        monitor.start(queue: queue)
    }

    deinit { monitor.cancel() }
}
