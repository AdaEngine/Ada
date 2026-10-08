import Foundation
import Observation

@Observable @MainActor
final class EditorAchievementCenter {
    static let shared: EditorAchievementCenter = {
        let root =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return EditorAchievementCenter(url: root.appendingPathComponent("AdaEditor/achievements.json"))
    }()

    private(set) var snapshot = EditorAchievementSnapshot()
    private(set) var profileID = "local"
    private(set) var status = "Local progress · Game Center not connected"
    private(set) var storageError: String?
    private(set) var isSyncing = false
    @ObservationIgnored var onEarned: ((EditorAchievement) -> Void)?
    @ObservationIgnored private var provider: (any EditorAchievementProvider)?
    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var canPersist = true
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var revision = 0

    init(url: URL? = nil) {
        self.url = url
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        do {
            let loaded = try JSONDecoder().decode(EditorAchievementSnapshot.self, from: Data(contentsOf: url))
            guard loaded.version == 1 else {
                throw CocoaError(.coderReadCorrupt)
            }
            snapshot = loaded
            profileID = loaded.activeProfileID
        } catch {
            canPersist = false
            storageError = "Unable to read achievements: \(error.localizedDescription). The original file is preserved."
        }
    }

    var profile: EditorAchievementProfile { snapshot.profiles[profileID] ?? .init() }
    var earnedCount: Int { EditorAchievement.catalog.filter { progress($0.id).earnedAt != nil }.count }
    var notificationsEnabled: Bool { snapshot.notificationsEnabled }
    var isConnected: Bool { provider?.playerID != nil }

    func progress(_ id: EditorAchievementID) -> EditorAchievementProgress { profile.progress[id] ?? .init() }

    func install(_ provider: any EditorAchievementProvider) {
        self.provider = provider
        provider.onPlayerChanged = { [weak self] player in self?.selectPlayer(player) }
        if snapshot.gameCenterEnabled {
            provider.authenticate()
        }
    }

    func connect() {
        guard let provider else {
            status = "Game Center is unavailable on this platform."
            return
        }
        snapshot.gameCenterEnabled = true
        persist()
        status = "Connecting to Game Center…"
        provider.authenticate()
    }

    func showGameCenter() { provider?.showAchievements() }
    func setProviderStatus(_ message: String) { status = message }

    func setNotificationsEnabled(_ enabled: Bool) {
        snapshot.notificationsEnabled = enabled
        persist()
    }

    func selectPlayer(_ player: String?) {
        generation += 1
        syncTask?.cancel()
        isSyncing = false
        profileID = player.map { "gamecenter:\($0)" } ?? "local"
        snapshot.activeProfileID = profileID
        // Guest progress is claimed once, by the first connected account only.
        if let player, snapshot.guestOwner == nil {
            let guest = snapshot.profiles["local"] ?? .init()
            var destination = profile
            destination.activeDays.formUnion(guest.activeDays)
            for (id, progress) in guest.progress {
                let existing = destination.progress[id] ?? .init()
                if progress.value > existing.value {
                    destination.progress[id] = progress
                }
            }
            snapshot.profiles[profileID] = destination
            snapshot.profiles["local"] = .init()
            snapshot.guestOwner = player
        }
        persist()
        status = player == nil ? "Local progress · Game Center not connected" : "Game Center connected"
        synchronize()
    }

    func record(_ values: [EditorAchievementID: Int], date: Date = Date(), activeDay: Bool = false) {
        var updated = profile
        var values = values
        if activeDay {
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
            let day = "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
            updated.activeDays.insert(day)
            values[.activeDays] = updated.activeDays.count
        }
        var earned: [EditorAchievement] = []
        for achievement in EditorAchievement.catalog {
            guard let value = values[achievement.id] else {
                continue
            }
            var progress = updated.progress[achievement.id] ?? .init()
            progress.value = min(achievement.goal, max(progress.value, value))
            if progress.value == achievement.goal, progress.earnedAt == nil {
                progress.earnedAt = date
                earned.append(achievement)
            }
            updated.progress[achievement.id] = progress
        }
        guard updated.progress != profile.progress || updated.activeDays != profile.activeDays else {
            return
        }
        snapshot.profiles[profileID] = updated
        revision += 1
        guard persist() else {
            return
        }
        if notificationsEnabled {
            for achievement in earned { onEarned?(achievement) }
        }
        synchronize()
    }

    func synchronize() {
        guard
            let provider, let player = provider.playerID,
            profileID == "gamecenter:\(player)", !isSyncing, canPersist
        else {
            return
        }
        syncTask?.cancel()
        let generation = generation
        syncTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, self.generation == generation else {
                return
            }
            await self.sync(provider: provider, player: player, generation: generation)
        }
    }

    private func sync(provider: any EditorAchievementProvider, player: String, generation: Int) async {
        isSyncing = true
        let revision = revision
        defer {
            if self.generation == generation {
                isSyncing = false
                if self.revision != revision {
                    synchronize()
                }
            }
        }
        do {
            let remote = try await provider.load()
            guard self.generation == generation, provider.playerID == player, !Task.isCancelled else {
                return
            }
            var updated = profile
            var pending: [EditorAchievementID: Double] = [:]
            for achievement in EditorAchievement.catalog {
                let raw = remote[achievement.id] ?? 0
                let percent = raw.isFinite ? min(100, max(0, raw)) : 0
                var progress = updated.progress[achievement.id] ?? .init()
                progress.value = max(progress.value, Int((percent * Double(achievement.goal) / 100).rounded(.down)))
                if percent >= 100, progress.earnedAt == nil {
                    progress.earnedAt = Date()
                }
                updated.progress[achievement.id] = progress
                let local = Double(progress.value) / Double(achievement.goal) * 100
                if local > percent, !achievement.secret || local >= 100 {
                    pending[achievement.id] = local
                }
            }
            snapshot.profiles[profileID] = updated
            guard persist() else {
                return
            }
            if !pending.isEmpty {
                try await provider.report(pending)
            }
            guard self.generation == generation, provider.playerID == player else {
                return
            }
            status = "Game Center · Synced"
        } catch {
            guard self.generation == generation else {
                return
            }
            status = "Saved locally · Sync unavailable: \(error.localizedDescription)"
        }
    }

    @discardableResult
    private func persist() -> Bool {
        guard canPersist else {
            return false
        }
        guard let url else {
            return true
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
            storageError = nil
            return true
        } catch {
            storageError = "Unable to save achievements: \(error.localizedDescription)"
            return false
        }
    }
}
