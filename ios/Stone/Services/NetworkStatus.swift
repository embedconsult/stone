import Combine
import Foundation
import Network
import SwiftUI

/// Whether the phone has a network path at all, from the system's own
/// monitor. With none (airplane mode, Wi-Fi off and no cellular) a sync
/// can't reach anything, so Stone doesn't start one and says "Offline"
/// instead of spinning (maintainer, on a plane: "Stone acted like it was
/// synching while the wifi wasn't active", ocx-console forum 653b82196c).
/// ForegroundSync syncs everything once the path returns.
///
/// A path being up doesn't prove the server answers (a plane's Wi-Fi before
/// sign-in is up); such a sync still runs and fails with its own status.
@MainActor
final class NetworkStatus: ObservableObject {
    static let shared = NetworkStatus()

    @Published private(set) var online = true

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in
                if NetworkStatus.shared.online != online { NetworkStatus.shared.online = online }
            }
        }
        monitor.start(queue: DispatchQueue(label: "Stone.NetworkStatus"))
    }
}

/// What a sync button shows with no network: plainly offline, not busy.
struct OfflineLabel: View {
    var body: some View {
        Label("Offline", systemImage: "wifi.slash").labelStyle(.titleAndIcon)
    }
}
