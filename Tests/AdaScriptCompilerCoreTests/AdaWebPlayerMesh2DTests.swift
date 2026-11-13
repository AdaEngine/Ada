import AdaScriptCompilerCore
import Testing

@Suite("Web Player 2D mesh scene component")
struct AdaWebPlayerMesh2DTests {
    @Test("Studio's default payload decodes without edits")
    func studioDefaults() throws {
        // Studio writes mesh/size plus 3D-only keys; the 2D component ignores the extras.
        let mesh = try AdaWebPlayerMesh2D(mesh: "Quad", size: 64)
        #expect(mesh.primitive == .quad)
        #expect(mesh.size == 64)
    }

    @Test("Missing fields use Studio's 2D defaults")
    func defaults() throws {
        let mesh = try AdaWebPlayerMesh2D(mesh: nil, size: nil)
        #expect(mesh.primitive == .quad)
        #expect(mesh.size == AdaWebPlayerMesh2D.defaultSize)
        #expect(AdaWebPlayerMesh2D.defaultSize == 64)
    }

    @Test("Circle is supported")
    func circle() throws {
        #expect(try AdaWebPlayerMesh2D(mesh: "Circle", size: 2).primitive == .circle)
    }

    @Test("3D-only primitives are rejected", arguments: ["Cube", "Sphere", "Plane", "", "quad"])
    func unsupportedPrimitive(name: String) {
        #expect(throws: AdaWebPlayerProjectError.self) { try AdaWebPlayerMesh2D(mesh: name, size: 1) }
    }

    @Test("Invalid sizes are rejected", arguments: [0.0, -1.0, .infinity, -.infinity, .nan, 100_000.5])
    func invalidSize(size: Double) {
        #expect(throws: AdaWebPlayerProjectError.self) { try AdaWebPlayerMesh2D(mesh: "Quad", size: size) }
    }

    @Test("The size limit is inclusive")
    func maximumSize() throws {
        #expect(try AdaWebPlayerMesh2D(mesh: "Quad", size: 100_000).size == 100_000)
    }
}
