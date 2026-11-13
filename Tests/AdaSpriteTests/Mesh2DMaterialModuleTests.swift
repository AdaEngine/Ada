import AdaAssets
@testable import AdaRender
@testable import AdaSprite
import Testing

/// Canvas materials choose a complete shader module per vertex layout (WESL variants). The 2D mesh pass must ask the
/// material for it instead of compiling the material's legacy sources, which are empty for variant materials.
@Suite("Mesh2D material shader modules")
struct Mesh2DMaterialModuleTests {
    private struct Probe: Error, Equatable {
        let defines: [String]
    }

    private final class ProbeMaterial: Material, @unchecked Sendable {
        init() { super.init(shaderSource: ShaderSource()) }

        required convenience init(from assetDecoder: AssetDecoder) throws { self.init() }

        override func makeShaderModule(defines: [ShaderDefine]) throws -> ShaderModule {
            throw Probe(defines: defines.map(\.name))
        }
    }

    @Test("The mesh pass requests the module through the material with the vertex-layout defines")
    func usesTheMaterialsModuleFactory() {
        let material = ProbeMaterial()
        let key = MaterialMesh2dKey(
            defines: [.define("VERTEX_POSITIONS"), .define("VERTEX_UVS")],
            keys: [],
            vertexDescritor: VertexDescriptor()
        )
        #expect(throws: Probe(defines: ["VERTEX_POSITIONS", "VERTEX_UVS"])) {
            try material.makeMesh2dShaderModule(for: key)
        }
    }
}
