@_spi(AdaEngine) import AdaEngine
import Foundation
import Observation
import Yams

struct EditorTileSourcePreview {
    let image: Image
    let layout: TileSourceImageDescriptor
}

@Observable
@MainActor
final class EditorTileSourceEditorModel {
    private(set) var image: Image?
    private(set) var previews: [EditorTileSourcePreview?] = []
    private(set) var sources: [[String: Any]] = []
    private(set) var selectedSource = 0
    private(set) var selectedTile: PointInt?
    private(set) var layout: TileSourceImageDescriptor?
    private(set) var status = "Add a PNG image to create a tile source."
    private(set) var isEditable = false
    var name = ""
    var width = "16"
    var height = "16"
    var marginX = "0"
    var marginY = "0"
    var spacingX = "0"
    var spacingY = "0"
    var displayWidth = "16"
    var displayHeight = "16"
    var frames = "1"
    var duration = "1"
    var verticalAnimation = false
    var zoom: Float = 2
    var showGrid = true

    @ObservationIgnored private let url: URL?
    @ObservationIgnored private var root: [String: Any] = [:]
    @ObservationIgnored private var savedData: Data?

    init(document: EditorAssetDocument) {
        url = document.absolutePath.map { URL(fileURLWithPath: $0) }
        reload()
    }

    var gridSize: SizeInt {
        guard let image, let layout else {
            return .zero
        }
        return layout.gridSize(imageSize: [image.width, image.height])
    }

    var tiles: [[String: Any]] { sourceData["tiles"] as? [[String: Any]] ?? [] }
    var sourceData: [String: Any] {
        guard sources.indices.contains(selectedSource) else {
            return [:]
        }
        return sources[selectedSource]["data"] as? [String: Any] ?? [:]
    }
    var canEditSource: Bool { isEditable && layout != nil && image != nil }

    func sourceName(at index: Int) -> String {
        let data = sources[index]["data"] as? [String: Any] ?? [:]
        return data["name"] as? String ?? "Source \(index)"
    }

