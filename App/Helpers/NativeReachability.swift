import Combine
import Foundation
import Network

/// Whether the Mac has a route to the internet, as the system sees it. The
/// stores watch it so a list that failed for want of a connection loads
/// again on its own the moment one is back, without anyone finding Retry.
@MainActor
final class NativeReachability: ObservableObject {
    // MARK: Lifecycle

    private init() {
        self.monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        self.monitor.start(queue: DispatchQueue(label: "sh.firstlight.reachability"))
    }

    // MARK: Internal

    static let shared = NativeReachability()

    /// True until the monitor has reported otherwise: a fresh launch should
    /// try its first request, not assume the worst.
    @Published private(set) var isOnline = true

    // MARK: Private

    private let monitor = NWPathMonitor()
}
