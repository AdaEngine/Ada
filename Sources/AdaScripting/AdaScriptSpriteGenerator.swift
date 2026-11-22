import AdaAssets
import Foundation
import Gravity

/// A named range of frames in a generated sprite strip, such as `walk` over frames 0...3.
public struct AdaScriptSpriteTag: Sendable, Equatable {
    public let name: String
    public let from: Int
    public let to: Int

    public init(name: String, from: Int, to: Int) {
        self.name = name
        self.from = from
        self.to = to
    }
}

/// A pixel-art image produced by an AdaScript generator.
///
/// `canvas` is the flattened composite: a single image for flat sprites, or a horizontal
/// strip of `frameCount` cells of `frameWidth × height` when the script requested frames.
public struct AdaScriptSpriteResult: Sendable {
    public let canvas: PixelCanvas
    public let frameWidth: Int
    public let frameCount: Int
    /// Per-frame durations in milliseconds; defaults to ``AdaScriptSpriteGenerator/defaultFrameDuration``.
    public let frameDurations: [Int]
    public let tags: [AdaScriptSpriteTag]
    /// Layer names in creation order; empty for flat single-canvas scripts.
    public let layers: [String]
}

/// Runs an agent-authored AdaScript `build(sprite)` function in an isolated VM and collects the pixels it paints.
///
/// The script sees only the `sprite` builder (canvas size, palette and drawing calls) and the limits of
/// ``AdaScriptGeneratorRunner``. Encoding and writing the `.png` stay with the host (see ``PNGWriter``).
/// Palette presets are compiled into the host; user palettes extracted by the host tool arrive
/// through `userPalettes` so the isolated VM keeps its no-file-access rule.
@MainActor
public enum AdaScriptSpriteGenerator {
    /// Maximum frames in one strip; keeps generated sheets inside the canvas budget.
    nonisolated public static let maximumFrames = 64
    /// Maximum named layers per sprite.
    nonisolated public static let maximumLayers = 16
    /// Default per-frame duration in milliseconds.
    nonisolated public static let defaultFrameDuration = 100

    public static func generate(source: String, userPalettes: [String: [PixelColor]] = [:]) throws -> AdaScriptSpriteResult {
        let bridge = AdaScriptSpriteBridge()
        bridge.configure(userPalettes: userPalettes)
        try AdaScriptGeneratorRunner.run(source: source, kind: "sprite", bridge: bridge, prelude: builderPrelude, factory: "__ada_make_sprite_builder")
        if let failure = bridge.failure { throw AdaScriptError.invalidManifest(failure) }
        return try bridge.result()
    }

    // Parameter validation lives in the bridge; the script-side wrapper only forwards positional values.
    private static let builderPrelude = """

        class __AdaSpriteBuilder {
            var __host;
            func init(host) { __host = host; }
            func size(width, height, frames = 1) { return __host.setSize(width, height, frames); }
            func palette(index, red, green, blue) { return __host.setPalette(index, red, green, blue); }
            func palettePreset(name) { return __host.palettePreset(name); }
            func opacity(index, alpha) { return __host.setOpacity(index, alpha); }
            func pixel(x, y, color) { return __host.paintPixel(x, y, color); }
            func fill(color) { return __host.paintFill(color); }
            func rect(x0, y0, x1, y1, color) {
                __host.stage(x0, y0);
                return __host.paintRect(x1, y1, color);
            }
            func line(x0, y0, x1, y1, color) {
                __host.stage(x0, y0);
                return __host.paintLine(x1, y1, color);
            }
            func ellipse(cx, cy, rx, ry, color) {
                __host.stage(cx, cy);
                return __host.paintEllipse(rx, ry, color);
            }
            func circle(cx, cy, radius, color) {
                __host.stage(cx, cy);
                return __host.paintEllipse(radius, radius, color);
            }
            func outline(color) { return __host.paintOutline(color); }
            func mirror() { return __host.mirrorHalf(); }
            func colorAt(x, y) { return __host.colorAt(x, y); }
            func beginLayer(name) { return __host.beginLayer(name); }
            func endLayer() { return __host.endLayer(); }
            func frame(index) { return __host.selectFrame(index); }
            func frameDuration(index, ms) { return __host.setFrameDuration(index, ms); }
            func tag(name, from, to) { return __host.addTag(name, from, to); }
        }
        func __ada_make_sprite_builder(host) { return __AdaSpriteBuilder(host); }
        """
}

// Only the owning main-actor generator touches this bridge, inside the shared VM lock.
@GSExportable("AdaSpriteBuilderHost")
final class AdaScriptSpriteBridge {
    @GSExportableIgnore var failure: String?
    @GSExportableIgnore private var userPalettes: [String: [PixelColor]]

