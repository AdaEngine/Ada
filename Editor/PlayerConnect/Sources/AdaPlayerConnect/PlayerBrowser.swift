import Foundation
import Network
import Observation

@Observable @MainActor
public final class PlayerBrowser {
    public struct Device: Identifiable {
        public let id: String
        public let name: String
        public let endpoint: NWEndpoint
    }
    public private(set) var devices: [Device] = []
    public private(set) var status = "Looking for AdaPlayer on this network…"
    @ObservationIgnored private var browser: NWBrowser?
    public init() {}

    public func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: PlayerConnection.serviceType, domain: nil), using: .tcp)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.devices = results.compactMap { result in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    return Device(id: String(describing: result.endpoint), name: name, endpoint: result.endpoint)
                }.sorted { $0.id < $1.id }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { @MainActor in self?.status = error.localizedDescription }
            }
        }
        browser.start(queue: .main)
    }

    public func stop() { browser?.cancel(); browser = nil; devices = [] }
}
