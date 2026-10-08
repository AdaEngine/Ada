//
//  TextureAtlasBuilder.swift
//  AdaEngine
//

import AdaRender
import Foundation
import Math

// MARK: - Config

struct AtlasConfig: Codable, Sendable {
    var atlasName: String
    var inputDirectory: String
    var padding: Int = 2
    var extrude: Int = 1
    var powerOfTwo: Bool = false
    var accessorTypeName: String
    var keyStrategy: String = "filenameStem"
    var sampler: String = "linear"
    /// Maximum row width before wrapping to next shelf (pixels). Default: wide strip.
    var maxShelfWidth: Int = 4096
}

private struct PackedSprite {
    var key: String
    var sourceURL: URL
    var sourceWidth: Int
    var sourceHeight: Int
    var cellW: Int
    var cellH: Int
    var x: Int
    var y: Int
}

enum BuilderError: LocalizedError {
    case usage(String)
    case duplicateKey(String)
    case missingPNG(URL)
    case invalidPNG(URL, String)

    var errorDescription: String? {
        switch self {
        case .usage(let s):
            return s
        case .duplicateKey(let k):
            return "Duplicate texture key '\(k)' (same filename stem)."
        case .missingPNG(let u):
            return "Missing or unreadable PNG: \(u.path)"
        case .invalidPNG(let u, let m):
            return "Invalid PNG \(u.path): \(m)"
        }
    }
}

@main
enum TextureAtlasBuilderEntry {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let cfgIdx = args.firstIndex(of: "--config"), cfgIdx + 1 < args.count,
              let outIdx = args.firstIndex(of: "--output-swift"), outIdx + 1 < args.count
        else {
            throw BuilderError.usage(
                "texture-atlas-builder --config <path.atlas.json> --output-swift <out.swift>"
            )
        }
        let configPath = URL(fileURLWithPath: args[cfgIdx + 1], isDirectory: false)
        let outputPath = URL(fileURLWithPath: args[outIdx + 1], isDirectory: false)

        if configPath.lastPathComponent.hasSuffix(".fonts.json") {
            try buildFontConstants(configPath: configPath, outputPath: outputPath)
            return
        }

        let data = try Data(contentsOf: configPath)
        let config = try JSONDecoder().decode(AtlasConfig.self, from: data)

        let baseDir = configPath.deletingLastPathComponent()
        let inputDir = baseDir.appendingPathComponent(config.inputDirectory, isDirectory: true)

        let pngURLs = try FileManager.default.contentsOfDirectory(
            at: inputDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "png" }.sorted { $0.path < $1.path }

        guard !pngURLs.isEmpty else {
            throw BuilderError.missingPNG(inputDir)
        }

        var seenKeys: Set<String> = []
        var sprites: [PackedSprite] = []

        for url in pngURLs {
            let stem = url.deletingPathExtension().lastPathComponent
            let key: String
            switch config.keyStrategy {
            case "filenameStem":
                key = stem
            default:
                key = stem
            }
            if seenKeys.contains(key) {
                throw BuilderError.duplicateKey(key)
            }
            seenKeys.insert(key)

            let img: Image
            do {
                img = try Image(contentsOf: url)
            } catch {
                throw BuilderError.invalidPNG(url, String(describing: error))
            }
            guard img.format == .rgba8 else {
                throw BuilderError.invalidPNG(url, "expected RGBA8 PNG")
            }

            let sw = img.width
            let sh = img.height
            let ex = max(0, config.extrude)
            let cellW = sw + 2 * ex
            let cellH = sh + 2 * ex

            sprites.append(
                PackedSprite(
                    key: key,
                    sourceURL: url,
                    sourceWidth: sw,
                    sourceHeight: sh,
                    cellW: cellW,
                    cellH: cellH,
                    x: 0,
                    y: 0
                )
            )
        }

        sprites.sort { a, b in
            if a.cellH != b.cellH {
                return a.cellH > b.cellH
            }
            if a.cellW != b.cellW {
                return a.cellW > b.cellW
            }
            return a.key < b.key
        }

        let pad = max(0, config.padding)
        let maxShelf = max(64, config.maxShelfWidth)

        var cursorX = pad
        var cursorY = pad
        var rowHeight = 0
        var atlasW = pad * 2
        var atlasH = pad * 2

        for i in sprites.indices {
            let sp = sprites[i]
            if cursorX > pad && cursorX + sp.cellW + pad > maxShelf {
                cursorY += rowHeight + pad
                cursorX = pad
                rowHeight = 0
            }
            sprites[i].x = cursorX
            sprites[i].y = cursorY
            rowHeight = max(rowHeight, sp.cellH)
            atlasW = max(atlasW, cursorX + sp.cellW + pad)
            cursorX += sp.cellW + pad
        }
        atlasH = max(atlasH, cursorY + rowHeight + pad)

