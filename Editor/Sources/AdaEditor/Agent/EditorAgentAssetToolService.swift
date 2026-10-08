import AdaEngine
import CoreFoundation
import Foundation
import MCP
import Yams

/// Portable authoring tools share the editor's actual image/atlas/tile codecs.
@MainActor
final class EditorAgentAssetToolService {
    private let projectURL: URL
    private let credentials: any EditorImageCredentialProviding
    private let imageClient: any EditorImageGenerationHTTPClient
    private let analyzeImage: (@MainActor ([URL], String) async throws -> String)?

    init(
        projectURL: URL,
        credentials: any EditorImageCredentialProviding = EditorOpenAIImageCredentialStore(),
        imageClient: any EditorImageGenerationHTTPClient = EditorImageHTTPClient(),
        analyzeImage: (@MainActor ([URL], String) async throws -> String)? = nil
    ) {
        self.projectURL = projectURL.resolvingSymlinksInPath().standardizedFileURL
        self.credentials = credentials
        self.imageClient = imageClient
        self.analyzeImage = analyzeImage
    }

    func saveCapturedFrame(_ data: Data) throws -> [String: Any] {
        guard data.count <= 24 * 1024 * 1024 else { throw Failure("Captured frame exceeds 24 MB.") }
        let root = try ProjectSystem.loadProject(at: projectURL).paths.assets ?? "Assets"
        let url = try assetURL(root + "/AgentCaptures/play-\(UUID()).png", extension: "png")
        try writeNew(data, to: url)
        return try imageInfo(url)
    }

