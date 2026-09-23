@_spi(AdaEngine) import AdaEngine
import Foundation
import Observation

private struct TileMapCoordinate: Hashable {
    let x: Int
    let y: Int
}

@Observable
@MainActor
final class EditorTileMapEditorModel {
    enum Tool: String, CaseIterable {
        case paint = "Paint"
        case erase = "Erase"
        case pan = "Pan"
    }

    private(set) var map = EditorTileMapResource(atlasColors: [], cells: [])
    private(set) var status = ""
    var selectedColor = 0
    var tool: Tool = .paint
    var newColorHex = "FFFFFF"
    var zoom: Float = 1
    var showGrid = true
    private(set) var panOffset = Point.zero
    private(set) var revision = 0
    private(set) var displayTileSize = Size(width: 24, height: 24)
    private(set) var tileSetStatus = "Link a Tile Source to add authored textures."

    var cellWidth: Float { displayTileSize.width * zoom }
    var cellHeight: Float { displayTileSize.height * zoom }

    @ObservationIgnored private let url: URL?
    @ObservationIgnored private let assetReference: String?
    @ObservationIgnored private let onSave: (() -> Void)?
    @ObservationIgnored private var savedData: Data?
    @ObservationIgnored private var paintedCells: [TileMapCoordinate: Int] = [:]
    @ObservationIgnored private var tileImages: [Image?] = []
    @ObservationIgnored private var tileTextures: [Texture2D?] = []
    @ObservationIgnored private var linkedImages: [Image?] = []
    @ObservationIgnored private var linkedTextures: [Texture2D?] = []
    @ObservationIgnored private var linkedNames: [String] = []
    @ObservationIgnored private var lastPaintedCell: TileMapCoordinate?
    @ObservationIgnored private var panStart: Point?
    @ObservationIgnored private var lastPinchScale: Float?
    @ObservationIgnored private var strokeChanged = false
    @ObservationIgnored private(set) var viewportSize = Size(width: 600, height: 400)

    var legacyPaletteCount: Int { max(map.atlasColors.count, tileImages.count) }
    var paletteCount: Int { legacyPaletteCount + (map.tileSetTiles?.count ?? 0) }

    init(document: EditorAssetDocument, onSave: (() -> Void)? = nil) {
        url = document.absolutePath.map { URL(fileURLWithPath: $0) }
        assetReference = document.assetReference
        self.onSave = onSave
        reload()
    }

