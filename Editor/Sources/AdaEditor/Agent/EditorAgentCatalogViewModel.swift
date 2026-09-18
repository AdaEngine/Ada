import Foundation
import Observation

@Observable
@MainActor
final class EditorAgentCatalogViewModel {
    enum Filter: String, CaseIterable {
        case all = "All"
        case installed = "Added"
        case available = "Not Added"
    }
    var query = ""
    var filter = Filter.all
    var agents: [EditorRegistryAgent] = []
    var discovered: [EditorDiscoveredAgent] = []
    var installed: [EditorInstalledAgent] = []
    var isBusy = false
    var status = ""
    var notificationAction = EditorNotificationAction(title: "Agent settings", destination: .agentSettings)
    var notificationProjectName: String?
    private var hasLoaded = false
    private let service: EditorAgentCatalogService

    init(service: EditorAgentCatalogService = .shared) { self.service = service }

    var visibleAgents: [EditorRegistryAgent] {
        agents.filter { agent in
            let added = installed.contains { $0.id == agent.id }
            return (filter == .all || (filter == .installed ? added : !added)) && (query.isEmpty || "\(agent.name) \(agent.id) \(agent.description)".localizedCaseInsensitiveContains(query))
        }
        .sorted { lhs, rhs in
            let left = discovered.contains { $0.id == lhs.id }
            let right = discovered.contains { $0.id == rhs.id }
            return left != right ? left : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func adapter(for local: EditorDiscoveredAgent) -> EditorRegistryAgent? {
        agents.first { $0.id == local.id }
    }

    func loadIfNeeded() async {
        guard !hasLoaded else {
            return
        }
        hasLoaded = true
        await refresh()
    }

    func refresh() async {
        guard !isBusy else {
            return
        }
        isBusy = true
        defer { isBusy = false }
        discovered = await service.discover()
        do {
            installed = try await service.installed()
        } catch {
            reportError(error.localizedDescription)
            return
        }
        if agents.isEmpty {
            agents = await service.cachedRegistry()
        }
        do {
            agents = try await service.refresh()
            status = "\(agents.count) agents • \(discovered.count) found on this Mac"
        } catch {
            status = "Registry unavailable. \(agents.isEmpty ? "Local agents are still available." : "Showing the saved catalog.") \(error.localizedDescription)"
        }
    }

    @discardableResult
    func add(_ local: EditorDiscoveredAgent) async -> EditorInstalledAgent? {
        guard !isBusy else {
            return nil
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let entry = try await service.addLocal(local)
            installed = try await service.installed()
            status = "\(local.name) added. Choose Connect to use it in this project."
            filter = .all
            return entry
        } catch {
            reportError(error.localizedDescription)
            return nil
        }
    }

    @discardableResult
    func install(_ agent: EditorRegistryAgent) async -> EditorInstalledAgent? {
        guard !isBusy else {
            return nil
        }
        isBusy = true
        status = "Installing \(agent.name)…"
        defer { isBusy = false }
        do {
            let entry = try await service.install(agent)
            installed = try await service.installed()
            status =
                entry.version == agent.version
                ? "\(agent.name) \(entry.version) installed."
                : "Registry version \(agent.version) is unavailable. Installed published version \(entry.version)."
            filter = .all
            return entry
        } catch {
            reportError(error.localizedDescription)
            return nil
        }
    }

    private func reportError(_ message: String) {
        status = message
        EditorNotificationCenter.shared.post(
            .init(
                source: .catalog,
                importance: .error,
                title: "Agent catalog operation failed",
                detail: message,
                projectName: notificationProjectName,
                actions: [notificationAction]
            )
        )
    }

    func remove(_ agent: EditorInstalledAgent) async {
        guard !isBusy else {
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            try await service.remove(agent)
            installed = try await service.installed()
            status = "\(agent.name) removed from the list. Existing project connections and files are kept."
        } catch { reportError(error.localizedDescription) }
    }
}