    func execute(name: String, arguments: [String: Value]) async throws -> [String: Any] {
        if name.hasPrefix("editor.model."), name != "editor.model.texture.assign" {
            return try EditorAgentModelToolService(projectURL: projectURL).execute(name: name, arguments: arguments)
        }
        let path = try required("path", arguments, fallback: arguments["destination"]?.stringValue)
        switch name {
        case "editor.image.generate":
            let project = try ProjectSystem.loadProject(at: projectURL)
            let target = try assetURL(path)
            let generator = EditorAgentImageToolService(project: project, projectURL: projectURL, credentials: credentials, httpClient: imageClient)
            let destination = relative(target, to: try assetsURL())
            let prompt = try required("prompt", arguments)
            let result: EditorGeneratedImageAsset
            if let source = arguments["source"]?.stringValue, !source.isEmpty {
                _ = try assetURL(source)
                result = try await generator.edit(prompt: prompt, sourcePath: source, destinationPath: destination)
            } else {
                result = try await generator.generate(prompt: prompt, destinationPath: destination)
            }
            return try imageInfo(projectURL.appendingPathComponent(result.relativePath))
        case "editor.image.read":
            let url = try assetURL(path)
            var info = try imageInfo(url)
            guard let analyzeImage else { throw Failure("The image analysis model is not configured in this host.") }
            info["analysis"] = try await analyzeImage([url], required("question", arguments))
            return info
        case "editor.texture.render":
            let url = try assetURL(path, extension: "png")
            let spec = try object(required("specJSON", arguments))
            let width = try integer(spec["width"] ?? 256, in: 1...2048)
            let height = try integer(spec["height"] ?? width, in: 1...2048)
            let cell = try integer(spec["cellSize"] ?? 16, in: 1...2048)
            let colors = try (spec["colors"] as? [[Double]] ?? [[1, 1, 1, 1], [0.12, 0.12, 0.12, 1]]).map(color)
            guard !colors.isEmpty, colors.count <= 16 else { throw Failure("Provide 1...16 RGBA colors.") }
            let pattern = spec["pattern"] as? String ?? "solid"
            guard ["solid", "checker", "gradient", "noise", "normal"].contains(pattern) else { throw Failure("Unknown texture pattern.") }
            let seed = try integer(spec["seed"] ?? 1, in: 0...Int(Int32.max))
            var image = Image(width: width, height: height)
            for y in 0..<height {
                for x in 0..<width {
                    let pixel: Color
                    switch pattern {
                    case "normal": pixel = Color(red: 0.5, green: 0.5, blue: 1)
                    case "checker": pixel = colors[(x / cell + y / cell) % colors.count]
                    case "gradient":
                        let t = Float(x) / Float(max(1, width - 1))
                        let a = colors[0]
                        let b = colors.last ?? a
                        pixel = Color(
                            red: a.red + (b.red - a.red) * t,
                            green: a.green + (b.green - a.green) * t,
                            blue: a.blue + (b.blue - a.blue) * t,
                            alpha: a.alpha + (b.alpha - a.alpha) * t
                        )
                    case "noise":
                        var n = UInt32(truncatingIfNeeded: seed) ^ (UInt32(x) &* 73_856_093) ^ (UInt32(y) &* 19_349_663)
                        n ^= n >> 13
                        n = n &* 1_274_126_177
                        pixel = colors[Int(n % UInt32(colors.count))]
                    default: pixel = colors[0]
                    }
                    image.setPixel(in: Point(Float(x), Float(y)), color: pixel)
                }
            }
            try writeNew(EditorImageAttachment.encodePNG(image), to: url)
            return try imageInfo(url)
        case "editor.atlas.read", "editor.atlas.pack", "editor.atlas.write":
            let url = try assetURL(path, extension: "atlas")
            let descriptor: NamedTextureAtlas.Descriptor
            if name == "editor.atlas.write" {
                descriptor = try JSONDecoder().decode(NamedTextureAtlas.Descriptor.self, from: Data(required("descriptorJSON", arguments).utf8))
            } else {
                descriptor = try YAMLDecoder().decode(NamedTextureAtlas.Descriptor.self, from: text(url))
            }
            let packed = try pack(descriptor, at: url)
            if name == "editor.atlas.write" { try save(Data(YAMLEncoder().encode(descriptor).utf8), to: url) }
            var result: [String: Any] = ["path": path, "descriptor": try json(descriptor), "width": packed.image.width, "height": packed.image.height, "regions": try json(packed.regions)]
            if name == "editor.atlas.pack" {
                let preview = try assetURL(required("previewPath", arguments), extension: "png")
                try writeNew(EditorImageAttachment.encodePNG(packed.image), to: preview)
                result["preview"] = try imageInfo(preview)
            }
            return result
        case "editor.tileset.create":
            let url = try assetURL(path, extension: "tileset")
            let imageURL = try assetURL(required("image", arguments))
            let image = try loadImage(imageURL)
            let w = try argumentInteger("tileWidth", arguments, in: 1...4096)
            let h = try argumentInteger("tileHeight", arguments, in: 1...4096)
            let descriptor = TileSourceImageDescriptor(path: relative(imageURL, to: url.deletingLastPathComponent()), tileSize: [w, h])
            let grid = descriptor.gridSize(imageSize: [image.width, image.height])
            guard grid.width > 0, grid.height > 0, grid.width * grid.height <= 4096 else { throw Failure("Expected 1...4096 complete tiles in the image grid.") }
            let tiles = (0..<grid.height).flatMap { y in (0..<grid.width).map { x in tile(x: x, y: y) } }
            let root: [String: Any] = [
                "tileSize": ["x": w, "y": h],
                "sources": [
                    [
                        "type": String(reflecting: TextureAtlasTileSource.self),
                        "data": ["id": 1, "name": imageURL.deletingPathExtension().lastPathComponent, "image": try json(descriptor), "tiles": tiles],
                    ]
                ],
            ]
            try writeNew(Data(Yams.dump(object: root).utf8), to: url)
            return try tilesetInfo(url)
        case "editor.tileset.read": return try tilesetInfo(assetURL(path, extension: "tileset"))
        case "editor.tileset.edit":
            return try editTileset(at: assetURL(path, extension: "tileset"), operations: operations(arguments))
        case "editor.tilemap.read":
            let url = try assetURL(path, extension: "tilemap")
            let map = try EditorTileMapResource.read(from: url)
            try validate(map, at: url)
            return ["path": path, "resource": try json(map), "paletteIndexes": "zero-based"]
        case "editor.tilemap.write":
            let url = try assetURL(path, extension: "tilemap")
            var map = try JSONDecoder().decode(EditorTileMapResource.self, from: Data(required("resourceJSON", arguments).utf8))
            if let reference = map.tileSetReference, map.tileSetTiles == nil {
                let tileset = try referencedURL(reference, from: url)
                try validateTileSources(at: tileset)
                map.tileSetTiles = try EditorTileSetPalette.load(from: tileset).map(\.reference)
            }
            try validate(map, at: url)
            try save(Data(YAMLEncoder().encode(map).utf8), to: url)
            return ["path": path, "resource": try json(map)]
        case "editor.tilemap.edit":
            return try editMap(at: assetURL(path, extension: "tilemap"), operations: operations(arguments))
        case "editor.scene.asset.assign":
            let url = try assetURL(path, extension: "ascn")
            let asset = try assetURL(required("asset", arguments))
            guard FileManager.default.fileExists(atPath: asset.path) else { throw Failure("Asset does not exist.") }
            var scene = try EditorSceneModel.decode(from: text(url))
            let id = try required("entityID", arguments)
            let component = try required("component", arguments)
            let key = try required("field", arguments)
            guard let index = scene.entities.firstIndex(where: { $0.id == id }),
                let descriptor = EditorComponentRegistry.descriptor(named: component),
                let field = descriptor.fields.first(where: { $0.key == key && ($0.kind == .assetReference || $0.kind == .sceneReference) })
            else {
                throw Failure("Unknown entity, component or asset field. Use editor.components.describe.")
            }
            var payload = scene.entities[index].components[component] ?? descriptor.makeDefaultPayload()
            field.write(try reference(asset), to: &payload)
            for required in descriptor.requiredComponentTypeNames where scene.entities[index].components[required] == nil {
                scene.entities[index].components[required] = EditorComponentRegistry.defaultPayload(for: required)
            }
            scene.entities[index].components[component] = payload
            try save(Data(scene.encodedYAML().utf8), to: url)
            return ["path": path, "entityID": id, "assetReference": try reference(asset), "requiresRebuild": true]
        case "editor.model.texture.assign":
            let url = try assetURL(path)
            let texture = try assetURL(required("texture", arguments))
            _ = try loadImage(texture)
            let index = try argumentInteger("material", arguments, in: 0...1024, default: 0)
            return try EditorAgentModelTextureTools.assign(
                model: url,
                textureURI: relative(texture, to: url.deletingLastPathComponent()),
                channel: required("channel", arguments),
                material: index
            )
        case "editor.asset.validate":
            switch URL(fileURLWithPath: path).pathExtension.lowercased() {
            case "glb", "gltf":
                return try EditorAgentModelToolService(projectURL: projectURL).execute(name: "editor.model.validate", arguments: arguments)
            case "atlas": return try await execute(name: "editor.atlas.read", arguments: arguments)
            case "tileset": return try await execute(name: "editor.tileset.read", arguments: arguments)
            case "tilemap": return try await execute(name: "editor.tilemap.read", arguments: arguments)
            default: return try imageInfo(assetURL(path))
            }
        default: throw Failure("Unknown asset operation.")
        }
    }

