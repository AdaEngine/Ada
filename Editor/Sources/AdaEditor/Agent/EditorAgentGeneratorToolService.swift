import AdaAssets
import AdaEngine
import AdaScripting
import Foundation
import MCP

/// Runs an agent-authored AdaScript generator in an isolated VM and saves the result as an asset:
/// `editor.voxel.generate` writes a MagicaVoxel `.vox`, `editor.model.generate` a binary glTF `.glb`,
/// `editor.audio.generate` a 16-bit PCM `.wav` and `editor.sprite.generate` a `.png` plus, for
/// frame scripts, an Aseprite-compatible `.sheet.json` sidecar. `editor.audio.inspect` measures an
/// existing WAV file without any script. `editor.palette.extract` turns a reference image into a
/// user palette under `.ada/workspace/pixel-art/palettes`, and `editor.sprite.gif` renders a sheet
/// or sprite as an animated GIF preview.
@MainActor
struct EditorAgentGeneratorToolService {
    static let toolNames: Set<String> = [
        "editor.voxel.generate", "editor.model.generate", "editor.audio.generate", "editor.sprite.generate",
        "editor.audio.inspect", "editor.palette.extract", "editor.sprite.gif",
    ]
    static let pixelArtWorkspace = ".ada/workspace/pixel-art/"

    static func isRecipePath(_ path: String) -> Bool {
        guard path.hasPrefix(pixelArtWorkspace) else {
            return false
        }
        let name = path.dropFirst(pixelArtWorkspace.count)
        return name.count > 5 && name.lowercased().hasSuffix(".adas")
            && !name.contains("/") && !name.contains("\\") && !name.contains(":")
            && !name.unicodeScalars.contains { $0.value < 32 }
    }

    private let projectURL: URL

    init(projectURL: URL) {
        self.projectURL = projectURL.resolvingSymlinksInPath().standardizedFileURL
    }