    /// The shared palette lives outside the canvases, so presets and `palette()` work before `size()`.
    /// Index 0 stays transparent, matching ``PixelCanvas``.
    @GSExportableIgnore private var palette: [PixelColor] = {
        var palette = [PixelColor](repeating: PixelColor(red: 255, green: 0, blue: 255), count: 256)
        palette[0] = PixelColor(red: 0, green: 0, blue: 0, alpha: 0)
        return palette
    }()

    @GSExportableIgnore private var frameWidth = 0
    @GSExportableIgnore private var frameHeight = 0
    @GSExportableIgnore private var frameCount = 0
    @GSExportableIgnore private var stripWidth = 0

    /// The base strip plus named layers, all strip-sized; drawing happens in `cell`, the scratch
    /// canvas of the current frame, and commits into the owning strip on every context switch.
    @GSExportableIgnore private var base: PixelCanvas?
    @GSExportableIgnore private var layers: [(name: String, canvas: PixelCanvas)] = []
    @GSExportableIgnore private var currentLayer = -1
    @GSExportableIgnore private var currentFrame = 0
    @GSExportableIgnore private var cell: PixelCanvas?

    @GSExportableIgnore private var durations: [Int] = []
    @GSExportableIgnore private var tags: [AdaScriptSpriteTag] = []
    @GSExportableIgnore private var staged = (0, 0)

    init() {
        userPalettes = [:]
    }

    /// Hidden from the VM bridge: the host passes palettes after construction; the script cannot.
    @GSExportableIgnore
    func configure(userPalettes: [String: [PixelColor]]) {
        self.userPalettes = userPalettes
    }

    @GSExportableIgnore
    func result() throws -> AdaScriptSpriteResult {
        guard frameCount > 0, let base, let cell else {
            throw AdaScriptError.invalidManifest("The script never called sprite.size(width, height).")
        }
        var flattened = PixelCanvas(width: stripWidth, height: frameHeight) ?? base
        let composite = flattening(base: base, scratch: cell)
        for y in 0..<frameHeight {
            for x in 0..<stripWidth {
                flattened.set(x: x, y: y, color: composite[y * stripWidth + x])
            }
        }
        flattened.palette = palette
        guard flattened.opaquePixelCount > 0 else { throw AdaScriptError.invalidManifest("The script painted no pixels.") }
        return AdaScriptSpriteResult(
            canvas: flattened,
            frameWidth: frameWidth,
            frameCount: frameCount,
            frameDurations: durations,
            tags: tags,
            layers: layers.map(\.name)
        )
    }

    func setSize(width: GSValue, height: GSValue, frames: GSValue) -> Bool {
        guard frameCount == 0 else {
            return fail("sprite.size can be called once.")
        }
        guard let width = whole(width), let height = whole(height), let frames = whole(frames) else {
            return fail("sprite.size expects a width, height and optional frame count as whole numbers.")
        }
        guard frames >= 1, frames <= AdaScriptSpriteGenerator.maximumFrames,
              width > 0, width <= PixelCanvas.maximumDimension / frames,
              let strip = PixelCanvas(width: width * frames, height: height), let scratch = PixelCanvas(width: width, height: height) else {
            return fail(
                "sprite.size expects a width and height in 1...\(PixelCanvas.maximumDimension), "
                    + "a strip at most \(PixelCanvas.maximumDimension) pixels wide and at most \(AdaScriptSpriteGenerator.maximumFrames) frames."
            )
        }
        frameWidth = width
        frameHeight = height
        frameCount = frames
        stripWidth = width * frames
        base = strip
        cell = scratch
        durations = [Int](repeating: AdaScriptSpriteGenerator.defaultFrameDuration, count: frames)
        return true
    }

    func setPalette(index: GSValue, red: GSValue, green: GSValue, blue: GSValue) -> Bool {
        guard let index = whole(index), (1...255).contains(index), let red = byte(red), let green = byte(green), let blue = byte(blue) else {
            return fail("sprite.palette expects an index in 1...255 and red, green, blue in 0...255.")
        }
        palette[index] = PixelColor(red: red, green: green, blue: blue, alpha: palette[index].alpha)
        return true
    }

    func palettePreset(name: GSValue) -> Bool {
        guard let name = text(name) else {
            return fail("sprite.palettePreset expects a preset name string such as \"pico-8\".")
        }
        if name == "custom" {
            return true
        }
        let colors: [PixelColor]?
        if name.hasPrefix("user:") {
            let key = String(name.dropFirst(5))
            colors = userPalettes[key]
        } else {
            colors = AdaScriptSpritePalettes.bundled(name)
        }
        guard let colors, colors.count <= 255 else {
            return fail("Unknown palette preset \"\(name)\". Bundled: \(AdaScriptSpritePalettes.bundledNames.joined(separator: ", ")); user presets come from editor.palette.extract.")
        }
        for (offset, color) in colors.enumerated() {
            palette[offset + 1] = color
        }
        return true
    }

