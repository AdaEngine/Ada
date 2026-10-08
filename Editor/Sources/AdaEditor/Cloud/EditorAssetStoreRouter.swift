#if os(macOS)
import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class EditorAssetStoreRouter {
    static let shared = EditorAssetStoreRouter()
    private var downloading = false

    func receive(_ url: URL) -> Bool {
        guard url.scheme == "adaeditor", url.host == "store" else { return false }
        guard let id = EditorAssetStoreClient.assetID(from: url), !downloading else { return true }
        downloading = true
        Task {
            defer { downloading = false }
            do {
                let client = EditorAssetStoreClient()
                let data = try await client.metadata(id: id)
                let asset = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                let title = asset["title"] as? String ?? "Ada asset"
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = "By \(asset["authorName"] as? String ?? "Community") · \(asset["license"] as? String ?? "See Store license")\n\nDownload the asset ZIP. You can then import its files into your project."
                alert.addButton(withTitle: "Download ZIP")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.zip]
                panel.nameFieldStringValue = "ada-asset-" + id + ".zip"
                guard await panel.begin() == .OK, let destination = panel.url else { return }
                let scoped = destination.startAccessingSecurityScopedResource()
                defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
                try await client.download(id: id, to: destination)
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch {
                let alert = NSAlert(); alert.messageText = "Could not download asset"; alert.informativeText = error.localizedDescription; alert.runModal()
            }
        }
        return true
    }
}
#endif
