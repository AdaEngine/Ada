@testable import AdaShaderGraphBaker
import AdaRender
import Foundation
import Testing

@Suite("Shader Graph host baking", .serialized)
struct ShaderGraphBakerTests {
    @Test func inactiveLayersDropOnlyTheirOwnTextureDefines() {
        for mask: UInt32 in 0..<256 {
            for layers: UInt32 in 0..<8 {
                for morph in [false, true] {
                    let features = ShaderGraphBakeVariants.features(textureMask: mask << 3, layers: layers, morph: morph)
                    #expect(features.contains(.clearcoat) == (layers & 1 != 0))
                    #expect(features.contains(.sheen) == (layers & 2 != 0))
                    #expect(features.contains(.anisotropy) == (layers & 4 != 0))
                    #expect(features.contains(.morph) == morph)
                    for texture in PBRLayerTexture.allCases {
                        let active = switch texture {
                        case .clearcoat, .clearcoatRoughness, .clearcoatNormal: layers & 1 != 0
                        case .sheenColor, .sheenRoughness: layers & 2 != 0
                        case .anisotropy: layers & 4 != 0
                        case .specular, .specularColor: true
                        }
                        #expect(features.contains(texture.feature) == (active && mask & (1 << texture.rawValue) != 0))
                    }
                }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_SHADER_GRAPH_BAKER"] != nil))
    func realBakerHandlesInlineOverridesMissingResourcesAndUnicode() throws {
        let environment = ProcessInfo.processInfo.environment
        let executable = try #require(environment["ADAENGINE_SHADER_GRAPH_BAKER"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Граф со пробелами " + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scene = root.appendingPathComponent("Main.ascn")
        let archive = root.appendingPathComponent("shaders.shadergraphlib")
        func run() throws -> (Int32, String) {
            let log = root.appendingPathComponent("baker.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = [root.path]
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            return (process.terminationStatus, try String(contentsOf: log, encoding: .utf8))
        }
        func write(_ source: ShaderGraphMaterialSource) throws {
            // Production prepared scenes store Codable component bytes in base64.
            let component = try JSONEncoder().encode(source).base64EncodedString()
            try JSONSerialization.data(withJSONObject: ["components": ["graph": component]]).write(to: scene)
        }
        try Data("{}".utf8).write(to: scene)
        #expect(try run().0 == 0)
        #expect(!FileManager.default.fileExists(atPath: archive.path))
        try write(.init(path: "@res://missing.shadergraph"))
        let missingGraph = try run()
        #expect(missingGraph.0 != 0 && missingGraph.1.contains("Missing packaged Shader Graph"))
        let invalid = root.appendingPathComponent("invalid.shadergraph")
        try Data("{\"version\":99}".utf8).write(to: invalid)
        let invalidGraph = try run()
        #expect(invalidGraph.0 != 0 && invalidGraph.1.contains("invalid.shadergraph"))
        try FileManager.default.removeItem(at: invalid)
        let graph = ShaderGraph(target: .sprite, output: "out", nodes: [.init(id: "out", operation: .output)])
        try write(.init(graph: graph, textures: ["map": "../outside.png"]))
        let outsideTexture = try run()
        #expect(outsideTexture.0 != 0 && outsideTexture.1.contains("outside packaged resources"))
        try write(.init(graph: graph, textures: ["map": "@res://missing.png"]))
        let missingTexture = try run()
        #expect(missingTexture.0 != 0 && missingTexture.1.contains("Missing packaged Shader Graph texture"))
        try Data([0]).write(to: root.appendingPathComponent("цвет.png"))
        try write(.init(graph: graph, textures: ["map": "@res://цвет.png"]))
        #expect(try run().0 == 0)
        let baked = try JSONDecoder().decode(ShaderGraphArchive.self, from: Data(contentsOf: archive))
        #expect(baked.graphs.isEmpty && baked.fragments.count == 2)
        #expect(baked.texturePaths == ["@res://цвет.png"])
        #expect(baked.fragments.allSatisfy { !$0.wgsl.isEmpty && !$0.entryPoint.isEmpty })
    }
}
