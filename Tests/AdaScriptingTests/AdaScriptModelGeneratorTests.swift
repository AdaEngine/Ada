import AdaAssets
@testable import AdaScripting
import Testing

@Suite("AdaScript model generator", .serialized)
@MainActor
struct AdaScriptModelGeneratorTests {
    @Test("Builds a hierarchy of primitives with materials and encodes it as GLB")
    func buildsHierarchy() throws {
        let model = try AdaScriptModelGenerator.generate(
            source: """
            func build(model) {
                assert(Identifiers.uuid().length == 36);
                model.material(1, 0.8, 0.1, 0.1);
                model.surface(1, 0.0, 0.4);
                model.material(2, 0.1, 0.1, 0.9);
                model.emissive(2, 0.0, 0.0, 0.5);
                var root = model.group();
                model.name(root, "Lamp");
                var base = model.cylinder(0.4, 0.5, 0.1, 16);
                model.paint(base, 1);
                model.parent(base, root);
                var bulb = model.sphere(0.25, 12);
                model.paint(bulb, 2);
                model.place(bulb, 0.0, 0.6, 0.0);
                model.rotate(bulb, 0.0, 90.0, 0.0);
                model.scale(bulb, 1.0, 1.5, 1.0);
                model.parent(bulb, root);
            }
            """
        )
        #expect(model.nodes.map(\.name) == ["Lamp", "Cylinder 1", "Sphere 2"])
        #expect(model.nodes[1].parent == 0 && model.nodes[2].parent == 0)
        #expect(model.nodes[0].mesh == nil)
        #expect(model.nodes[2].translation == SIMD3<Float>(0, 0.6, 0))
        #expect(model.nodes[2].scale == SIMD3<Float>(1, 1.5, 1))
        #expect(model.nodes[2].rotation != SIMD4<Float>(0, 0, 0, 1))
        #expect(model.materials.count == 2)
        #expect(model.materials[0].baseColor == SIMD4<Float>(0.8, 0.1, 0.1, 1))
        #expect(model.materials[0].roughness == 0.4)
        #expect(model.materials[1].emissive == SIMD3<Float>(0, 0, 0.5))
        #expect(model.nodes[1].material == 0 && model.nodes[2].material == 1)

        let data = try GLBWriter().encode(model)
        let imported = try NativeGLTFLoader().load(data: data)
        #expect(imported.nodes.count == 3)
        #expect(imported.nodes[0].children == [1, 2])
    }

    @Test("Revolves a profile, builds custom triangles and loops inside the script")
    func profilesAndTriangles() throws {
        let model = try AdaScriptModelGenerator.generate(
            source: """
            func build(model) {
                model.profile(0.0, 1.0);
                model.profile(0.5, 1.0);
                model.profile(0.3, 0.0);
                model.profile(0.0, 0.0);
                var vase = model.lathe(12);
                var a = model.vertex(0.0, 0.0, 0.0);
                var b = model.vertex(1.0, 0.0, 0.0);
                var c = model.vertex(0.0, 1.0, 0.0);
                model.triangle(a, b, c);
                var wedge = model.mesh();
                var i = 0;
                while (i < 3) {
                    var post = model.box(0.1, 1.0, 0.1);
                    model.place(post, i * 1.0, 0.0, 0.0);
                    i = i + 1;
                }
                model.place(wedge, 0.0, 0.0, 2.0);
            }
            """
        )
        #expect(model.nodes.count == 5)
        #expect(model.nodes[0].mesh?.isEmpty == false)
        #expect(model.nodes[1].mesh?.positions.count == 3)
        #expect(model.nodes[4].translation == SIMD3<Float>(2, 0, 0))
        #expect(model.materials.count == 1)
    }

    @Test("Rejects invalid scripts and arguments with an error")
    func rejectsInvalidScripts() {
        let scripts = [
            "func build(model) { }",
            "func build(model) { model.box(0.0, 1.0, 1.0); }",
            "func build(model) { model.sphere(1.0, 2); }",
            "func build(model) { model.capsule(1.0, 1.0, 12); }",
            "func build(model) { model.torus(0.5, 1.0, 12); }",
            "func build(model) { model.material(64, 0.0, 0.0, 0.0); model.box(1.0, 1.0, 1.0); }",
            "func build(model) { model.material(0, 2.0, 0.0, 0.0); model.box(1.0, 1.0, 1.0); }",
            "func build(model) { var a = model.box(1.0, 1.0, 1.0); model.parent(a, a); }",
            "func build(model) { var a = model.box(1.0, 1.0, 1.0); model.scale(a, -1.0, 1.0, 1.0); }",
            "func build(model) { var a = model.box(1.0, 1.0, 1.0); model.place(a + 5, 0.0, 0.0, 0.0); }",
            "func build(model) { model.lathe(8); }",
            "func build(model) { model.mesh(); }",
            "func build(model) { model.triangle(0, 1, 2); model.box(1.0, 1.0, 1.0); }",
            "func build(model) { model.box(1.0, 1.0, 1.0); System.exit(1); }",
            "func build(model) { while (true) { } }",
            "func other() { }",
        ]
        for script in scripts {
            #expect(throws: (any Error).self, "\(script)") { try AdaScriptModelGenerator.generate(source: script) }
        }
    }

    @Test("Enforces the part and vertex budgets")
    func enforcesBudgets() {
        let tooManyParts = """
            func build(model) {
                var i = 0;
                while (i < 600) { model.box(1.0, 1.0, 1.0); i = i + 1; }
            }
            """
        #expect(throws: (any Error).self) { try AdaScriptModelGenerator.generate(source: tooManyParts) }
        let tooManyVertices = """
            func build(model) {
                var i = 0;
                while (i < 60) { model.sphere(1.0, 64); i = i + 1; }
            }
            """
        #expect(throws: (any Error).self) { try AdaScriptModelGenerator.generate(source: tooManyVertices) }
    }
}