    private func pack(_ descriptor: NamedTextureAtlas.Descriptor, at url: URL) throws -> NamedTextureAtlas.PackedImages {
        guard (1...256).contains(descriptor.images.count), (0...64).contains(descriptor.padding), (0...64).contains(descriptor.margin), (0...16).contains(descriptor.extrude) else {
            throw Failure("Atlas settings exceed the authoring limits.")
        }
        var images: [String: Image] = [:]
        var pixels = 0
        for source in descriptor.images {
            let file = try referencedURL(source.path, from: url)
            let key = source.key ?? file.deletingPathExtension().lastPathComponent
            guard images[key] == nil, !key.isEmpty else { throw Failure("Duplicate or empty atlas key: \(key)") }
            let image = try loadImage(file)
            pixels += image.width * image.height
            guard pixels <= 16_777_216 else { throw Failure("Atlas sources exceed 16 million pixels.") }
            images[key] = image
        }
        var bounded = descriptor
        if let size = bounded.maxSize {
            guard size.width > 0, size.height > 0, size.width <= 4096, size.height <= 4096 else { throw Failure("Atlas maxSize must be within 4096x4096.") }
        } else {
            bounded.maxSize = [4096, 4096]
        }
        return try NamedTextureAtlas.packImages(images, descriptor: bounded)
    }

    private func tilesetInfo(_ url: URL) throws -> [String: Any] {
        try validateTileSources(at: url)
        let palette = try EditorTileSetPalette.load(from: url)
        return [
            "path": relative(url, to: projectURL), "resource": try Yams.load(yaml: text(url)) as Any,
            "palette": try palette.enumerated().map {
                ["index": $0.offset, "reference": try json($0.element.reference), "width": $0.element.image.width, "height": $0.element.image.height] as [String: Any]
            },
        ]
    }

