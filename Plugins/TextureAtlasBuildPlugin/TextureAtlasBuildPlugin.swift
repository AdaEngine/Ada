//
//  TextureAtlasBuildPlugin.swift
//  AdaEngine
//

import Foundation
import PackagePlugin

@main
struct TextureAtlasBuildPlugin: BuildToolPlugin {

    private let fileManager = FileManager.default

    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let tool = try context.tool(named: "TextureAtlasBuilderTool")
        let root = URL(fileURLWithPath: target.directory.string, isDirectory: true)

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var configs: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            if item.lastPathComponent.hasSuffix(".atlas.json") || item.lastPathComponent.hasSuffix(".fonts.json") {
                configs.append(item)
            }
        }
        configs.sort { $0.path < $1.path }

        var commands: [Command] = []

        for configURL in configs {
            let data = try Data(contentsOf: configURL)
            let lite = try JSONDecoder().decode(AssetConstantsConfigLite.self, from: data)
            let baseDir = configURL.deletingLastPathComponent()
            let inputDir = baseDir.appendingPathComponent(lite.inputDirectory, isDirectory: true)
            let isFontsConfig = configURL.lastPathComponent.hasSuffix(".fonts.json")

            var inputs: [Path] = [Path(configURL.path)]
            if fileManager.fileExists(atPath: inputDir.path) {
                let resourceExtensions = isFontsConfig ? AssetConstantsConfigLite.fontExtensions : AssetConstantsConfigLite.pngExtensions
                let resources = try fileManager.contentsOfDirectory(
                    at: inputDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ).filter { resourceExtensions.contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
                inputs.append(contentsOf: resources.map { Path($0.path) })
            }

            let safeName = lite.outputName.replacingOccurrences(of: " ", with: "_")
            let outName = isFontsConfig ? "\(safeName)Fonts+Generated.swift" : "\(safeName)Atlas+Generated.swift"
            let outPath = context.pluginWorkDirectory.appending(outName)

            commands.append(
                .buildCommand(
                    displayName: isFontsConfig ? "Generate font constants \(lite.outputName)" : "Pack texture atlas \(lite.outputName)",
                    executable: tool.path,
                    arguments: [
                        "--config", configURL.path,
                        "--output-swift", outPath.string
                    ],
                    environment: [:],
                    inputFiles: inputs,
                    outputFiles: [outPath]
                )
            )
        }

        return commands
    }
}

private struct AssetConstantsConfigLite: Codable, Sendable {
    static let fontExtensions: Set<String> = ["ttf", "otf", "ttc"]
    static let pngExtensions: Set<String> = ["png"]

    var atlasName: String?
    var fontSetName: String?
    var inputDirectory: String

    var outputName: String {
        fontSetName ?? atlasName ?? "Assets"
    }
}
