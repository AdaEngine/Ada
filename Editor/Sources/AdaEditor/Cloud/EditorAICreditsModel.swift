import Foundation
import Observation

@MainActor
@Observable
final class EditorAICreditsModel {
    enum Phase: Equatable { case signedOut, loading, ready, unavailable, failed }
    private(set) var phase: Phase = .signedOut
    private(set) var catalog: EditorAICatalog?
    private(set) var balance: EditorAIBalance?
    private(set) var history: [EditorAIUsagePage.Entry] = []
    private(set) var hasMoreHistory = false
    private(set) var loadingHistory = false
    private(set) var historyError: String?
    private(set) var updatedAt: Date?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var cursor: Int64 = 0

    var counterText: String {
        switch phase {
        case .signedOut: "Sign in"
        case .loading: "Credits…"
        case .unavailable, .failed: "Credits —"
        case .ready: balance.map { "\(EditorAICreditAmount.text($0.available)) credits" } ?? "Credits —"
        }
    }

    var summary: String {
        switch phase {
        case .signedOut: return "Sign in to Ada Cloud to see AI credits."
        case .loading: return "Checking AI credits…"
        case .unavailable: return "AI credits are unavailable on this server."
        case .failed: return "Couldn’t refresh AI credits. Please retry."
        case .ready:
            if balance?.closed == true {
                return "This account is closed. AI spending is disabled."
            }
            if balance?.suspended == true {
                return "AI spending is suspended for this account."
            }
            if catalog?.enabled != true {
                return "Hosted AI will open soon."
            }
            if catalog?.availability["cloudServicesAvailable"].bool != true {
                return "Hosted AI is unavailable in your region."
            }
            if catalog?.capabilities.isEmpty == true {
                return "Hosted AI will open soon."
            }
            return "AI credits are shared across your Ada Studio apps."
        }
    }

    func reset(signedIn: Bool) {
        generation = UUID()
        phase = signedIn ? .loading : .signedOut
        balance = nil
        catalog = nil
        history = []
        cursor = 0
        hasMoreHistory = false
        loadingHistory = false
        historyError = nil
        updatedAt = nil
        lastAttempt = nil
        refreshing = false
        needsRefresh = false
    }

    func refresh(client: EditorCloudAIClient, force: Bool = false, now: Date = Date()) async {
        if refreshing {
            // A reservation may complete while a prior balance request is in flight.
            needsRefresh = needsRefresh || force
            return
        }
        guard force || lastAttempt.map({ now.timeIntervalSince($0) >= 45 }) ?? true else {
            return
        }
        let current = generation
        refreshing = true
        lastAttempt = now
        if balance == nil { phase = .loading }
        defer {
            if current == generation {
                refreshing = false
                if needsRefresh {
                    needsRefresh = false
                    Task {
                        guard current == generation else {
                            return
                        }
                        await refresh(client: client, force: true)
                    }
                }
            }
        }
        do {
            let catalog = try await client.catalog()
            let balance = try await client.balance()
            guard current == generation else {
                return
            }
            self.catalog = catalog
            self.balance = balance
            phase = .ready
            updatedAt = now
        } catch {
            guard current == generation else {
                return
            }
            balance = nil
            catalog = nil
            if case let EditorCloudAccount.CloudError.http(status, _) = error, [404, 503].contains(status) {
                phase = .unavailable
            } else {
                phase = .failed
            }
        }
    }

    func loadHistory(client: EditorCloudAIClient, restart: Bool = false) async {
        guard !loadingHistory else {
            return
        }
        let current = generation
        loadingHistory = true
        historyError = nil
        let after = restart ? 0 : cursor
        defer { if current == generation { loadingHistory = false } }
        do {
            let page = try await client.usage(after: after)
            guard current == generation else {
                return
            }
            history = restart ? page.items : history + page.items
            cursor = page.nextCursor
            hasMoreHistory = page.items.count == 50
        } catch {
            guard current == generation else {
                return
            }
            historyError = "Couldn’t load credit activity. Please retry."
        }
    }
}