    func reload() {
        guard let url else {
            status = "Tile source has no file path."
            return
        }
        do {
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw EditorTileSourceError.message("Symbolic-link tile sources are read-only.")
            }
            let data = try Data(contentsOf: url)
            guard
                let yaml = String(bytes: data, encoding: .utf8),
                let parsed = try Yams.load(yaml: yaml) as? [String: Any],
                let loadedSources = parsed["sources"] as? [[String: Any]],
                let size = parsed["tileSize"] as? [String: Int],
                let x = size["x"], let y = size["y"], x > 0, y > 0
            else {
                throw EditorTileSourceError.message("Expected tileSize and sources in the .tileset file.")
            }
            root = parsed
            sources = loadedSources
            previews = loadedSources.indices.map { loadPreview(at: $0) }
            savedData = data
            displayWidth = String(x)
            displayHeight = String(y)
            isEditable = true
            selectSource(min(selectedSource, max(0, sources.count - 1)))
            if sources.isEmpty {
                status = "Add a PNG image to create a tile source."
            }
        } catch {
            isEditable = false
            status = error.localizedDescription
        }
    }

    func selectSource(_ index: Int) {
        selectedSource = index
        selectedTile = nil
        image = nil
        layout = nil
        name = sourceNameSafely(index)
        guard sources.indices.contains(index) else { return }
        guard let preview = previews[index] else {
            if !sources.isEmpty {
                status = "Image preview unavailable. Legacy or custom source data is preserved."
            }
            return
        }
        layout = preview.layout
        image = preview.image
        width = String(preview.layout.tileSize.width)
        height = String(preview.layout.tileSize.height)
        marginX = String(preview.layout.margin.width)
        marginY = String(preview.layout.margin.height)
        spacingX = String(preview.layout.spacing.width)
        spacingY = String(preview.layout.spacing.height)
        status = "Click a cell to inspect it. Add tiles individually or create the whole grid."
    }

    private func loadPreview(at index: Int) -> EditorTileSourcePreview? {
        guard sources.indices.contains(index),
              sources[index]["type"] as? String == String(reflecting: TextureAtlasTileSource.self),
              let data = sources[index]["data"] as? [String: Any],
              let raw = data["image"], let url else { return nil }
        do {
            let settings = try YAMLDecoder().decode(TileSourceImageDescriptor.self, from: Yams.dump(object: raw))
            try settings.validate()
            let path = settings.resolvedPath(relativeTo: url.deletingLastPathComponent())
            guard !path.hasPrefix("@res://") else { return nil }
            let imageURL = path.hasPrefix("file://") ? URL(string: path) : URL(fileURLWithPath: path)
            guard let imageURL else { return nil }
            return try EditorTileSourcePreview(image: Image(contentsOf: imageURL), layout: settings)
        } catch { return nil }
    }

    func presentImagePicker() {
        guard isEditable else {
            return
        }
        ProjectOpenPicker.presentAtlasImagePicker { [weak self] result in
            switch result {
            case let .selected(urls): self?.addImages(urls)
            case let .unavailable(message): self?.status = message
            case .cancelled: break
            }
        }
    }

    func addImages(_ urls: [URL]) {
        guard isEditable, let url else {
            return
        }
        var updated = sources
        var copied: [URL] = []
        do {
            for source in urls where source.pathExtension.lowercased() == "png" {
                _ = try Image(contentsOf: source)
                let base = url.deletingLastPathComponent()
                let standardized = source.standardizedFileURL
                let target: URL
                if standardized.path.hasPrefix(base.standardizedFileURL.path + "/") {
                    target = standardized
                } else {
                    let directory = base.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".images")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    var candidate = directory.appendingPathComponent(source.lastPathComponent)
                    var suffix = 2
                    while FileManager.default.fileExists(atPath: candidate.path) {
                        candidate = directory.appendingPathComponent("\(source.deletingPathExtension().lastPathComponent)-\(suffix).png")
                        suffix += 1
                    }
                    try FileManager.default.copyItem(at: source, to: candidate)
                    copied.append(candidate)
                    target = candidate
                }
                let path = String(target.standardizedFileURL.path.dropFirst(base.standardizedFileURL.path.count + 1))
                let settings = TileSourceImageDescriptor(path: path, tileSize: [Int(displayWidth) ?? 16, Int(displayHeight) ?? 16])
                updated.append([
                    "type": String(reflecting: TextureAtlasTileSource.self),
                    "data": [
                        "id": try nextSourceID(in: updated),
                        "name": source.deletingPathExtension().lastPathComponent,
                        "image": try imageObject(settings),
                        "tiles": [],
                    ] as [String: Any],
                ])
            }
            guard updated.count != sources.count else {
                return
            }
            try save(updated, refreshPreviews: true)
            selectSource(updated.count - 1)
        } catch {
            for path in copied { try? FileManager.default.removeItem(at: path) }
            status = error.localizedDescription
        }
    }

    func applySettings() {
        guard isEditable else {
            return
        }
        do {
            guard let x = Int(displayWidth), let y = Int(displayHeight), (1...1_048_576).contains(x), (1...1_048_576).contains(y) else {
                throw EditorTileSourceError.message("Tile Set dimensions must be positive whole numbers.")
            }
            var updated = sources
            if var settings = layout, sources.indices.contains(selectedSource) {
                let values = [width, height, marginX, marginY, spacingX, spacingY].compactMap(Int.init)
                guard values.count == 6 else {
                    throw EditorTileSourceError.message("Use whole numbers for slicing settings.")
                }
                settings.tileSize = [values[0], values[1]]
                settings.margin = [values[2], values[3]]
                settings.spacing = [values[4], values[5]]
                try settings.validate()
                if let image {
                    let grid = settings.gridSize(imageSize: [image.width, image.height])
                    guard tiles.allSatisfy({ tileFits($0, grid: grid) }) else {
                        throw EditorTileSourceError.message("Some existing tiles or animation frames would fall outside this grid. Remove them first.")
                    }
                }
                var data = sourceData
                data["name"] = name
                var imageData = data["image"] as? [String: Any] ?? [:]
                imageData.merge(try imageObject(settings) as? [String: Any] ?? [:]) { _, new in new }
                data["image"] = imageData
                updated[selectedSource]["data"] = data
            }
            try save(updated, tileSize: ["x": x, "y": y], refreshPreviews: true)
            selectSource(selectedSource)
            status = "Saved slicing settings"
        } catch { status = error.localizedDescription }
    }

    func selectTile(_ point: PointInt) {
        guard point.x >= 0, point.y >= 0, point.x < gridSize.width, point.y < gridSize.height else {
            return
        }
        selectedTile = point
        let tile = tiles.first { ($0["xy"] as? [Int]) == [point.x, point.y] }
        let animation = tile?["ad"] as? [String: Any] ?? [:]
        frames = String(animation["anim_fr_clm"] as? Int ?? 1)
        duration = String(animation["anim_dur"] as? Double ?? 1)
        verticalAnimation = (animation["anim_alig"] as? Int ?? 1) == 0
    }

    func hasTile(_ point: PointInt) -> Bool { tiles.contains { ($0["xy"] as? [Int]) == [point.x, point.y] } }

    func toggleTile() {
        guard canEditSource, let selectedTile else {
            return
        }
        var updated = tiles
        if let index = updated.firstIndex(where: { ($0["xy"] as? [Int]) == [selectedTile.x, selectedTile.y] }) {
            updated.remove(at: index)
        } else {
            updated.append(newTile(selectedTile))
        }
        saveTiles(updated)
    }

    func createAllTiles() {
        guard canEditSource else {
            return
        }
        let grid = gridSize
        guard grid.width * grid.height <= 65_536 else {
            status = "Grid is too large. Increase the tile dimensions."
            return
        }
        var updated = tiles
        let existing = Set(tiles.compactMap { $0["xy"] as? [Int] })
        for y in 0..<grid.height {
            for x in 0..<grid.width where !existing.contains([x, y]) { updated.append(newTile([x, y])) }
        }
        saveTiles(updated)
    }

    func applyAnimation() {
        guard
            canEditSource, let selectedTile,
            let index = tiles.firstIndex(where: { ($0["xy"] as? [Int]) == [selectedTile.x, selectedTile.y] })
        else {
            return
        }
        guard
            let count = Int(frames), count > 0, count <= 65_536,
            let seconds = Double(duration), seconds.isFinite, seconds > 0,
            count <= (verticalAnimation ? gridSize.height - selectedTile.y : gridSize.width - selectedTile.x)
        else {
            status = "Animation needs a positive duration and frames within the grid."
            return
        }
        var updated = tiles
        var data = updated[index]["ad"] as? [String: Any] ?? [:]
        data["anim_fr_clm"] = count
        data["anim_dur"] = seconds
        data["anim_alig"] = verticalAnimation ? 0 : 1
        updated[index]["ad"] = data
        saveTiles(updated)
    }

    func removeSource() {
        guard isEditable, sources.indices.contains(selectedSource) else {
            return
        }
        var updated = sources
        updated.remove(at: selectedSource)
        do {
            try save(updated, refreshPreviews: true)
            selectSource(min(selectedSource, max(0, updated.count - 1)))
        } catch { status = error.localizedDescription }
    }
}

