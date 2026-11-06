@_spi(AdaEngine) import AdaEngine
import Foundation

/// Editor-only state. Libraries and source models are never saved through this file.
struct EditorAnimationWorkspaceState: Codable {
    var version = 1
    var assetPath: String
    var libraryPath: String?
    var clipID: String?
    var sourceClip: String
    var mode: String
    var panelWidth: Float
    var showsPanel: Bool
    var selectedNodes: Set<String>
    var collapsedNodes: Set<String>
    var expandedChannels: Set<String>
    var graph: AnimationGraph
    var positions: [String: [Float]]
    var pan: [Float]
    var zoom: Float
    var preview: Preview?

    struct Preview: Codable {
        var orthographic: Bool
        var background: String
        var lighting: Float
        var grid: Bool
        var axes: Bool
    }

    @MainActor init(_ workspace: EditorAnimationAssetWorkspace) {
        assetPath = workspace.document.relativePath
        libraryPath = workspace.library?.relativePath ?? workspace.libraryPath
        clipID = workspace.library?.selectedClipID
        sourceClip = workspace.sourceClip
        mode = workspace.mode.rawValue
        panelWidth = workspace.timeline.modelPanelWidth
        showsPanel = workspace.timeline.showsModelPanel
        selectedNodes = workspace.timeline.selectedNodes
        collapsedNodes = workspace.timeline.collapsedNodes
        expandedChannels = workspace.timeline.expandedChannels
        graph = workspace.graph.graph
        let ids = Set(graph.nodes.map(\.id))
        positions = workspace.graph.positions.filter { ids.contains($0.key) }.mapValues { [$0.x, $0.y] }
        pan = [workspace.graph.canvas.pan.x, workspace.graph.canvas.pan.y]
        zoom = workspace.graph.canvas.zoom
        preview = .init(orthographic: workspace.camera.isOrthographic, background: workspace.camera.backgroundStyle,
                        lighting: workspace.camera.lightingIntensity, grid: workspace.camera.showsGrid, axes: workspace.camera.showsAxes)
    }

    @MainActor private static func url(project: URL, asset: String) throws -> URL {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in asset.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        let url = project.appendingPathComponent(".ada/workspace/animation/" + String(hash, radix: 16) + ".json").standardizedFileURL
        guard EditorAnimationAuthoringService.canonicalDestination(url).path == url.path,
              url.path.hasPrefix(project.path + "/") else { throw invalid() }
        return url
    }

    @MainActor static func load(project: URL, asset: String) throws -> Self? {
        let url = try url(project: project, asset: asset)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 2 * 1024 * 1024 else { throw invalid() }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
        guard bytes.count <= 2 * 1024 * 1024 else { throw invalid() }
        let state = try JSONDecoder().decode(Self.self, from: bytes)
        try state.validate(asset: asset)
        return state
    }

    @MainActor func save(project: URL) throws {
        try validate(asset: assetPath)
        let target = try Self.url(project: project, asset: assetPath)
        // Full identity comparison prevents a cache-name collision from replacing another asset's state.
        if let previous = try Self.load(project: project, asset: assetPath), previous.assetPath != assetPath { throw Self.invalid() }
        let data = try JSONEncoder().encode(self)
        guard data.count <= 2 * 1024 * 1024 else { throw Self.invalid() }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try Self.url(project: project, asset: assetPath)
        try data.write(to: target, options: .atomic)
    }

    @MainActor private func validate(asset: String) throws {
        let ids = graph.nodes.map(\.id)
        guard version == 1, assetPath == asset, asset.utf8.count <= 4096,
              panelWidth.isFinite, (100...4000).contains(panelWidth), zoom.isFinite, (0.25...2.5).contains(zoom),
              pan.count == 2, pan.allSatisfy({ $0.isFinite && abs($0) < 10_000_000 }),
              graph.nodes.count <= 1024, Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }),
              graph.nodes.reduce(0, { $0 + $1.inputs.count }) <= 4096,
              positions.count <= 1024, positions.values.allSatisfy({ $0.count == 2 && $0.allSatisfy { $0.isFinite && abs($0) < 10_000_000 } }),
              selectedNodes.count <= 16_384, collapsedNodes.count <= 16_384, expandedChannels.count <= 16_384 else { throw Self.invalid() }
        if let preview {
            guard preview.lighting.isFinite, (0...8).contains(preview.lighting), ["dark", "gray", "light"].contains(preview.background) else { throw Self.invalid() }
        }
    }

    @MainActor private static func invalid() -> AnimationAuthoringError {
        .init(.conflict, itemID: "workspace", message: L10n.tr("Animation workspace state is invalid or outside the project."))
    }
}

extension EditorAnimationAssetWorkspace {
    func restoreWorkspaceState() {
        guard let service else { return }
        do {
            guard let saved = try EditorAnimationWorkspaceState.load(project: service.projectURL, asset: document.relativePath) else { return }
            timeline.modelPanelWidth = saved.panelWidth
            timeline.showsModelPanel = saved.showsPanel
            timeline.selectedNodes = saved.selectedNodes
            timeline.collapsedNodes = saved.collapsedNodes
            timeline.expandedChannels = saved.expandedChannels
            mode = Mode(rawValue: saved.mode) ?? .keys
            sourceClip = saved.sourceClip
            graph.restoring = true
            graph.graph = saved.graph
            graph.restoring = false
            graph.undoStack = []; graph.redoStack = []
            graph.selectedNodeID = graph.graph.root
            graph.positions = saved.positions.mapValues { Vector2($0[0], $0[1]) }
            graph.canvas.zoom(by: saved.zoom / graph.canvas.zoom, around: .zero)
            graph.canvas.setPan(Vector2(saved.pan[0], saved.pan[1]))
            if let preview = saved.preview {
                camera.isOrthographic = preview.orthographic
                camera.backgroundStyle = preview.background
                camera.lightingIntensity = preview.lighting
                camera.showsGrid = preview.grid
                camera.showsAxes = preview.axes
            }
            if let path = saved.libraryPath {
                libraryPath = path
                let url = try service.resolve(path, extensions: ["animlib"])
                if FileManager.default.fileExists(atPath: url.path) {
                    library = try service.open(path)
                    library?.selectedClipID = saved.clipID
                }
            }
        } catch { self.error = L10n.text("Unable to restore animation workspace: \(error.localizedDescription)") }
    }

    func saveWorkspaceState() throws {
        guard let service else { return }
        try EditorAnimationWorkspaceState(self).save(project: service.projectURL)
    }
}