    private func validateTileSources(at url: URL) throws {
        guard let root = try Yams.load(yaml: text(url)) as? [String: Any], let sources = root["sources"] as? [[String: Any]], sources.count <= 64 else {
            throw Failure("Invalid tile sources.")
        }
        for source in sources {
            guard source["type"] as? String == String(reflecting: TextureAtlasTileSource.self), let data = source["data"] as? [String: Any], let image = data["image"] else {
                throw Failure("Unsupported tile source.")
            }
            let descriptor = try YAMLDecoder().decode(TileSourceImageDescriptor.self, from: Yams.dump(object: image))
            try descriptor.validate()
            let loaded = try loadImage(referencedURL(descriptor.path, from: url))
            let grid = descriptor.gridSize(imageSize: [loaded.width, loaded.height])
            let tiles = data["tiles"] as? [[String: Any]] ?? []
            guard tiles.count <= 4096 else { throw Failure("Too many tile definitions.") }
            var coordinates: Set<[Int]> = []
            for tile in tiles {
                guard let xy = tile["xy"] as? [Int], xy.count == 2, (0..<grid.width).contains(xy[0]), (0..<grid.height).contains(xy[1]), coordinates.insert(xy).inserted else {
                    throw Failure("Tile coordinates are duplicated or outside the image grid.")
                }
            }
        }
    }

    private func validate(_ map: EditorTileMapResource, at url: URL) throws {
        guard map.effectiveLayers.count <= 32, map.allCells.count <= 262_144 else { throw Failure("Tile map exceeds layer/cell limits.") }
        var count = max(map.atlasColors.count, map.atlasTextures?.count ?? 0)
        for path in map.atlasTextures ?? [] { _ = try loadImage(referencedURL(path, from: url)) }
        if let path = map.tileSetReference {
            let source = try referencedURL(path, from: url)
            try validateTileSources(at: source)
            let palette = try EditorTileSetPalette.load(from: source)
            if let tiles = map.tileSetTiles {
                guard tiles.allSatisfy({ tile in palette.contains { $0.reference == tile } }) else { throw Failure("Map references an undefined tile.") }
                count += tiles.count
            }
        }
        for layer in map.effectiveLayers {
            var positions: Set<[Int]> = []
            for cell in layer.cells {
                guard cell.count == 3, (-32767...32767).contains(cell[0]), (-32767...32767).contains(cell[1]), (0..<count).contains(cell[2]), positions.insert(Array(cell.prefix(2))).inserted
                else { throw Failure("Invalid/duplicate cell or palette index in layer \(layer.name).") }
            }
        }
    }

    private func editMap(at url: URL, operations: [[String: Any]]) throws -> [String: Any] {
        var map = try EditorTileMapResource.read(from: url)
        try validate(map, at: url)
        var layers = map.effectiveLayers
        for operation in operations {
            let kind = operation["op"] as? String ?? ""
            if kind == "addLayer" {
                guard let name = operation["name"] as? String, !name.isEmpty, layers.count < 32, !layers.contains(where: { $0.name == name }) else {
                    throw Failure("Provide a unique layer name.")
                }
                layers.append(.init(name: name, zIndex: layers.count, isEnabled: true, cells: []))
                continue
            }
            let index = try integer(operation["layer"] ?? 0, in: 0...max(0, layers.count - 1))
            let x = try integer(operation["x"] as Any, in: -32767...32767)
            let y = try integer(operation["y"] as Any, in: -32767...32767)
            let width = kind == "fill" ? try integer(operation["width"] as Any, in: 1...512) : 1
            let height = kind == "fill" ? try integer(operation["height"] as Any, in: 1...512) : 1
            guard ["paint", "erase", "fill"].contains(kind), x + width <= 32768, y + height <= 32768 else { throw Failure("Invalid tilemap operation.") }
            let selected = kind == "erase" ? nil : try integer(operation["tile"] as Any, in: 0...65535)
            var cells = Dictionary(uniqueKeysWithValues: layers[index].cells.filter { $0.count == 3 }.map { (Array($0.prefix(2)), $0[2]) })
            for row in y..<(y + height) { for column in x..<(x + width) { cells[[column, row]] = selected } }
            layers[index].cells = cells.keys.sorted { $0[1] == $1[1] ? $0[0] < $1[0] : $0[1] < $1[1] }.map { [$0[0], $0[1], cells[$0] ?? 0] }
        }
        map.cells = []
        map.paletteLayers = layers
        try validate(map, at: url)
        try save(Data(YAMLEncoder().encode(map).utf8), to: url)
        return ["resource": try json(map), "requiresRebuild": true]
    }