extension EditorTileSourceEditorModel {
    private func nextSourceID(in sources: [[String: Any]]) throws -> Int {
        let ids = sources.compactMap { ($0["data"] as? [String: Any])?["id"] as? Int }
        guard (ids.max() ?? -1) < Int.max else {
            throw EditorTileSourceError.message("No source IDs available.")
        }
        return (ids.max() ?? -1) + 1
    }

    private func saveTiles(_ tiles: [[String: Any]]) {
        var updated = sources
        var data = sourceData
        data["tiles"] = tiles
        updated[selectedSource]["data"] = data
        do {
            try save(updated)
            status = "Saved \(tiles.count) tiles"
        } catch { status = error.localizedDescription }
    }

    private func save(_ updated: [[String: Any]], tileSize: [String: Int]? = nil, refreshPreviews: Bool = false) throws {
        guard isEditable, let url else {
            throw EditorTileSourceError.message("File is read-only.")
        }
        guard try Data(contentsOf: url) == savedData else {
            reload()
            throw EditorTileSourceError.message("File changed on disk. Reloaded its latest contents; repeat your edit.")
        }
        var candidate = root
        candidate["sources"] = updated
        if let tileSize {
            candidate["tileSize"] = tileSize
        }
        let data = Data(try Yams.dump(object: candidate).utf8)
        try data.write(to: url, options: .atomic)
        root = candidate
        sources = updated
        if refreshPreviews { previews = updated.indices.map { loadPreview(at: $0) } }
        savedData = data
    }

    private func imageObject(_ settings: TileSourceImageDescriptor) throws -> Any {
        try Yams.load(yaml: YAMLEncoder().encode(settings)) ?? [:]
    }

    private func newTile(_ point: PointInt) -> [String: Any] {
        [
            "xy": [point.x, point.y],
            "ad": [
                "anim_dur": 1.0,
                "anim_fr_clm": 1,
                "anim_alig": 1,
                "td": [
                    "mColor": ["red": 1.0, "green": 1.0, "blue": 1.0, "alpha": 1.0],
                    "f_h": false,
                    "f_v": false,
                ],
            ] as [String: Any],
        ]
    }

    private func tileFits(_ tile: [String: Any], grid: SizeInt) -> Bool {
        guard let xy = tile["xy"] as? [Int], xy.count == 2 else {
            return false
        }
        let ad = tile["ad"] as? [String: Any] ?? [:]
        let count = ad["anim_fr_clm"] as? Int ?? 1
        let vertical = (ad["anim_alig"] as? Int ?? 1) == 0
        return xy[0] >= 0 && xy[1] >= 0 && xy[0] < grid.width && xy[1] < grid.height
            && count > 0 && count <= (vertical ? grid.height - xy[1] : grid.width - xy[0])
    }

    private func sourceNameSafely(_ index: Int) -> String { sources.indices.contains(index) ? sourceName(at: index) : "" }
}

extension EditorWorkbenchViewModel {
    func tileSourceModel(for document: EditorAssetDocument) -> EditorTileSourceEditorModel {
        if let model = tileSourceModels[document.id] { return model }
        let model = EditorTileSourceEditorModel(document: document)
        tileSourceModels[document.id] = model
        return model
    }
}

enum EditorTileSourceError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case let .message(text): text
        }
    }
}