        if config.powerOfTwo {
            atlasW = nextPowerOfTwo(atlasW)
            atlasH = nextPowerOfTwo(atlasH)
        }

        var atlasData = Data(count: atlasW * atlasH * 4)

        func setPixel(ax: Int, ay: Int, r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            guard ax >= 0, ay >= 0, ax < atlasW, ay < atlasH else { return }
            let o = (ay * atlasW + ax) * 4
            atlasData[o] = r
            atlasData[o + 1] = g
            atlasData[o + 2] = b
            atlasData[o + 3] = a
        }

        func getPixel(data: Data, w: Int, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
            let o = (y * w + x) * 4
            return (data[o], data[o + 1], data[o + 2], data[o + 3])
        }

        for sp in sprites {
            let srcImg = try Image(contentsOf: sp.sourceURL)
            let src = srcImg.data
            let sw = sp.sourceWidth
            let sh = sp.sourceHeight
            let ex = max(0, config.extrude)
            let dstX0 = sp.x + ex
            let dstY0 = sp.y + ex
            for y in 0 ..< sh {
                for x in 0 ..< sw {
                    let (r, g, b, a) = getPixel(data: src, w: sw, x: x, y: y)
                    setPixel(ax: dstX0 + x, ay: dstY0 + y, r: r, g: g, b: b, a: a)
                }
            }
            if ex > 0 {
                extrudeRegion(
                    data: &atlasData,
                    atlasWidth: atlasW,
                    atlasHeight: atlasH,
                    rectX: sp.x,
                    rectY: sp.y,
                    rectW: sp.cellW,
                    rectH: sp.cellH,
                    extrude: ex
                )
            }
        }

        var regions: [AtlasRegion] = []
        let aw = Float(atlasW)
        let ah = Float(atlasH)

        for sp in sprites {
            let ex = max(0, config.extrude)
            let contentX = sp.x + ex
            let contentY = sp.y + ex
            let u0 = Float(contentX) / aw
            let u1 = Float(contentX + sp.sourceWidth) / aw
            let v0 = Float(contentY) / ah
            let v1 = Float(contentY + sp.sourceHeight) / ah

            let region = AtlasRegion(
                key: sp.key,
                atlasOrigin: PointInt(x: sp.x, y: sp.y),
                atlasSize: SizeInt(width: sp.cellW, height: sp.cellH),
                uvMin: Vector2(u0, v0),
                uvMax: Vector2(u1, v1),
                originalSize: SizeInt(width: sp.sourceWidth, height: sp.sourceHeight),
                contentOriginInAtlas: PointInt(x: contentX, y: contentY)
            )
            regions.append(region)
        }

        regions.sort { $0.key < $1.key }

        let swift = try renderSwift(
            config: config,
            atlasWidth: atlasW,
            atlasHeight: atlasH,
            atlasData: atlasData,
            regions: regions
        )

        try swift.write(to: outputPath, atomically: true, encoding: .utf8)
    }
}

private func nextPowerOfTwo(_ v: Int) -> Int {
    let x = max(1, v)
    var p = 1
    while p < x {
        p &*= 2
    }
    return p
}

/// Copy edge RGBA outward by `extrude` pixels inside the packed rectangle.
private func extrudeRegion(
    data: inout Data,
    atlasWidth: Int,
    atlasHeight: Int,
    rectX: Int,
    rectY: Int,
    rectW: Int,
    rectH: Int,
    extrude: Int
) {
    guard extrude > 0, rectW > 0, rectH > 0 else { return }

    func getA(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let o = (y * atlasWidth + x) * 4
        return (data[o], data[o + 1], data[o + 2], data[o + 3])
    }

    func setA(_ x: Int, _ y: Int, _ p: (UInt8, UInt8, UInt8, UInt8)) {
        guard x >= 0, y >= 0, x < atlasWidth, y < atlasHeight else { return }
        let o = (y * atlasWidth + x) * 4
        data[o] = p.0
        data[o + 1] = p.1
        data[o + 2] = p.2
        data[o + 3] = p.3
    }

    let innerX0 = rectX + extrude
    let innerY0 = rectY + extrude
    let innerW = rectW - 2 * extrude
    let innerH = rectH - 2 * extrude
    guard innerW > 0, innerH > 0 else { return }

    for e in 1 ... extrude {
        for x in innerX0 ..< (innerX0 + innerW) {
            let top = getA(x, innerY0)
            let bottom = getA(x, innerY0 + innerH - 1)
            setA(x, innerY0 - e, top)
            setA(x, innerY0 + innerH - 1 + e, bottom)
        }
        for y in innerY0 ..< (innerY0 + innerH) {
            let left = getA(innerX0, y)
            let right = getA(innerX0 + innerW - 1, y)
            setA(innerX0 - e, y, left)
            setA(innerX0 + innerW - 1 + e, y, right)
        }
    }
}

