import AdaEngine
@_spi(Internal) @testable import AdaRender
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Closed operands include every selected node and primitive with inherited reflection and placement")
    func volumeModelIncludesCompleteScene() async throws {
        _ = try await makeApp()
        let device = unsafe RenderEngine.shared.renderDevice
        let cube = Mesh.generateCube(renderDevice: device)
        let source = try #require(cube.models.first?.parts.first?.meshDescriptor)
        var first = source, second = source
        first.indicies = Array(source.indicies.prefix(source.indicies.count / 2))
        second.indicies = Array(source.indicies.suffix(source.indicies.count / 2))
        let split = Mesh.generate(from: [first, second], renderDevice: device)
        let model = ModelAsset3D(
            nodes: [
                .init(name: "Root", transform: .init(translation: [3, 0, 0], rotation: .identity, scale: [-2, 1, 1]), meshIndex: nil, children: [1, 2]),
                .init(name: "Left", transform: .init(translation: [-2, 0, 0]), meshIndex: 0, children: []),
                .init(name: "Right", transform: .identity, meshIndex: 0, children: [], restPose: .init(translation: [2, 0, 0])),
                .init(name: "Other scene", transform: .init(translation: [20, 0, 0]), meshIndex: 0, children: [])
            ],
            meshes: [split],
            materials: [PBRMaterial()],
            scenes: [[0], [3]],
            defaultScene: 0
        )
        let operation = TerrainVolumeOperation(
            operation: .union,
            operand: .mesh(assetPath: "solid.gltf", scene: nil),
            transform: .init(translation: [1, 5, 2], rotation: .identity, scale: [1, 2, 1])
        )
        let prepared = try #require(try? TerrainVolumePreparedMesh(operation: operation, model: model), "Closed multi-primitive model scenes must prepare")
        let base = try TerrainHeightStorage(importing: Terrain3D(resolution: 65, size: 64))
        let field = try TerrainVolumeField(document: .init(cellSize: 0.5, operations: [operation]), base: base, preparedMeshes: [prepared])
        #expect(try field.sample(at: [8, 5, 2]).value < 0)
        #expect(try field.sample(at: [0, 5, 2]).value < 0)
        #expect(try field.sample(at: [4, 5, 2]).value > 0)
        #expect(try field.sample(at: [21, 5, 2]).value > 0)
        let other = TerrainVolumeOperation(operation: .union, operand: .mesh(assetPath: "solid.gltf", scene: 1), transform: operation.transform)
        let selected = try #require(try? TerrainVolumePreparedMesh(operation: other, model: model))
        let selectedField = try TerrainVolumeField(document: .init(cellSize: 0.5, operations: [other]), base: base, preparedMeshes: [selected])
        #expect(try selectedField.sample(at: [21, 5, 2]).value < 0)
        #expect(try selectedField.sample(at: [8, 5, 2]).value > 0)
    }

    @Test("Model solid preparation rejects open geometry, deformed scenes and insufficient staging budgets")
    func volumeModelRejectsUnsupportedInputs() async throws {
        _ = try await makeApp()
        let device = unsafe RenderEngine.shared.renderDevice
        let cube = Mesh.generateCube(renderDevice: device)
        let operation = TerrainVolumeOperation(operation: .union, operand: .mesh(assetPath: "solid.gltf", scene: nil))
        func model(_ mesh: Mesh, skin: Int? = nil) -> ModelAsset3D {
            .init(
                nodes: [.init(name: "Solid", transform: .identity, meshIndex: 0, children: [], skinIndex: skin)],
                meshes: [mesh],
                materials: [PBRMaterial()],
                scenes: [[0]],
                defaultScene: 0
            )
        }
        let valid = model(cube)
        let prepared = try? TerrainVolumePreparedMesh(operation: operation, model: valid)
        #expect(prepared != nil, "The closed control must prepare before testing rejection")
        #expect(throws: TerrainVolumeFieldError.memoryBudgetExceeded) { try TerrainVolumePreparedMesh(operation: operation, model: valid, maximumBytes: 0) }
        var open = try #require(cube.models.first?.parts.first?.meshDescriptor)
        open.indicies.removeLast(3)
        #expect(throws: (any Error).self) { try TerrainVolumePreparedMesh(operation: operation, model: model(Mesh.generate(from: [open], renderDevice: device))) }
        #expect(throws: TerrainMeshPrototypeError.unsupportedDeformation) { try TerrainVolumePreparedMesh(operation: operation, model: model(cube, skin: 0)) }
    }
}
