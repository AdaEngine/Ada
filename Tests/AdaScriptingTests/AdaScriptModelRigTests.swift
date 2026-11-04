import AdaAssets
@testable import AdaScripting
import Foundation
import Testing

@Suite("AdaScript interpreted rig authoring", .serialized)
@MainActor
struct AdaScriptModelRigTests {
    @Test("Interprets recipes with platform line endings", arguments: ["\n", "\r\n", "\r"])
    func lineEndings(ending: String) throws {
        let source = """
        func build(m) {
            var part = m.box(1, 1, 1);
            var root = m.joint("Root", -1, 0, 0, 0);
            m.bind(part, root);
            var clip = m.clip("Idle");
            m.rotationKey(clip, root, 0, 0, 0, 0);
            m.rotationKey(clip, root, 1, 0, 5, 0);
        }
        """.replacingOccurrences(of: "\n", with: ending)
        let model = try AdaScriptModelGenerator.generate(source: source)
        let imported = try NativeGLTFLoader().load(data: GLBWriter().encode(model))
        #expect(imported.skins.first?.joints.count == 1)
        #expect(imported.animations.first?.name == "Idle")
    }

    @Test("Interpreted recipe exports joints, weights, clips and transformed geometry through the native importer")
    func exportsRig() throws {
        let model = try AdaScriptModelGenerator.generate(source: """
        func build(m) {
            var p = m.box(1, 2, 1);
            m.name(p, "Probe");
            m.place(p, 0, 1, 0);
            m.scale(p, 2, 1, 3);
            var root = m.joint("Root", -1, 0, 0, 0);
            var head = m.joint("Head", root, 0, 1, 0);
            assert(m.partCount() == 1);
            assert(m.partName(p) == "Probe" && m.partParent(p) == -1 && m.hasMesh(p));
            assert(m.vertexCount(p) == 24);
            m.bind(p, root);
            m.weights(p, 0, root, 0.25, head, 0.75);
            var clip = m.clip("Walk");
            m.rotationKey(clip, head, 0, 0, 0, 0);
            m.rotationKey(clip, head, 1, 0, 90, 0);
            m.translationKey(clip, root, 0, 0, 0, 0);
            m.translationKey(clip, root, 1, 0, 0.1, 0);
        }
        """)
        let imported = try NativeGLTFLoader().load(data: GLBWriter().encode(model))
        #expect(imported.skins.count == 1 && imported.skins[0].joints == [1, 2])
        #expect(imported.skins[0].inverseBindMatrices[1].w.y == -1)
        #expect(imported.animations.first?.name == "Walk" && imported.animations.first?.duration == 1)
        let primitive = try #require(imported.meshes.first?.primitives.first)
        #expect(primitive.skinning?.jointIndices[0] == SIMD4(0, 1, 0, 0))
        #expect(primitive.skinning?.weights[0].x == 0.25 && primitive.skinning?.weights[0].y == 0.75)
        let positions = try #require(primitive.attributes[.position]?.vector3Values())
        #expect(positions.map(\.y).min() == 0 && positions.map(\.y).max() == 2)
        #expect(positions.map(\.z).max() == 1.5)
    }

    @Test("World vertex queries and baked normals agree with rotated custom geometry")
    func worldVertices() throws {
        let model = try AdaScriptModelGenerator.generate(source: """
        func build(m) {
            m.vertex(1, 0, 0);
            m.vertex(0, 1, 0);
            m.vertex(0, 0, 0);
            m.triangle(0, 1, 2);
            var p = m.mesh();
            m.scale(p, 2, 3, 1);
            m.rotate(p, 0, 0, 90);
            m.place(p, 0, 1, 0);
            var root = m.joint("Root", -1, 0, 0, 0);
            assert(Math.abs(m.vertexPosition(p, 0, 1) - 3) < 0.0001);
            m.bind(p, root);
        }
        """)
        let mesh = try #require(model.nodes.last?.mesh)
        #expect(mesh.normals.allSatisfy { $0.z > 0.999 })
        #expect(model.nodes.last?.scale == .one)
    }

    @Test("Rejects invalid bindings, joint hierarchies, key times, late geometry edits and oversized integer indices")
    func rejectsInvalidRecipes() {
        let tail = [
            "m.joint(\"Other root\", -1, 0, 0, 0);",
            "m.joint(\"Bad\", 99, 0, 0, 0);",
            "m.joint(\"Root\", 0, 0, 0, 0);",
            "m.bind(p, 99);",
            "m.weights(p, 0, r, 0, r, 0);",
            "m.weights(p, 0, r, 0.7, r, 0.8);",
            "m.weights(p, 99, r, 1, r, 0);",
            "m.box(1, 1, 1);",
            "m.place(p, 0, 1, 0);",
            "m.rotationKey(m.clip(\"Walk\"), 99, 0, 0, 0, 0);",
            "var c = m.clip(\"Walk\"); m.rotationKey(c, r, 1, 0, 0, 0); m.rotationKey(c, r, 1, 0, 0, 0);",
            "m.partName(9223372036854775807);",
        ]
        for invalid in tail {
            let source = "func build(m) { var p = m.box(1, 1, 1); var r = m.joint(\"Root\", -1, 0, 0, 0); m.bind(p, r); " + invalid + " }"
            #expect(throws: (any Error).self) { try AdaScriptModelGenerator.generate(source: source) }
        }
        #expect(throws: (any Error).self) {
            try AdaScriptModelGenerator.generate(source: "func build(m) { m.box(1, 1, 1); m.joint(\"Root\", -1, 0, 0, 0); }")
        }
    }
}