    func setOpacity(index: GSValue, alpha: GSValue) -> Bool {
        guard let index = whole(index), (1...255).contains(index), let alpha = byte(alpha) else {
            return fail("sprite.opacity expects an index in 1...255 and an alpha in 0...255.")
        }
        palette[index].alpha = alpha
        return true
    }

    func paintPixel(x: GSValue, y: GSValue, color: GSValue) -> Bool {
        guard let x = whole(x), let y = whole(y), let color = byte(color), cell != nil else {
            return fail("sprite.pixel expects x, y and a color in 0...255, after sprite.size.")
        }
        cell?.set(x: x, y: y, color: color)
        return true
    }

    func paintFill(color: GSValue) -> Bool {
        guard let color = byte(color), cell != nil else {
            return fail("sprite.fill expects a color in 0...255, after sprite.size.")
        }
        cell?.fill(color: color)
        return true
    }

    /// Remembers the first two numbers of a shape call; Gravity bridge methods take at most four arguments.
    func stage(a: GSValue, b: GSValue) -> Bool {
        guard let a = whole(a), let b = whole(b) else {
            return fail("Shape coordinates must be whole numbers.")
        }
        staged = (a, b)
        return true
    }

    func paintRect(x1: GSValue, y1: GSValue, color: GSValue) -> Bool {
        guard failure == nil, cell != nil, let x1 = whole(x1), let y1 = whole(y1), let color = byte(color) else {
            return fail("sprite.rect expects two inclusive corners as whole numbers and a color in 0...255, after sprite.size.")
        }
        cell?.fillRect(x0: staged.0, y0: staged.1, x1: x1, y1: y1, color: color)
        return true
    }

    func paintLine(x1: GSValue, y1: GSValue, color: GSValue) -> Bool {
        guard failure == nil, cell != nil, let x1 = whole(x1), let y1 = whole(y1), let color = byte(color) else {
            return fail("sprite.line expects two end points as whole numbers and a color in 0...255, after sprite.size.")
        }
        cell?.line(x0: staged.0, y0: staged.1, x1: x1, y1: y1, color: color)
        return true
    }

    func paintEllipse(rx: GSValue, ry: GSValue, color: GSValue) -> Bool {
        guard failure == nil, cell != nil, let rx = whole(rx), let ry = whole(ry), rx >= 0, ry >= 0, let color = byte(color) else {
            return fail("sprite.ellipse and sprite.circle expect a center, non-negative whole radii and a color in 0...255, after sprite.size.")
        }
        cell?.fillEllipse(cx: staged.0, cy: staged.1, rx: rx, ry: ry, color: color)
        return true
    }

    func paintOutline(color: GSValue) -> Bool {
        guard let color = byte(color), color > 0, cell != nil else {
            return fail("sprite.outline expects a color in 1...255, after sprite.size.")
        }
        cell?.outline(color: color)
        return true
    }

    func mirrorHalf() -> Bool {
        guard cell != nil else {
            return fail("Call sprite.size(width, height) first.")
        }
        cell?.mirrorLeftToRight()
        return true
    }

    func colorAt(x: GSValue, y: GSValue) -> Int {
        guard let x = whole(x), let y = whole(y), let cell, let base, x >= 0, y >= 0, x < frameWidth, y < frameHeight else {
            return 0
        }
        let stripX = currentFrame * frameWidth + x
        var value = currentLayer == -1 ? cell.color(x: x, y: y) : base.color(x: stripX, y: y)
        for (index, layer) in layers.enumerated() {
            let painted = index == currentLayer ? cell.color(x: x, y: y) : layer.canvas.color(x: stripX, y: y)
            if painted != 0 { value = painted }
        }
        return Int(value)
    }

    func beginLayer(name: GSValue) -> Bool {
        guard cell != nil else {
            return fail("Call sprite.size(width, height) first.")
        }
        guard let name = text(name), name.count <= 32 else {
            return fail("sprite.beginLayer expects a nonempty layer name of at most 32 characters.")
        }
        commitCell()
        if let index = layers.firstIndex(where: { $0.name == name }) {
            layers[index].canvas = PixelCanvas(width: stripWidth, height: frameHeight) ?? layers[index].canvas
            currentLayer = index
        } else {
            guard layers.count < AdaScriptSpriteGenerator.maximumLayers else {
                return fail("A sprite supports at most \(AdaScriptSpriteGenerator.maximumLayers) layers.")
            }
            guard let canvas = PixelCanvas(width: stripWidth, height: frameHeight) else {
                return fail("The canvas is not initialized.")
            }
            layers.append((name, canvas))
            currentLayer = layers.count - 1
        }
        loadCell()
        return true
    }