    private func editTileset(at url: URL, operations: [[String: Any]]) throws -> [String: Any] {
        try validateTileSources(at: url)
        guard var root = try Yams.load(yaml: text(url)) as? [String: Any], var sources = root["sources"] as? [[String: Any]] else { throw Failure("Invalid tileset.") }
        for op in operations {
            let id = try integer(op["sourceID"] ?? 1, in: 0...65535)
            guard let index = sources.firstIndex(where: { ($0["data"] as? [String: Any])?["id"] as? Int == id }), var data = sources[index]["data"] as? [String: Any] else {
                throw Failure("Unknown source ID.")
            }
            var tiles = data["tiles"] as? [[String: Any]] ?? []
            let x = try integer(op["x"] as Any, in: 0...4096)
            let y = try integer(op["y"] as Any, in: 0...4096)
            let xy = [x, y]
            let tileIndex = tiles.firstIndex { $0["xy"] as? [Int] == xy }
            switch op["op"] as? String {
            case "define": if tileIndex == nil { tiles.append(tile(x: x, y: y)) }
            case "remove":
                // Removing a tile can invalidate both stable references and numeric palettes.
                guard !(try mapsReferencing(url)) else { throw Failure("A tile map uses this tileset; repair its palette/references before removing tiles.") }
                if let tileIndex { tiles.remove(at: tileIndex) }
            case "animate":
                guard let tileIndex else { throw Failure("Define this tile first.") }
                let frames = try integer(op["frames"] as Any, in: 1...4096)
                let duration = (op["duration"] as? Double) ?? 0
                guard duration.isFinite, duration > 0, let descriptorObject = data["image"] else { throw Failure("Animation duration must be positive.") }
                let layout = try YAMLDecoder().decode(TileSourceImageDescriptor.self, from: Yams.dump(object: descriptorObject))
                let image = try loadImage(referencedURL(layout.path, from: url))
                let grid = layout.gridSize(imageSize: [image.width, image.height])
                let vertical = op["vertical"] as? Bool ?? false
                guard frames <= (vertical ? grid.height - y : grid.width - x) else { throw Failure("Animation extends outside the texture grid.") }
                var metadata = tiles[tileIndex]["ad"] as? [String: Any] ?? [:]
                metadata["anim_fr_clm"] = frames
                metadata["anim_dur"] = duration
                metadata["anim_alig"] = vertical ? 0 : 1
                tiles[tileIndex]["ad"] = metadata
            default: throw Failure("Unknown tileset operation.")
            }
            data["tiles"] = tiles
            sources[index]["data"] = data
        }
        root["sources"] = sources
        let encoded = Data(try Yams.dump(object: root).utf8)
        // Validate in memory before committing; the palette decoder validates the persisted result on read.
        for source in sources {
            guard let data = source["data"] as? [String: Any], let descriptorObject = data["image"] else { throw Failure("Invalid tile source.") }
            let layout = try YAMLDecoder().decode(TileSourceImageDescriptor.self, from: Yams.dump(object: descriptorObject))
            let image = try loadImage(referencedURL(layout.path, from: url))
            let grid = layout.gridSize(imageSize: [image.width, image.height])
            for tile in data["tiles"] as? [[String: Any]] ?? [] {
                guard let xy = tile["xy"] as? [Int], xy.count == 2, (0..<grid.width).contains(xy[0]), (0..<grid.height).contains(xy[1]) else {
                    throw Failure("Tile lies outside the image grid.")
                }
            }
        }
        try save(encoded, to: url)
        return try tilesetInfo(url)
    }

    private func mapsReferencing(_ url: URL) throws -> Bool {
        guard let iterator = FileManager.default.enumerator(at: try assetsURL(), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return false
        }
        for case let file as URL in iterator where file.pathExtension == "tilemap" {
            let checked = try assetURL(relative(file, to: projectURL))
            if let reference = try EditorTileMapResource.read(from: checked).tileSetReference, try referencedURL(reference, from: checked) == url {
                return true
            }
        }
        return false
    }

    private func tile(x: Int, y: Int) -> [String: Any] {
        ["xy": [x, y], "ad": ["anim_dur": 1.0, "anim_fr_clm": 1, "anim_alig": 1, "td": ["mColor": ["red": 1.0, "green": 1.0, "blue": 1.0, "alpha": 1.0], "f_h": false, "f_v": false]]]
    }

    private func imageInfo(_ url: URL) throws -> [String: Any] {
        let image = try loadImage(url)
        return ["path": relative(url, to: projectURL), "assetReference": try reference(url), "width": image.width, "height": image.height, "format": String(describing: image.format)]
    }

