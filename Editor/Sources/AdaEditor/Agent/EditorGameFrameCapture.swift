@_spi(AdaEngine) import AdaEngine
import AdaMCPCore
import Foundation

/// Reads finished frames of the running game and stores them as PNG files.
///
/// Studio's own render world only contains editor UI cameras. Games are rendered by
/// `SceneView`s that opt in with ``gameLabel``, so every capture goes through
/// ``SceneViewFrameRegistry`` instead of the editor's cameras.
@MainActor
enum EditorGameFrameCapture {
    static let gameLabel = "game"
    static let maxRetainedFiles = 80

    /// Replaces AdaMCP's default `render.capture_screenshot` source.
    ///
    /// With a running game the result is that game's completed frame. Without one
    /// the editor window is captured as before (UI-node screenshots depend on it) and
    /// the result's `world` field says so: that image is not evidence about the game.
    static var mcpCaptureOverride: RenderCaptureService.CaptureOverride {
        { appWorlds, cameraEntityID, cameraName, _, refreshFrame in
            if let source = SceneViewFrameRegistry.latest(label: gameLabel) {
                return try await captureForMCP(source: source, cameraEntityID: cameraEntityID, cameraName: cameraName)
            }
            if cameraEntityID != nil || cameraName != nil {
                throw SceneViewFrameCaptureError.noGameView(label: gameLabel)
            }
            let editorResult = try await RenderCaptureService(appWorlds: appWorlds)
                .capture(cameraEntityID: nil, cameraName: nil, pauseBeforeCapture: false, refreshFrame: refreshFrame)
            return ScreenshotCaptureResult(
                world: "editor-window (no game is running; this is not the game)",
                cameraEntityID: editorResult.cameraEntityID,
                cameraName: editorResult.cameraName,
                width: editorResult.width,
                height: editorResult.height,
                path: editorResult.path,
                timestamp: editorResult.timestamp
            )
        }
    }

    private static func captureForMCP(source: SceneViewFrameSource, cameraEntityID: Int?, cameraName: String?) async throws -> ScreenshotCaptureResult {
        var name = cameraName
        if let cameraEntityID {
            guard let match = source.activeCameras.first(where: { $0.id == cameraEntityID }) else {
                throw SceneViewFrameCaptureError.cameraUnavailable(name: "#\(cameraEntityID)", activeCameras: source.activeCameraNames)
            }
            name = match.name
        }
        let frame = try await source.captureFrame(after: max(0, source.frameSequence - 1), cameraName: name)
        let camera = source.activeCameras.first { $0.name == name } ?? source.activeCameras.first
        let url = try write(frame.image, to: FileManager.default.temporaryDirectory.appendingPathComponent("adamcp-screenshots", isDirectory: true), name: "game-\(frame.sequence)")
        return ScreenshotCaptureResult(
            world: "game:\(source.label)",
            cameraEntityID: camera?.id ?? -1,
            cameraName: camera?.name ?? "",
            width: frame.image.width,
            height: frame.image.height,
            path: url.path,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }

    /// Directory for captures an agent may read; outside `Assets` so they never become project assets.
    static func capturesDirectory(projectURL: URL) -> URL {
        projectURL.appendingPathComponent(ProjectSystem.metadataDirectoryName, isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
            .appendingPathComponent("agent-captures", isDirectory: true)
    }

    @discardableResult
    static func write(_ image: Image, to directory: URL, name: String) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8)).png")
        try image.pngData().write(to: url, options: .atomic)
        prune(directory, keeping: maxRetainedFiles)
        return url
    }

    static func prune(_ directory: URL, keeping limit: Int) {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
            urls.count > limit
        else { return }
        let dated = urls.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(urls.count - limit) {
            try? manager.removeItem(at: url)
        }
    }

    /// `editor.play.capture`: one frame of the running game, optionally by camera and bounded size.
    static func captureTool(projectURL: URL, cameraName: String?, maxDimension: Int?) async throws -> [String: Any] {
        guard let source = SceneViewFrameRegistry.latest(label: gameLabel) else {
            throw SceneViewFrameCaptureError.noGameView(label: gameLabel)
        }
        let limit = min(max(maxDimension ?? EditorPlayScenario.Limits.defaultDimension, 64), EditorPlayScenario.Limits.maxDimension)
        let frame = try await source.captureFrame(after: max(0, source.frameSequence - 1), cameraName: cameraName, maxDimension: limit)
        let url = try write(frame.image, to: capturesDirectory(projectURL: projectURL), name: "play")
        return [
            "path": url.path,
            "width": frame.image.width,
            "height": frame.image.height,
            "sourceWidth": frame.sourceWidth,
            "sourceHeight": frame.sourceHeight,
            "frameSequence": frame.sequence,
            "activeCameras": frame.activeCameras,
            "kind": "game-frame",
        ]
    }
}
