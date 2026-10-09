@_spi(AdaEngine) import AdaEngine
import Foundation

/// Opens expiring moderator/author previews using the same restricted player.
@MainActor
enum EditorCommunityLinkRouter {
    static func preview(from url: URL) -> EditorCommunityGame? {
        guard url.scheme == "adaeditor", url.host == "community", url.path == "/preview",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = components.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        guard let id = value("game"), UUID(uuidString: id) != nil,
              let release = value("release"), UUID(uuidString: release) != nil,
              let address = value("url"), let target = URL(string: address), target.scheme == "https",
              target.host != nil, target.user == nil, target.password == nil,
              target.query == nil, target.fragment == nil else { return nil }
        return EditorCommunityGame(id: id, title: String((value("title") ?? "Game preview").prefix(120)), description: "", tags: [], likes: 0, coverURL: nil, screenshotURLs: [], playURL: target, runtime: .adaScript(releaseID: release), isPreview: true, apiVersion: Int(value("api") ?? "1") ?? 1)
    }

    static func receive(_ url: URL) -> Bool {
        guard url.scheme == "adaeditor", url.host == "community" else { return false }
        guard let game = preview(from: url), let server = URL(string: EditorCloudAccount.shared.server) else { return true }
        open(game: game, client: EditorCommunityClient(server: server))
        return true
    }

    static func open(game: EditorCommunityGame, client: EditorCommunityClient) {
        Task { @MainActor in
            for _ in 0..<50 where UIWindowManager.shared == nil { try? await Task.sleep(for: .milliseconds(100)) }
            guard let manager = UIWindowManager.shared else { return }
            let holder = WindowHolder()
            let window = manager.spawnWindow(configuration: .init(title: game.title, frame: Rect(x: 0, y: 0, width: 960, height: 640), showsImmediately: false)) {
                EditorCommunityPlayerView(game: game, client: client, close: { holder.window?.close() }).theme(.adaEditor)
            }
            holder.window = window
            window.showWindow(makeFocused: true)
        }
    }

    private final class WindowHolder { weak var window: UIWindow? }
}
