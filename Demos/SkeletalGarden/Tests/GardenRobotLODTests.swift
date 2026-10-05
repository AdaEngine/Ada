import AdaEngine
import Foundation
import Testing

@Suite
struct GardenRobotLODTests {
    @Test
    func indexOnlyLODsPreserveTheRigClipsInfluencesAndMaterialSlots() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Assets")
        let loader = NativeGLTFLoader()
        let base = try loader.load(data: Data(contentsOf: directory.appendingPathComponent("GardenRobot.glb")))
        for level in 1...2 {
            let lod = try loader.load(data: Data(contentsOf: directory.appendingPathComponent("GardenRobotLOD\(level).glb")))
            #expect(lod.nodes.count == base.nodes.count)
            #expect(lod.skins.count == base.skins.count)
            #expect(lod.animations.map(\.name) == base.animations.map(\.name))
            for (a, b) in zip(base.skins, lod.skins) {
                #expect(a.joints == b.joints)
                #expect(a.inverseBindMatrices == b.inverseBindMatrices)
            }
            for (a, b) in zip(base.nodes, lod.nodes) {
                #expect(a.transform == b.transform)
                #expect(a.children == b.children)
                #expect(a.skinIndex == b.skinIndex)
                #expect(a.meshIndex == b.meshIndex)
            }
            var baseTriangles = 0
            var lodTriangles = 0
            for (original, alternative) in zip(base.meshes, lod.meshes) {
                #expect(original.primitives.count == alternative.primitives.count)
                for (a, b) in zip(original.primitives, alternative.primitives) {
                    #expect(a.attributes[.position]?.values == b.attributes[.position]?.values)
                    #expect(a.materialIndex == b.materialIndex)
                    #expect(a.skinning?.jointIndices == b.skinning?.jointIndices)
                    #expect(a.skinning?.weights == b.skinning?.weights)
                    baseTriangles += try #require(a.indices).count / 3
                    lodTriangles += try #require(b.indices).count / 3
                }
            }
            #expect(lodTriangles < baseTriangles)
        }
    }
}