    private func loadImage(_ url: URL) throws -> Image {
        let info = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (info.fileSize ?? 0) <= 24 * 1024 * 1024, let image = EditorImageAttachment.image(at: url), image.width * image.height <= 16_777_216 else {
            throw Failure("Expected a supported image up to 24 MB and 16 million pixels.")
        }
        return image
    }

    private func assetsURL() throws -> URL {
        let project = try ProjectSystem.loadProject(at: projectURL)
        let url = projectURL.appendingPathComponent(project.paths.assets ?? "Assets").resolvingSymlinksInPath().standardizedFileURL
        guard url.pathComponents.starts(with: projectURL.pathComponents), url.pathComponents.count > projectURL.pathComponents.count else {
            throw Failure("Assets directory is outside the project.")
        }
        return url
    }

    private func assetURL(_ path: String, extension ext: String? = nil) throws -> URL {
        guard !path.hasPrefix("/"), !path.hasPrefix("~"), !path.isEmpty else { throw Failure("Use a project-relative Assets path.") }
        let url = projectURL.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        let root = try assetsURL()
        guard url.pathComponents.starts(with: root.pathComponents), url.pathComponents.count > root.pathComponents.count,
            ext == nil || url.pathExtension.lowercased() == ext
        else { throw Failure("Asset path is outside Assets or has the wrong extension.") }
        return url
    }

    private func referencedURL(_ path: String, from source: URL) throws -> URL {
        let url = path.hasPrefix("@res://") ? try assetsURL().appendingPathComponent(String(path.dropFirst(7))) : source.deletingLastPathComponent().appendingPathComponent(path)
        return try assetURL(relative(url.standardizedFileURL.resolvingSymlinksInPath(), to: projectURL))
    }

    private func reference(_ url: URL) throws -> String { "@res://" + relative(url, to: try assetsURL()) }
    private func relative(_ url: URL, to base: URL) -> String {
        let a = base.standardizedFileURL.pathComponents
        let b = url.standardizedFileURL.pathComponents
        var common = 0
        while common < min(a.count, b.count), a[common] == b[common] { common += 1 }
        return (Array(repeating: "..", count: a.count - common) + Array(b.dropFirst(common))).joined(separator: "/")
    }
    private func text(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard data.count <= 8 * 1024 * 1024 else { throw Failure("Resource file exceeds 8 MB.") }
        return try EditorAgentToolEncoding.string(data)
    }
    private func save(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
    private func writeNew(_ data: Data, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure("Destination exists: \(relative(url, to: projectURL))") }
        try save(data, to: url)
    }
    private func json<T: Encodable>(_ value: T) throws -> Any {
        try Yams.load(yaml: YAMLEncoder().encode(value)) ?? NSNull()
    }
    private func required(_ key: String, _ arguments: [String: Value], fallback: String? = nil) throws -> String {
        guard let value = arguments[key]?.stringValue ?? fallback, !value.isEmpty else { throw Failure("Missing \(key).") }
        return value
    }
    private func object(_ value: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else { throw Failure("Expected a JSON object.") }
        return object
    }
    private func operations(_ arguments: [String: Value]) throws -> [[String: Any]] {
        guard let values = try JSONSerialization.jsonObject(with: Data(required("operationsJSON", arguments).utf8)) as? [[String: Any]], values.count <= 1024 else {
            throw Failure("Expected up to 1024 operations.")
        }
        return values
    }
    private func integer(_ value: Any, in range: ClosedRange<Int>) throws -> Int {
        // NSNumber preserves the distinction between JSON booleans and numbers.
        // swiftlint:disable:next legacy_objc_type
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            let result = Int(exactly: number.doubleValue), range.contains(result)
        else { throw Failure("Expected an integer in \(range).") }
        return result
    }
    private func argumentInteger(_ key: String, _ arguments: [String: Value], in range: ClosedRange<Int>, default fallback: Int? = nil) throws -> Int {
        if let value = arguments[key], value != .null {
            guard let number = value.doubleValue else { throw Failure("Expected numeric \(key).") }
            return try integer(number, in: range)
        }
        guard let fallback else { throw Failure("Missing \(key).") }
        return fallback
    }
    private func color(_ rgba: [Double]) throws -> Color {
        guard rgba.count == 4, rgba.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw Failure("Colors must be four finite values in 0...1.") }
        return Color(red: Float(rgba[0]), green: Float(rgba[1]), blue: Float(rgba[2]), alpha: Float(rgba[3]))
    }
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