private func renderSwift(
    config: AtlasConfig,
    atlasWidth: Int,
    atlasHeight: Int,
    atlasData: Data,
    regions: [AtlasRegion]
) throws -> String {
    let filter: String
    switch config.sampler.lowercased() {
    case "nearest":
        filter = ".nearest"
    default:
        filter = ".linear"
    }

    let b64 = atlasData.base64EncodedString()

    var regionLines: [String] = []
    for r in regions {
        regionLines.append(
            """
                    "\(escapeStr(r.key))": AtlasRegion(
                        key: "\(escapeStr(r.key))",
                        atlasOrigin: PointInt(x: \(r.atlasOrigin.x), y: \(r.atlasOrigin.y)),
                        atlasSize: SizeInt(width: \(r.atlasSize.width), height: \(r.atlasSize.height)),
                        uvMin: Vector2(\(r.uvMin.x), \(r.uvMin.y)),
                        uvMax: Vector2(\(r.uvMax.x), \(r.uvMax.y)),
                        originalSize: SizeInt(width: \(r.originalSize.width), height: \(r.originalSize.height)),
                        contentOriginInAtlas: PointInt(x: \(r.contentOriginInAtlas.x), y: \(r.contentOriginInAtlas.y))
                    )
            """
        )
    }

    var seenCases: Set<String> = []
    var enumCases: [String] = []
    for r in regions {
        let caseName = swiftEnumCaseName(r.key)
        if seenCases.contains(caseName) {
            throw BuilderError.duplicateKey("enum case collision after sanitizing: \(caseName)")
        }
        seenCases.insert(caseName)
        enumCases.append("    case \(caseName) = \"\(escapeStr(r.key))\"")
    }
    let enumCasesBlock = enumCases.joined(separator: "\n")

    let accessor = config.accessorTypeName
    let keysEnum = "\(accessor)Key"

    return """
    // swift-format-ignore-file
    // Generated by TextureAtlasBuilderTool — do not edit.

    import AdaEngine
    import Foundation
    import Math

    public enum \(keysEnum): String, CaseIterable, Sendable {
    \(enumCasesBlock)
    }

    public enum \(accessor)Atlas {
        private static let _regionsByKey: [String: AtlasRegion] = [
    \(regionLines.joined(separator: ",\n"))
        ]

        private static let _atlasBase64 = \"\(b64)\"

        public static let atlas: NamedTextureAtlas = {
            guard let raw = Data(base64Encoded: _atlasBase64) else {
                fatalError("\(accessor)Atlas: corrupted embedded atlas data")
            }
            let image = Image(width: \(atlasWidth), height: \(atlasHeight), data: raw, format: .rgba8)
            let tex = Texture2D(
                image: image,
                samplerDescription: SamplerDescriptor(
                    minFilter: \(filter),
                    magFilter: \(filter),
                    mipFilter: .notMipmapped
                )
            )
            return NamedTextureAtlas(texture: tex, entriesByKey: _regionsByKey)
        }()

        public static func texture(_ key: \(keysEnum)) -> Texture2D {
            guard let t = atlas.slice(for: key.rawValue) else {
                preconditionFailure("\(accessor)Atlas: missing texture for " + String(describing: key.rawValue))
            }
            return t
        }

        public static func image(_ key: \(keysEnum)) -> Image {
            guard let raw = Data(base64Encoded: _atlasBase64) else {
                preconditionFailure("\(accessor)Atlas: corrupted embedded atlas data")
            }
            guard let img = atlas.image(
                for: key.rawValue,
                atlasRGBA: raw,
                atlasWidth: \(atlasWidth),
                atlasHeight: \(atlasHeight)
            ) else {
                preconditionFailure("\(accessor)Atlas: missing image for " + String(describing: key.rawValue))
            }
            return img
        }

        public static var allKeys: [\(keysEnum)] {
            Array(\(keysEnum).allCases)
        }
    }

    """
}

func escapeStr(_ s: String) -> String {
    s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
}

func swiftEnumCaseName(_ key: String) -> String {
    var s = key
    if let f = s.first, f.isNumber {
        s = "_" + s
    }
    return String(s.map { ch -> Character in
        if ch.isLetter || ch.isNumber || ch == "_" {
            return ch
        }
        return "_"
    })
}
