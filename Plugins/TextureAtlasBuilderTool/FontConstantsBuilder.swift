//
//  FontConstantsBuilder.swift
//  AdaEngine
//

import Foundation

struct FontConstantsConfig: Codable, Sendable {
    var fontSetName: String
    var inputDirectory: String
    var accessorTypeName: String
    var keyStrategy: String
    var emFontScale: Double?
    var bundle: String

    init(
        fontSetName: String,
        inputDirectory: String,
        accessorTypeName: String,
        keyStrategy: String = "filenameStem",
        emFontScale: Double? = nil,
        bundle: String = "module"
    ) {
        self.fontSetName = fontSetName
        self.inputDirectory = inputDirectory
        self.accessorTypeName = accessorTypeName
        self.keyStrategy = keyStrategy
        self.emFontScale = emFontScale
        self.bundle = bundle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fontSetName = try container.decode(String.self, forKey: .fontSetName)
        self.inputDirectory = try container.decode(String.self, forKey: .inputDirectory)
        self.accessorTypeName = try container.decode(String.self, forKey: .accessorTypeName)
        self.keyStrategy = try container.decodeIfPresent(String.self, forKey: .keyStrategy) ?? "filenameStem"
        self.emFontScale = try container.decodeIfPresent(Double.self, forKey: .emFontScale)
        self.bundle = try container.decodeIfPresent(String.self, forKey: .bundle) ?? "module"
    }
}

struct FontAssetEntry: Sendable {
    var key: String
    var caseName: String
    var constantName: String
    var relativePath: String
}

extension BuilderError {
    static func missingFont(_ url: URL) -> BuilderError {
        .usage("Missing font files in directory: \(url.path)")
    }
}

func buildFontConstants(configPath: URL, outputPath: URL) throws {
    let data = try Data(contentsOf: configPath)
    let config = try JSONDecoder().decode(FontConstantsConfig.self, from: data)

    let baseDir = configPath.deletingLastPathComponent()
    let inputDir = baseDir.appendingPathComponent(config.inputDirectory, isDirectory: true)

    let fontURLs = try FileManager.default.contentsOfDirectory(
        at: inputDir,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )
    .filter { FontConstantsConfig.fontExtensions.contains($0.pathExtension.lowercased()) }
    .sorted { $0.path < $1.path }

    guard !fontURLs.isEmpty else {
        throw BuilderError.missingFont(inputDir)
    }

    var seenKeys: Set<String> = []
    var seenCases: Set<String> = []
    var entries: [FontAssetEntry] = []

    for fontURL in fontURLs {
        let key = fontKey(for: fontURL, inputDir: inputDir, strategy: config.keyStrategy)
        if seenKeys.contains(key) {
            throw BuilderError.duplicateKey(key)
        }
        seenKeys.insert(key)

        let caseName = swiftEnumCaseName(key)
        if seenCases.contains(caseName) {
            throw BuilderError.duplicateKey("font enum case collision after sanitizing: \(caseName)")
        }
        seenCases.insert(caseName)

        entries.append(
            FontAssetEntry(
                key: key,
                caseName: caseName,
                constantName: caseName,
                relativePath: relativeResourcePath(for: fontURL, baseDir: baseDir),
            )
        )
    }

    let swift = renderFontConstantsSwift(config: config, entries: entries)
    try swift.write(to: outputPath, atomically: true, encoding: .utf8)
}

private extension FontConstantsConfig {
    static let fontExtensions: Set<String> = ["ttf", "otf", "ttc"]
}

private func fontKey(for fontURL: URL, inputDir: URL, strategy: String) -> String {
    switch strategy {
    case "relativePath":
        return relativeResourcePath(for: fontURL, baseDir: inputDir).replacingOccurrences(of: "/", with: "_")
    case "filename":
        return fontURL.lastPathComponent
    case "filenameStem":
        fallthrough
    default:
        return fontURL.deletingPathExtension().lastPathComponent
    }
}

private func relativeResourcePath(for url: URL, baseDir: URL) -> String {
    let basePath = baseDir.standardizedFileURL.path
    let filePath = url.standardizedFileURL.path
    guard filePath.hasPrefix(basePath + "/") else {
        return url.lastPathComponent
    }
    return String(filePath.dropFirst(basePath.count + 1))
}

private func renderFontConstantsSwift(config: FontConstantsConfig, entries: [FontAssetEntry]) -> String {
    let accessor = config.accessorTypeName
    let keysEnum = "\(accessor)Key"
    let referenceType = "\(accessor)FontReference"
    let defaultScaleLiteral = config.emFontScale.map { String($0) } ?? "nil"
    let bundleExpression = config.bundle == "main" ? "Bundle.main" : "Bundle.module"

    let casesBlock = entries
        .map { "    case \($0.caseName) = \"\(escapeStr($0.key))\"" }
        .joined(separator: "\n")

    let tableBlock = entries
        .map { entry in
            """
                    .\(entry.caseName): \(referenceType)(
                        key: .\(entry.caseName),
                        path: "\(escapeStr(entry.relativePath))",
                        defaultEmFontScale: \(defaultScaleLiteral)
                    )
            """
        }
        .joined(separator: ",\n")

    let constantBlock = entries
        .map { entry in
            "    public static let \(entry.constantName) = reference(.\(entry.caseName))" }
        .joined(separator: "\n")

    return """
    // swift-format-ignore-file
    // Generated by TextureAtlasBuilderTool — do not edit.

    import AdaEngine
    import Foundation

    public enum \(keysEnum): String, CaseIterable, Sendable {
    \(casesBlock)
    }

    public struct \(referenceType): Sendable {
        public let key: \(keysEnum)
        public let path: String
        public let defaultEmFontScale: Double?

        public func resource(emFontScale: Double? = nil) -> FontResource {
            var resolvedPath = path
            let resolvedScale = emFontScale ?? defaultEmFontScale
            if let resolvedScale {
                resolvedPath += "#emSize=\\(resolvedScale)"
            }

            do {
                guard let resource = try AssetsManager.loadSync(
                    FontResource.self,
                    at: resolvedPath,
                    from: \(bundleExpression)
                ).asset else {
                    fatalError("\(accessor): failed to load font resource at path \\(resolvedPath)")
                }
                return resource
            } catch {
                fatalError("\(accessor): failed to load font resource at path \\(resolvedPath): \\(error)")
            }
        }
    }

    public enum \(accessor) {
        private static let referencesByKey: [\(keysEnum): \(referenceType)] = [
    \(tableBlock)
        ]

    \(constantBlock)

        public static func reference(_ key: \(keysEnum)) -> \(referenceType) {
            guard let reference = referencesByKey[key] else {
                preconditionFailure("\(accessor): missing font reference for " + String(describing: key.rawValue))
            }
            return reference
        }

        public static func font(_ key: \(keysEnum), emFontScale: Double? = nil) -> FontResource {
            reference(key).resource(emFontScale: emFontScale)
        }

        public static var allKeys: [\(keysEnum)] {
            Array(\(keysEnum).allCases)
        }
    }

    """
}
