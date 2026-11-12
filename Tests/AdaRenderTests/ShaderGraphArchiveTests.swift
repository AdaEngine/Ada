@testable import AdaRender
import Foundation
import Testing

@Suite("Baked Shader Graph resources", .serialized)
struct ShaderGraphArchiveTests {
    @Test func archivesRoundTripAndResolveOnlyExactVariants() throws {
        let graph = ShaderGraph(target: .sprite, output: "out", nodes: [.init(id: "out", operation: .output)])
        let source = "archive-test-\(UUID().uuidString)"
        let fragment = ShaderGraphArchive.Fragment(source: source, defines: ["ADA_MORPH": "1"], entryPoint: "fragment", wgsl: "@fragment fn fragment() {}", reflection: .init())
        let original = ShaderGraphArchive(graphs: ["@res://graph.shadergraph": graph], fragments: [fragment], texturePaths: [])
        let decoded = try JSONDecoder().decode(ShaderGraphArchive.self, from: JSONEncoder().encode(original))
        try ShaderGraphRuntimeLibrary.install(decoded)
        #expect(try ShaderGraphRuntimeLibrary.graph(at: "@res://graph.shadergraph") == graph)
        #expect(ShaderGraphRuntimeLibrary.fragment(source: source, defines: [.define("ADA_MORPH")])?.entryPoint == "fragment")
        #expect(ShaderGraphRuntimeLibrary.fragment(source: source, defines: []) == nil)
        #expect(ShaderGraphRuntimeLibrary.fragment(source: source + "\n", defines: [.define("ADA_MORPH")]) == nil)
    }

    @Test func invalidArchivesDoNotInstall() throws {
        var archive = ShaderGraphArchive(graphs: [:], fragments: [], texturePaths: [])
        // A GLSL-era archive is rejected with an explicit migration message.
        archive.version = 1
        #expect(throws: ShaderGraphDiagnostic.self) { try ShaderGraphRuntimeLibrary.install(archive) }
        archive.version = ShaderGraphArchive.currentVersion
        archive.fragments = [.init(source: "", defines: [:], entryPoint: "main", wgsl: "", reflection: .init())]
        #expect(throws: ShaderGraphDiagnostic.self) { try ShaderGraphRuntimeLibrary.install(archive) }
        #expect(throws: ShaderGraphDiagnostic.self) { try ShaderGraphRuntimeLibrary.graph(at: "@res://missing-graph.shadergraph") }
        #expect(throws: ShaderGraphDiagnostic.self) { try ShaderGraphRuntimeLibrary.texture(at: "@res://missing-texture.png") }
    }
}