    func reload() {
        guard let url else { status = "Map file is unavailable."; return }
        do {
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                status = "Symbolic-link maps are read-only."
                return
            }
            let data = try Data(contentsOf: url)
            map = try EditorTileMapResource.read(from: url)
            displayTileSize = Self.sceneTileSize(for: assetReference, mapURL: url) ?? Size(width: 24, height: 24)
            savedData = data
            paintedCells.removeAll(keepingCapacity: true)
            for cell in map.cells where cell.count >= 3 {
                paintedCells[TileMapCoordinate(x: cell[0], y: cell[1])] = cell[2]
            }
            tileImages = (map.atlasTextures ?? []).map { path in
                try? Image(contentsOf: URL(fileURLWithPath: path, relativeTo: url.deletingLastPathComponent()).standardizedFileURL)
            }
            tileTextures = tileImages.map { $0.map { Texture2D(image: $0) } }
            reloadLinkedTiles()
            lastPaintedCell = nil
            strokeChanged = false
            revision += 1
            status = "\(map.cells.count) cells"
        } catch { status = error.localizedDescription }
    }

    func color(atX x: Int, y: Int) -> Color? {
        guard let index = paintedCells[TileMapCoordinate(x: x, y: y)], index >= 0, index < paletteCount else { return nil }
        return paletteColor(at: index)
    }

    func paletteColor(at index: Int) -> Color {
        map.atlasColors.indices.contains(index) ? map.atlasColors[index] : .white
    }

    func paletteLabel(at index: Int) -> String {
        guard index >= legacyPaletteCount else { return "Tile \(index + 1)" }
        let linkedIndex = index - legacyPaletteCount
        guard (map.tileSetTiles ?? []).indices.contains(linkedIndex) else { return "Tile \(index + 1)" }
        let tile = map.tileSetTiles?[linkedIndex]
        let source = linkedNames.indices.contains(linkedIndex) ? linkedNames[linkedIndex] : "Tile Source"
        let xy = tile?.atlasCoordinates ?? []
        return xy.count == 2 ? "\(source)  \(xy[0]), \(xy[1])" : source
    }

    func tileIndex(atX x: Int, y: Int) -> Int? {
        paintedCells[TileMapCoordinate(x: x, y: y)]
    }

    func texture(at index: Int) -> Texture2D? {
        if index < legacyPaletteCount { return tileTextures.indices.contains(index) ? tileTextures[index] : nil }
        let linkedIndex = index - legacyPaletteCount
        return linkedTextures.indices.contains(linkedIndex) ? linkedTextures[linkedIndex] : nil
    }

    func image(at index: Int) -> Image? {
        if index < legacyPaletteCount { return tileImages.indices.contains(index) ? tileImages[index] : nil }
        let linkedIndex = index - legacyPaletteCount
        return linkedImages.indices.contains(linkedIndex) ? linkedImages[linkedIndex] : nil
    }

    func cell(at location: Point, in viewport: Size) -> (x: Int, y: Int) {
        let origin = canvasOrigin(in: viewport)
        return (
            Int(floor((location.x - origin.x) / cellWidth + 0.5)),
            Int(floor((origin.y - location.y) / cellHeight + 0.5))
        )
    }

    func tileRect(atX x: Int, y: Int, in viewport: Size) -> Rect {
        let origin = canvasOrigin(in: viewport)
        return Rect(
            x: origin.x + (Float(x) - 0.5) * cellWidth,
            y: origin.y - (Float(y) + 0.5) * cellHeight,
            width: cellWidth,
            height: cellHeight
        )
    }

    func canvasOrigin(in viewport: Size) -> Point {
        Point(x: viewport.width / 2 + panOffset.x, y: viewport.height / 2 + panOffset.y)
    }

    func updateViewportSize(_ size: Size) { viewportSize = size }

    func paint(at location: Point, in viewport: Size) {
        guard tool != .pan else { return }
        applyStroke(at: location, in: viewport, erasing: tool == .erase)
    }

    /// Erase with the secondary mouse button without changing the selected paint tool.
    func erase(at location: Point, in viewport: Size) {
        applyStroke(at: location, in: viewport, erasing: true)
    }

    private func applyStroke(at location: Point, in viewport: Size, erasing: Bool) {
        let coordinate = cell(at: location, in: viewport)
        let destination = TileMapCoordinate(x: coordinate.x, y: coordinate.y)
        if let lastPaintedCell {
            let steps = min(4_096, max(abs(destination.x - lastPaintedCell.x), abs(destination.y - lastPaintedCell.y)))
            if steps > 0 {
                for step in 1...steps {
                    let progress = Float(step) / Float(steps)
                    paintCell(TileMapCoordinate(
                        x: Int((Float(lastPaintedCell.x) + Float(destination.x - lastPaintedCell.x) * progress).rounded()),
                        y: Int((Float(lastPaintedCell.y) + Float(destination.y - lastPaintedCell.y) * progress).rounded())
                    ), erasing: erasing)
                }
            }
        } else {
            paintCell(destination, erasing: erasing)
        }
        lastPaintedCell = destination
    }

    func endStroke() {
        lastPaintedCell = nil
        guard strokeChanged else { return }
        strokeChanged = false
        var updated = map
        updated.cells = paintedCells.sorted {
            $0.key.y == $1.key.y ? $0.key.x < $1.key.x : $0.key.y < $1.key.y
        }.map { [$0.key.x, $0.key.y, $0.value] }
        save(updated)
    }

    func pan(by translation: Size) {
        let start = panStart ?? panOffset
        panStart = start
        panOffset = Point(x: start.x + translation.width, y: start.y + translation.height)
    }

    func endPan() { panStart = nil }

    func setZoom(_ value: Float) {
        setZoom(value, around: Point(x: viewportSize.width / 2, y: viewportSize.height / 2), in: viewportSize)
    }

    func setZoom(_ value: Float, around location: Point, in viewport: Size) {
        let next = min(4, max(0.5, value))
        guard next != zoom else { return }
        let ratio = next / zoom
        let offset = Point(x: location.x - viewport.width / 2, y: location.y - viewport.height / 2)
        panOffset = Point(
            x: offset.x - (offset.x - panOffset.x) * ratio,
            y: offset.y - (offset.y - panOffset.y) * ratio
        )
        zoom = next
    }

    func handleScroll(_ event: MouseEvent, at location: Point, in viewport: Size) {
        guard event.button == .scrollWheel, event.scrollDelta.x.isFinite, event.scrollDelta.y.isFinite else { return }
        if event.modifierKeys.contains(.main) || event.modifierKeys.contains(.control) {
            setZoom(zoom * pow(1.12, event.scrollDelta.y), around: location, in: viewport)
        } else {
            panOffset = Point(
                x: panOffset.x + event.scrollDelta.x * 72,
                y: panOffset.y + event.scrollDelta.y * 72
            )
        }
    }

    func handlePinch(_ event: PinchEvent, at location: Point, in viewport: Size) {
        guard event.scale.isFinite, event.scale > 0 else { return }
        if event.phase == .began { lastPinchScale = 1 }
        guard let previous = lastPinchScale else { return }
        if event.phase != .cancelled {
            setZoom(zoom * event.scale / previous, around: location, in: viewport)
        }
        lastPinchScale = event.phase == .ended || event.phase == .cancelled ? nil : event.scale
    }

    func fitMap(in viewport: Size) {
        guard let first = paintedCells.keys.first else {
            panOffset = .zero
            zoom = 1
            return
        }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for cell in paintedCells.keys {
            minX = min(minX, cell.x)
            maxX = max(maxX, cell.x)
            minY = min(minY, cell.y)
            maxY = max(maxY, cell.y)
        }
        let width = Float(maxX - minX + 1) * displayTileSize.width
        let height = Float(maxY - minY + 1) * displayTileSize.height
        zoom = min(4, max(0.5, min((viewport.width - 64) / width, (viewport.height - 64) / height)))
        panOffset = Point(
            x: -Float(minX + maxX) * cellWidth / 2,
            y: Float(minY + maxY) * cellHeight / 2
        )
    }

    private static func sceneTileSize(for reference: String?, mapURL: URL) -> Size? {
        guard let reference, reference.hasPrefix("@res://") else { return nil }
        let relativePath = String(reference.dropFirst("@res://".count))
        var assetsRoot = mapURL.standardizedFileURL
        for _ in relativePath.split(separator: "/") { assetsRoot.deleteLastPathComponent() }
        guard assetsRoot.appendingPathComponent(relativePath).standardizedFileURL == mapURL.standardizedFileURL else { return nil }
        let scenesURL = assetsRoot.appendingPathComponent("Scenes", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(at: scenesURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        let sceneURLs = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "ascn" }.sorted { $0.path < $1.path }
        for sceneURL in sceneURLs.prefix(128) {
            guard let source = try? String(contentsOf: sceneURL, encoding: .utf8), source.contains(reference),
                let scene = try? EditorSceneModel.decode(from: source) else { continue }
            for entity in scene.entities {
                guard let payload = entity.components[EditorBuiltInComponentType.tileMap],
                    payload["map"]?.stringValue == reference,
                    case let .array(dimensions)? = payload["tileDisplaySize"], dimensions.count >= 2,
                    let width = dimensions[0].doubleValue, let height = dimensions[1].doubleValue,
                    width.isFinite, height.isFinite, width > 0, height > 0,
                    width <= Double(Float.greatestFiniteMagnitude), height <= Double(Float.greatestFiniteMagnitude) else { continue }
                return Size(width: Float(width), height: Float(height))
            }
        }
        return nil
    }

    private func assetsRoot() -> URL? {
        guard let url, let assetReference, assetReference.hasPrefix("@res://") else { return nil }
        let relativePath = String(assetReference.dropFirst("@res://".count))
        var root = url.standardizedFileURL
        for _ in relativePath.split(separator: "/") { root.deleteLastPathComponent() }
        guard root.appendingPathComponent(relativePath).standardizedFileURL == url.standardizedFileURL else { return nil }
        return root
    }

    private func linkedTileSetURL() -> URL? {
        guard let url, let reference = map.tileSetReference else { return nil }
        if reference.hasPrefix("@res://") {
            return assetsRoot()?.appendingPathComponent(String(reference.dropFirst("@res://".count))).standardizedFileURL
        }
        return URL(fileURLWithPath: reference, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
    }

    private func reloadLinkedTiles() {
        let tiles = map.tileSetTiles ?? []
        linkedImages = Array(repeating: nil, count: tiles.count)
        linkedTextures = Array(repeating: nil, count: tiles.count)
        linkedNames = Array(repeating: "Tile Source", count: tiles.count)
        guard let tileSetURL = linkedTileSetURL() else {
            tileSetStatus = map.tileSetReference == nil ? "Link a Tile Source to add authored textures." : "Linked Tile Source is unavailable."
            return
        }
        do {
            let catalog = try EditorTileSetPalette.load(from: tileSetURL)
            let entries = Dictionary(catalog.map { ($0.reference, $0) }, uniquingKeysWith: { first, _ in first })
            for (index, tile) in tiles.enumerated() {
                guard let entry = entries[tile] else { continue }
                linkedImages[index] = entry.image
                linkedTextures[index] = Texture2D(image: entry.image)
                linkedNames[index] = entry.sourceName
            }
            let missing = linkedImages.filter { $0 == nil }.count
            tileSetStatus = missing == 0
                ? "\(tiles.count) linked tiles · \(tileSetURL.lastPathComponent)"
                : "\(missing) linked tiles are missing from \(tileSetURL.lastPathComponent)."
        } catch { tileSetStatus = error.localizedDescription }
    }

    func presentTileSetPicker() {
        guard let root = assetsRoot() else { status = "Save this map inside a project's Assets folder first."; return }
        ProjectOpenPicker.presentTileSetPicker(directoryURL: root) { [weak self] result in
            switch result {
            case let .selected(urls):
                if let url = urls.first { self?.linkTileSet(at: url) }
            case let .unavailable(message): self?.status = message
            case .cancelled: break
            }
        }
    }

    func linkTileSet(at selectedURL: URL) {
        guard let root = assetsRoot() else { status = "Map resource root is unavailable."; return }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let tileSetURL = selectedURL.resolvingSymlinksInPath().standardizedFileURL
        guard tileSetURL.pathExtension == "tileset", tileSetURL.path.hasPrefix(rootPath + "/") else {
            status = "Choose a .tileset file inside this project's Assets folder."
            return
        }
        do {
            let relativePath = String(tileSetURL.path.dropFirst(rootPath.count + 1))
            let reference = "@res://\(relativePath)"
            if map.tileSetReference == reference {
                refreshTileSet()
                return
            }
            if map.tileSetReference != nil, map.tileSetReference != reference,
                map.cells.contains(where: { $0.count >= 3 && $0[2] >= legacyPaletteCount }) {
                status = "Erase linked tiles before replacing this Tile Source."
                return
            }
            let catalog = try EditorTileSetPalette.load(from: tileSetURL)
            var updated = map
            updated.tileSetReference = reference
            updated.tileSetTiles = catalog.map(\.reference)
            guard save(updated) else { return }
            reload()
            status = "Linked \(catalog.count) tiles from \(tileSetURL.lastPathComponent)."
        } catch { status = error.localizedDescription }
    }

    func refreshTileSet() {
        guard let tileSetURL = linkedTileSetURL() else { status = "Link a Tile Source first."; return }
        do {
            let catalog = try EditorTileSetPalette.load(from: tileSetURL)
            var updated = map
            var existing = Set(updated.tileSetTiles ?? [])
            let added = catalog.map(\.reference).filter { existing.insert($0).inserted }
            guard !added.isEmpty else {
                reload()
                status = "Tile Source is up to date."
                return
            }
            updated.tileSetTiles = (updated.tileSetTiles ?? []) + added
            guard save(updated) else { return }
            reload()
            status = "Added \(added.count) tiles from \(tileSetURL.lastPathComponent)."
        } catch { status = error.localizedDescription }
    }

    func createTileSet() {
        guard map.tileSetReference == nil else { status = "A Tile Source is already linked. Open it to add textures."; return }
        guard let root = assetsRoot(), let url else { status = "Map resource root is unavailable."; return }
        let directory = root.appendingPathComponent("Tiles", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let base = url.deletingPathExtension().lastPathComponent
            var candidate = directory.appendingPathComponent("\(base).tileset")
            var suffix = 2
            while FileManager.default.fileExists(atPath: candidate.path) {
                candidate = directory.appendingPathComponent("\(base)-\(suffix).tileset")
                suffix += 1
            }
            try Data("tileSize:\n  x: 16\n  y: 16\nsources: []\n".utf8).write(to: candidate, options: .atomic)
            linkTileSet(at: candidate)
            status = "Created \(candidate.lastPathComponent). Open it in Assets, add PNGs and create tiles, then Refresh tiles here."
        } catch { status = error.localizedDescription }
    }

    func addColor() {
        let hex = newColorHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else {
            status = "Enter a six-digit RGB color."
            return
        }
        var updated = map
        let insertionIndex = legacyPaletteCount
        while updated.atlasColors.count < insertionIndex {
            updated.atlasColors.append(.white)
        }
        updated.atlasColors.append(Color(
            red: Float((rgb >> 16) & 0xFF) / 255,
            green: Float((rgb >> 8) & 0xFF) / 255,
            blue: Float(rgb & 0xFF) / 255
        ))
        for index in updated.cells.indices where updated.cells[index].count >= 3 && updated.cells[index][2] >= insertionIndex {
            updated.cells[index][2] += 1
        }
        guard save(updated) else { return }
        reload()
        selectedColor = insertionIndex
        tool = .paint
    }

    private func paintCell(_ cell: TileMapCoordinate, erasing: Bool) {
        if erasing {
            guard paintedCells.removeValue(forKey: cell) != nil else { return }
        } else {
            guard (0..<paletteCount).contains(selectedColor),
                selectedColor < legacyPaletteCount || image(at: selectedColor) != nil,
                paintedCells[cell] != selectedColor else { return }
            paintedCells[cell] = selectedColor
        }
        strokeChanged = true
        revision += 1
    }

    @discardableResult
    private func save(_ updated: EditorTileMapResource) -> Bool {
        guard let url, let savedData else { return false }
        do {
            guard try Data(contentsOf: url) == savedData else {
                reload()
                status = "File changed on disk. Reloaded; repeat your edit."
                return false
            }
            try updated.write(to: url)
            self.savedData = try Data(contentsOf: url)
            map = updated
            revision += 1
            status = "Saved \(updated.cells.count) cells"
            onSave?()
            return true
        } catch { status = error.localizedDescription; return false }
    }
}