    func endLayer() -> Bool {
        guard currentLayer != -1 else {
            return fail("sprite.endLayer without a matching sprite.beginLayer.")
        }
        commitCell()
        currentLayer = -1
        loadCell()
        return true
    }

    func selectFrame(index: GSValue) -> Bool {
        guard frameCount > 1 else {
            return fail("sprite.frame requires sprite.size(width, height, frames) with more than one frame.")
        }
        guard let index = whole(index), (0..<frameCount).contains(index) else {
            return fail("sprite.frame expects a frame in 0...\(frameCount - 1).")
        }
        commitCell()
        currentFrame = index
        loadCell()
        return true
    }

    func setFrameDuration(index: GSValue, ms: GSValue) -> Bool {
        guard let index = whole(index), (0..<max(frameCount, 1)).contains(index), frameCount > 0,
              let ms = whole(ms), (1...60_000).contains(ms) else {
            return fail("sprite.frameDuration expects a frame in 0...\(max(frameCount - 1, 0)) and a duration in 1...60000 milliseconds, after sprite.size.")
        }
        durations[index] = ms
        return true
    }

    func addTag(name: GSValue, from: GSValue, to: GSValue) -> Bool {
        guard frameCount > 1 else {
            return fail("sprite.tag requires sprite.size(width, height, frames) with more than one frame.")
        }
        guard let name = text(name), name.count <= 32 else {
            return fail("sprite.tag expects a nonempty tag name of at most 32 characters.")
        }
        guard !tags.contains(where: { $0.name == name }) else {
            return fail("sprite.tag names must be unique.")
        }
        guard let from = whole(from), let to = whole(to), from >= 0, from <= to, to < frameCount else {
            return fail("sprite.tag expects a frame range inside 0...\(frameCount - 1).")
        }
        tags.append(AdaScriptSpriteTag(name: name, from: from, to: to))
        return true
    }

    // MARK: - Cell composition

    /// Writes the scratch cell back into the owning strip at the current frame offset.
    @GSExportableIgnore
    private func commitCell() {
        guard let cell, frameCount > 0 else {
            return
        }
        for y in 0..<frameHeight {
            for x in 0..<frameWidth {
                let value = cell.color(x: x, y: y)
                let stripX = currentFrame * frameWidth + x
                if currentLayer == -1 {
                    base?.set(x: stripX, y: y, color: value)
                } else {
                    layers[currentLayer].canvas.set(x: stripX, y: y, color: value)
                }
            }
        }
    }

    /// Loads the current frame of the owning strip into the scratch cell.
    @GSExportableIgnore
    private func loadCell() {
        guard frameCount > 0 else {
            return
        }
        cell?.fill(color: 0)
        for y in 0..<frameHeight {
            for x in 0..<frameWidth {
                let stripX = currentFrame * frameWidth + x
                let value = currentLayer == -1 ? base?.color(x: stripX, y: y) ?? 0 : layers[currentLayer].canvas.color(x: stripX, y: y)
                cell?.set(x: x, y: y, color: value)
            }
        }
    }

    /// Composites the base strip and every layer in creation order. The scratch cell is the
    /// complete current state of its owner's cell and replaces that region before the layers
    /// above the owner are overlaid, so committed pixels never resurrect over newer edits.
    @GSExportableIgnore
    private func flattening(base: PixelCanvas, scratch: PixelCanvas) -> [UInt8] {
        var indices = base.indices
        let cellOrigin = currentFrame * frameWidth
        if currentLayer == -1 {
            for y in 0..<frameHeight {
                for x in 0..<frameWidth {
                    indices[y * stripWidth + cellOrigin + x] = scratch.color(x: x, y: y)
                }
            }
        }
        for (index, layer) in layers.enumerated() {
            for y in 0..<frameHeight {
                for x in 0..<stripWidth {
                    var painted = layer.canvas.color(x: x, y: y)
                    if index == currentLayer {
                        let localX = x - cellOrigin
                        if (0..<frameWidth).contains(localX) { painted = scratch.color(x: localX, y: y) }
                    }
                    if painted != 0 { indices[y * stripWidth + x] = painted }
                }
            }
        }
        return indices
    }

    // MARK: - Helpers

    @GSExportableIgnore
    private func fail(_ message: String) -> Bool {
        failure = failure ?? message
        return false
    }

    @GSExportableIgnore
    private func whole(_ value: GSValue) -> Int? {
        guard let number = value.finiteNumber else {
            return nil
        }
        return Int(exactly: number)
    }

    @GSExportableIgnore
    private func byte(_ value: GSValue) -> UInt8? {
        whole(value).flatMap { (0...255).contains($0) ? UInt8($0) : nil }
    }

    @GSExportableIgnore
    private func text(_ value: GSValue) -> String? {
        guard value.isString else {
            return nil
        }
        let string = value.toString
        return string.isEmpty ? nil : string
    }
}
