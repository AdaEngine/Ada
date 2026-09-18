import Foundation

#if os(macOS)
    import AppKit
    import GameKit
#elseif os(iOS)
    import GameKit
    import UIKit
#endif

#if os(macOS) || os(iOS)
    @MainActor
    final class EditorGameCenterProvider: NSObject, EditorAchievementProvider, @preconcurrency GKGameCenterControllerDelegate {
        var playerID: String? { GKLocalPlayer.local.isAuthenticated ? GKLocalPlayer.local.gamePlayerID : nil }
        var onPlayerChanged: ((String?) -> Void)?
        var onStatus: ((String) -> Void)?
        private var authenticationInstalled = false
        #if os(macOS)
            private var authenticationWindow: NSWindow?
        #endif

        func authenticate() {
            if authenticationInstalled, playerID != nil {
                onPlayerChanged?(playerID)
                return
            }
            authenticationInstalled = true
            GKLocalPlayer.local.authenticateHandler = { [weak self] controller, error in
                Task { @MainActor [weak self] in
                    guard let self else {
                        return
                    }
                    if let controller {
                        #if os(macOS)
                            let window = NSWindow(contentViewController: controller)
                            window.title = "Game Center"
                            window.center()
                            window.makeKeyAndOrderFront(nil)
                            self.authenticationWindow = window
                        #else
                            guard let presenter = self.presenter else {
                                self.onStatus?("Open Settings to connect to Game Center.")
                                return
                            }
                            presenter.present(controller, animated: true)
                        #endif
                        return
                    }
                    #if os(macOS)
                        self.authenticationWindow?.close()
                        self.authenticationWindow = nil
                    #endif
                    if let error {
                        // A network/authentication failure must not hide the last player's offline progress.
                        self.onStatus?("Game Center unavailable: \(error.localizedDescription). Progress stays local.")
                    } else {
                        self.onPlayerChanged?(self.playerID)
                    }
                }
            }
        }

        func load() async throws -> [EditorAchievementID: Double] {
            let achievements = try await GKAchievement.loadAchievements()
            let ids = Dictionary(uniqueKeysWithValues: EditorAchievement.catalog.map { ($0.gameCenterID, $0.id) })
            return achievements.reduce(into: [:]) { result, achievement in
                if let id = ids[achievement.identifier] {
                    result[id] = achievement.percentComplete
                }
            }
        }

        func report(_ progress: [EditorAchievementID: Double]) async throws {
            let achievements = EditorAchievement.catalog.compactMap { definition -> GKAchievement? in
                guard let value = progress[definition.id] else {
                    return nil
                }
                let achievement = GKAchievement(identifier: definition.gameCenterID)
                achievement.percentComplete = value
                // The editor notification center owns banners; syncing never replays a reward.
                achievement.showsCompletionBanner = false
                return achievement
            }
            try await GKAchievement.report(achievements)
        }

        func showAchievements() {
            guard playerID != nil else {
                authenticate()
                return
            }
            let controller = GKGameCenterViewController(state: .achievements)
            controller.gameCenterDelegate = self
            #if os(macOS)
                GKDialogController.shared().parentWindow = NSApp.keyWindow ?? NSApp.mainWindow
                if !GKDialogController.shared().present(controller) {
                    onStatus?("Unable to open Game Center.")
                }
            #else
                presenter?.present(controller, animated: true)
            #endif
        }

        func gameCenterViewControllerDidFinish(_ gameCenterViewController: GKGameCenterViewController) {
            #if os(macOS)
                GKDialogController.shared().dismiss(gameCenterViewController)
            #else
                gameCenterViewController.dismiss(animated: true)
            #endif
        }

        #if os(iOS)
            private var presenter: UIViewController? {
                let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                var controller = scenes.filter { $0.activationState == .foregroundActive }
                    .flatMap(\.windows).first(where: \.isKeyWindow)?
                    .rootViewController
                while let presented = controller?.presentedViewController { controller = presented }
                return controller
            }
        #endif
    }
#endif

@MainActor
enum EditorAchievementBootstrap {
    private(set) static var center: EditorAchievementCenter?

    static func install() {
        let center = EditorAchievementCenter.shared
        self.center = center
        center.onEarned = { achievement in
            EditorNotificationCenter.shared.post(
                .init(
                    id: "achievement:\(center.profileID):\(achievement.id.rawValue)",
                    source: .project,
                    importance: .success,
                    title: "Achievement unlocked · \(achievement.title)",
                    detail: achievement.detail,
                    requestsSystemDelivery: false
                )
            )
        }
        #if os(macOS) || os(iOS)
            let provider = EditorGameCenterProvider()
            provider.onStatus = { [weak center] in center?.setProviderStatus($0) }
            center.install(provider)
        #endif
    }
}