    func execute(name: String, arguments: [String: Value]) throws -> [String: Any] {
        guard Self.toolNames.contains(name) else { throw Failure("Unknown generator tool: \(name)") }
        if name == "editor.audio.inspect" {
            return try inspectAudio(arguments)
        }
        if name == "editor.palette.extract" {
            return try extractPalette(arguments)
        }
        if name == "editor.sprite.gif" {
            return try renderGIF(arguments)
        }
        if name == "editor.sprite.generate" {
            return try generateSprite(arguments)
        }
        guard let source = arguments["source"]?.stringValue, !source.isEmpty else { throw Failure("Missing source.") }
        guard let destination = arguments["destination"]?.stringValue, !destination.isEmpty else { throw Failure("Missing destination.") }
        let (fileExtension, result) = try Self.generation(for: name)
        let url = try destinationURL(destination, extension: fileExtension)
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw Failure("Destination exists: \(destination). Choose a new name; existing assets are preserved.")
        }
        let generated: (Data, [String: Any])
        do {
            generated = try result(source)
        } catch let error as AdaScriptError {
            throw Failure("Generator script failed: \(error.description)")
        }
        let data = generated.0
        var summary = generated.1
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        summary["path"] = destination
        summary["assetReference"] = try reference(url)
        summary["bytes"] = data.count
        summary["requiresRebuild"] = true
        return summary
    }

    // MARK: - Generators

    private typealias Generate = @MainActor (String) throws -> (Data, [String: Any])

    private static func generation(for name: String) throws -> (String, Generate) {
        switch name {
        case "editor.voxel.generate": ("vox", voxel)
        case "editor.model.generate": ("glb", model)
        case "editor.audio.generate": ("wav", sound)
        default: throw Failure("Unknown generator tool: \(name)")
        }
    }

    private static let voxel: Generate = { source in
        let result = try AdaScriptVoxelGenerator.generate(source: source)
        return (
            try VOXWriter().encode(model: result.model, palette: result.palette),
            [
                "size": [result.model.sizeX, result.model.sizeY, result.model.sizeZ],
                "voxelCount": result.model.voxels.count,
                "paletteIndicesUsed": Set(result.model.voxels.map(\.colorIndex)).sorted().map { Int($0) },
            ]
        )
    }

    private static let model: Generate = { source in
        let model = try AdaScriptModelGenerator.generate(source: source)
        let meshes = model.nodes.compactMap(\.mesh)
        return (
            try GLBWriter().encode(model),
            [
                "parts": model.nodes.map { node -> [String: Any] in
                    var part: [String: Any] = ["name": node.name, "hasMesh": node.mesh != nil]
                    if let parent = node.parent { part["parent"] = model.nodes[parent].name }
                    return part
                },
                "materials": model.materials.map(\.name),
                "vertexCount": meshes.reduce(0) { $0 + $1.positions.count },
                "triangleCount": meshes.reduce(0) { $0 + $1.indices.count / 3 },
            ]
        )
    }

    private static let sound: Generate = { source in
        let audio = try AdaScriptSoundGenerator.generate(source: source)
        return (try WAVWriter().encode(audio), report(AudioAnalyzer.analyze(audio)))
    }

    // MARK: - Sprite generation with palettes, layers and frames

    private func generateSprite(_ arguments: [String: Value]) throws -> [String: Any] {
        guard let source = arguments["source"]?.stringValue, !source.isEmpty else { throw Failure("Missing source.") }
        guard let destination = arguments["destination"]?.stringValue, !destination.isEmpty else { throw Failure("Missing destination.") }
        let url = try destinationURL(destination, extension: "png")
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw Failure("Destination exists: \(destination). Choose a new name; existing assets are preserved.")
        }
        let result: AdaScriptSpriteResult
        do {
            result = try AdaScriptSpriteGenerator.generate(source: source, userPalettes: userPalettes())
        } catch let error as AdaScriptError {
            throw Failure("Generator script failed: \(error.description)")
        }
        let canvas = result.canvas
        let recipe = arguments["recipe"]?.stringValue
        if let recipe, !Self.isRecipePath(recipe) {
            throw Failure("Use a recipe path under \(Self.pixelArtWorkspace) ending in .adas.")
        }
        let sidecarURL = url.deletingPathExtension().appendingPathExtension("sheet.json")
        let sidecar: Data?
        if result.frameCount > 1 {
            guard !FileManager.default.fileExists(atPath: sidecarURL.path) else {
                throw Failure("Sheet sidecar already exists. Choose a new destination.")
            }
            let metadata = spriteSidecar(result, destination: destination, recipe: recipe)
            sidecar = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        } else {
            sidecar = nil
        }
        let data = try PNGWriter().encode(width: canvas.width, height: canvas.height, rgba: canvas.rgba())
        let assetReference = try reference(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .withoutOverwriting)
        var summary: [String: Any] = [
            "size": [canvas.width, canvas.height],
            "opaquePixels": canvas.opaquePixelCount,
            "paletteIndicesUsed": canvas.usedColors.map { Int($0) },
            "hint": "Show the PNG or an exported GIF in native Studio chat with an A2UI Image component.",
        ]
        if let sidecar {
            do {
                try sidecar.write(to: sidecarURL, options: .withoutOverwriting)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            summary["frames"] = result.frameCount
            summary["frameWidth"] = result.frameWidth
            summary["frameDurations"] = result.frameDurations
            summary["tags"] = result.tags.map(\.name)
            summary["sheet"] = String(destination.dropLast(4)) + ".sheet.json"
        }
        if !result.layers.isEmpty { summary["layers"] = result.layers }
        summary["path"] = destination
        summary["assetReference"] = assetReference
        summary["bytes"] = data.count
        summary["requiresRebuild"] = true
        return summary
    }

    /// The Aseprite sheet shape `AsepriteImport` reads, plus the recipe path for traceability.
    private func spriteSidecar(_ result: AdaScriptSpriteResult, destination: String, recipe: String?) -> [String: Any] {
        let stem = URL(fileURLWithPath: destination).deletingPathExtension().lastPathComponent
        let frames = (0..<result.frameCount).map { index in
            [
                "filename": "\(stem) \(index)",
                "frame": ["x": index * result.frameWidth, "y": 0, "w": result.frameWidth, "h": result.canvas.height],
                "rotated": false,
                "trimmed": false,
                "duration": result.frameDurations[index],
            ] as [String: Any]
        }
        var meta: [String: Any] = [
            "image": URL(fileURLWithPath: destination).lastPathComponent,
            "size": ["w": result.canvas.width, "h": result.canvas.height],
            "frameTags": result.tags.map { ["name": $0.name, "from": $0.from, "to": $0.to, "direction": "forward"] as [String: Any] },
        ]
        meta["layers"] = result.layers
        if let recipe { meta["recipe"] = recipe }
        return ["frames": frames, "meta": meta]
    }

    // MARK: - User palettes

    private func extractPalette(_ arguments: [String: Value]) throws -> [String: Any] {
        guard let image = arguments["image"]?.stringValue, !image.isEmpty else { throw Failure("Missing image.") }
        guard let name = arguments["name"]?.stringValue, Self.validPaletteName(name) else {
            throw Failure("Missing or invalid name: use 1...32 of A-Z a-z 0-9 _ -, starting with a letter or digit.")
        }
        let maximumColors = arguments["maxColors"]?.intValue ?? PixelPaletteExtractor.defaultMaximumColors
        let url = try destinationURL(image, extension: "png", mustExist: true)
        let decoded = try Image(contentsOf: url)
        let colors = PixelPaletteExtractor.extract(rgba: [UInt8](decoded.data), maximumColors: maximumColors)
        guard !colors.isEmpty else { throw Failure("The image has no opaque pixels to extract colors from.") }
        let palettePath = Self.pixelArtWorkspace + "palettes/\(name).json"
        let paletteURL = try workspaceURL(palettePath)
        guard !FileManager.default.fileExists(atPath: paletteURL.path) else {
            throw Failure("Palette exists: \(name). Choose a new name; existing palettes are preserved.")
        }
        let document: [String: Any] = [
            "name": name,
            "description": "Extracted from \(image) by editor.palette.extract.",
            "max_colors": colors.count,
            "colors": colors.map { String(format: "#%02X%02X%02X", $0.red, $0.green, $0.blue) },
        ]
        try FileManager.default.createDirectory(at: paletteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]).write(to: paletteURL, options: .withoutOverwriting)
        return [
            "name": name,
            "colors": document["colors"] ?? [],
            "count": colors.count,
            "path": palettePath,
            "hint": "Use sprite.palettePreset(\"user:\(name)\") in editor.sprite.generate. One palette per game keeps the style consistent.",
        ]
    }

    private static func validPaletteName(_ name: String) -> Bool {
        guard let first = name.first, first.isLetter || first.isNumber, name.count <= 32 else {
            return false
        }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
    }

    /// User palettes saved by `editor.palette.extract`; the sprite VM resolves `user:<name>` presets from them.
    private func userPalettes() -> [String: [PixelColor]] {
        let palettePath = Self.pixelArtWorkspace + "palettes"
        guard let directory = try? workspaceURL(palettePath),
              let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [:] }
        var palettes: [String: [PixelColor]] = [:]
        for file in files where file.hasSuffix(".json") {
            guard let url = try? workspaceURL(palettePath + "/" + file),
                  let data = try? Data(contentsOf: url),
                  let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hexes = document["colors"] as? [String]
            else { continue }
            let colors = hexes.compactMap(Self.color(fromHex:))
            if !colors.isEmpty, colors.count <= 255 {
                palettes[String(file.dropLast(5))] = colors
            }
        }
        return palettes
    }

    private static func color(fromHex hex: String) -> PixelColor? {
        var text = hex
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else {
            return nil
        }
        return PixelColor(red: UInt8((value >> 16) & 0xFF), green: UInt8((value >> 8) & 0xFF), blue: UInt8(value & 0xFF))
    }

    // MARK: - GIF previews

    private typealias GIFFrame = (rect: (x: Int, y: Int, w: Int, h: Int), delay: Int)

    private func renderGIF(_ arguments: [String: Value]) throws -> [String: Any] {
        guard let path = arguments["path"]?.stringValue, !path.isEmpty else { throw Failure("Missing path.") }
        guard let destination = arguments["destination"]?.stringValue, !destination.isEmpty else { throw Failure("Missing destination.") }
        let sourceURL = try destinationURL(path, extension: "png", mustExist: true)
        let inWorkspace = destination.hasPrefix(Self.pixelArtWorkspace)
        let url = try inWorkspace ? workspaceURL(destination) : destinationURL(destination, extension: "gif")
        guard url.pathExtension.lowercased() == "gif" else { throw Failure("Use a .gif destination.") }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw Failure("Destination exists: \(destination). Choose a new name; existing assets are preserved.")
        }
        let scale = arguments["scale"]?.intValue ?? 4
        let image = try Image(contentsOf: sourceURL)
        let rgba = [UInt8](image.data)
        guard rgba.count == image.width * image.height * 4 else { throw Failure("Unsupported PNG layout; expected RGBA8.") }
        let frames = try gifFrames(for: sourceURL, arguments: arguments, width: image.width, height: image.height)
        let first = arguments["firstFrame"]?.intValue ?? 0
        let last = arguments["lastFrame"]?.intValue ?? frames.count - 1
        guard frames.indices.contains(first), frames.indices.contains(last), first <= last else {
            throw Failure("The requested GIF frame range is outside the sheet.")
        }
        let selected = frames[first...last]
        let width = selected.map(\.rect.w).max() ?? 0
        let height = selected.map(\.rect.h).max() ?? 0
        try GIFWriter.validateCanvas(width: width, height: height, frameCount: selected.count, scale: scale)
        let (palette, indexed) = try Self.indexedFrames(frames: selected, rgba: rgba, sheetWidth: image.width, width: width, height: height)
        let data = try GIFWriter().encode(width: width, height: height, frames: indexed, palette: palette, scale: scale)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .withoutOverwriting)
        var output: [String: Any] = [
            "path": destination,
            "bytes": data.count,
            "frames": indexed.count,
            "size": [width * scale, height * scale],
            "hint": "Show the GIF in chat with an a2ui image surface so the user sees the animation.",
        ]
        if !inWorkspace { output["assetReference"] = try reference(url) }
        return output
    }

    /// Frame layout: the generated `.sheet.json` sidecar wins; explicit metrics split the strip;
    /// otherwise the whole image is one static frame.
    private func gifFrames(for sourceURL: URL, arguments: [String: Value], width: Int, height: Int) throws -> [GIFFrame] {
        let sidecarURL = sourceURL.deletingPathExtension().appendingPathExtension("sheet.json")
        if let data = try? Data(contentsOf: sidecarURL),
           let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let frames = document["frames"] as? [[String: Any]], !frames.isEmpty {
            return try frames.map { frame in
                guard let rect = frame["frame"] as? [String: Any],
                      let x = rect["x"] as? Int, let y = rect["y"] as? Int, let w = rect["w"] as? Int, let h = rect["h"] as? Int,
                      x >= 0, y >= 0, x < width, y < height, w > 0, h > 0, w <= width - x, h <= height - y
                else { throw Failure("The sidecar sheet.json holds an invalid frame rect.") }
                return ((x, y, w, h), frame["duration"] as? Int ?? AdaScriptSpriteGenerator.defaultFrameDuration)
            }
        }
        if let frameWidth = arguments["frameWidth"]?.intValue, let frameHeight = arguments["frameHeight"]?.intValue {
            guard frameWidth > 0, frameHeight > 0, width % frameWidth == 0, height % frameHeight == 0 else {
                throw Failure("frameWidth and frameHeight must divide the image size.")
            }
            let delay = arguments["frameDuration"]?.intValue ?? AdaScriptSpriteGenerator.defaultFrameDuration
            var frames: [GIFFrame] = []
            for y in stride(from: 0, to: height, by: frameHeight) {
                for x in stride(from: 0, to: width, by: frameWidth) {
                    frames.append(((x, y, frameWidth, frameHeight), delay))
                }
            }
            return frames
        }
        return [((0, 0, width, height), AdaScriptSpriteGenerator.defaultFrameDuration)]
    }

    /// Maps RGBA pixels back to palette indices in first-seen order; index 0 is transparent.
    private static func indexedFrames(
        frames: ArraySlice<GIFFrame>,
        rgba: [UInt8],
        sheetWidth: Int,
        width: Int,
        height: Int
    ) throws -> (palette: [PixelColor], frames: [GIFAnimationFrame]) {
        var palette = [PixelColor(red: 0, green: 0, blue: 0, alpha: 0)]
        var indices: [UInt32: UInt8] = [:]
        var output: [GIFAnimationFrame] = []
        for (rect, delay) in frames {
            var pixels = [UInt8](repeating: 0, count: width * height)
            for y in 0..<rect.h {
                for x in 0..<rect.w {
                    let offset = ((rect.y + y) * sheetWidth + rect.x + x) * 4
                    guard rgba[offset + 3] >= 128 else { continue }
                    let key = UInt32(rgba[offset]) << 16 | UInt32(rgba[offset + 1]) << 8 | UInt32(rgba[offset + 2])
                    if let index = indices[key] {
                        pixels[y * width + x] = index
                    } else {
                        guard palette.count < 256 else {
                            throw Failure("The image uses more than 255 colors; GIF previews need palette pixel art, not a photo.")
                        }
                        let index = UInt8(palette.count)
                        palette.append(PixelColor(red: rgba[offset], green: rgba[offset + 1], blue: rgba[offset + 2]))
                        indices[key] = index
                        pixels[y * width + x] = index
                    }
                }
            }
            output.append(GIFAnimationFrame(indices: pixels, delayMilliseconds: delay))
        }
        return (palette, output)
    }

    private static func report(_ report: AudioReport) -> [String: Any] {
        func rounded(_ value: Double, _ digits: Double = 100) -> Double { (value * digits).rounded() / digits }
        return [
            "durationSeconds": rounded(report.duration, 1000),
            "sampleRate": report.sampleRate,
            "channels": report.channels,
            "peak": rounded(Double(report.peak), 1000),
            "peakDBFS": rounded(Double(report.peakDecibels)),
            "rmsDBFS": rounded(Double(report.rmsDecibels)),
            "clippedSamples": report.clippedSamples,
            "dcOffset": rounded(Double(report.dcOffset), 10000),
            "leadingSilenceSeconds": rounded(report.leadingSilence, 1000),
            "trailingSilenceSeconds": rounded(report.trailingSilence, 1000),
            "dominantFrequencyHz": rounded(report.dominantFrequency, 1),
            "spectralCentroidHz": rounded(report.spectralCentroid, 1),
            "loudnessEnvelopeDBFS": report.envelope.map { rounded(Double($0), 10) },
        ]
    }

    private func inspectAudio(_ arguments: [String: Value]) throws -> [String: Any] {
        guard let path = arguments["path"]?.stringValue, !path.isEmpty else { throw Failure("Missing path.") }
        let url = try destinationURL(path, extension: "wav", mustExist: true)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? Int, size <= WAVReader.maximumBytes else { throw Failure("Audio file exceeds 64 MB.") }
        let audio: WAVAudio
        do {
            audio = try WAVReader().decode(Data(contentsOf: url))
        } catch let error as WAVError {
            throw Failure("Cannot read WAV file: \(error). Only PCM and float WAV files can be measured.")
        }
        var summary = Self.report(AudioAnalyzer.analyze(audio))
        summary["path"] = path
        summary["assetReference"] = try reference(url)
        return summary
    }

    // MARK: - Paths

    private func workspaceURL(_ path: String) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard path.hasPrefix(Self.pixelArtWorkspace), !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { $0.value < 32 }),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw Failure("Use a path inside the pixel art workspace.")
        }
        var url = projectURL
        for component in components {
            url.appendPathComponent(String(component))
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else {
                throw Failure("The pixel art workspace does not support symbolic links.")
            }
        }
        return url
    }

    private func assetsURL() throws -> URL {
        let project = try ProjectSystem.loadProject(at: projectURL)
        return projectURL.appendingPathComponent(project.paths.assets ?? "Assets").resolvingSymlinksInPath().standardizedFileURL
    }

    private func reference(_ url: URL) throws -> String {
        "@res://" + url.pathComponents.dropFirst(try assetsURL().pathComponents.count).joined(separator: "/")
    }

    private func destinationURL(_ path: String, extension ext: String, mustExist: Bool = false) throws -> URL {
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else { throw Failure("Use a project-relative Assets path.") }
        let url = projectURL.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        let root = try assetsURL()
        guard url.pathComponents.starts(with: root.pathComponents), url.pathComponents.count > root.pathComponents.count,
            url.pathExtension.lowercased() == ext
        else { throw Failure("Path must be a .\(ext) file inside Assets.") }
        if mustExist, !FileManager.default.fileExists(atPath: url.path) { throw Failure("No such file: \(path)") }
        return url
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
