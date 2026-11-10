@_spi(Internal) @testable import AdaRender
import Math
import Testing

@Suite("GPU shadow cull input")
struct GPUShadowCullInputTests {
    @Test("consistent inputs are valid")
    func acceptsConsistentInput() {
        #expect(Self.input().isValid)
    }

    @Test("inputs that would write outside a segment or read outside the records are rejected")
    func rejectsInconsistentInput() {
        var input = Self.input()
        input.segments = [0, 2]
        #expect(!input.isValid, "Part 1 starts after part 0's single caster")

        input = Self.input()
        input.casters[0].instance = 9
        #expect(!input.isValid, "Instance record out of range")

        input = Self.input()
        input.casters[1] = GPUShadowCaster(bounds: nil, forceVisible: false, part: 5, instance: 1)
        #expect(!input.isValid, "Part out of range")

        input = Self.input()
        input.copiedBytes = input.instanceStride + 4
        #expect(!input.isValid, "Copy longer than a record")

        input = Self.input()
        input.instances.removeLast()
        #expect(!input.isValid, "Partial record")
    }

    @Test("view planes match the rows of the view-projection")
    func viewPlanes() {
        let matrix = Transform3D.orthographic(left: -1, right: 1, top: 1, bottom: -1, zNear: 0, zFar: 1)
        let view = GPUShadowCullView(viewProjection: matrix, culls: true)
        #expect(view.plane0 == matrix.row(at: 3) + matrix.row(at: 0))
        #expect(view.plane5 == matrix.row(at: 3) - matrix.row(at: 2))
        #expect(view.culls == 1)
        #expect(MemoryLayout<GPUShadowCullView>.stride == 112)
        #expect(MemoryLayout<GPUShadowCaster>.stride == 48)
    }

    private static func input() -> GPUShadowCullInput {
        var input = GPUShadowCullInput()
        let box = AABB(min: [-1, -1, -1], max: [1, 1, 1])
        input.casters = [
            GPUShadowCaster(bounds: box, forceVisible: false, part: 0, instance: 0),
            GPUShadowCaster(bounds: box, forceVisible: false, part: 1, instance: 1),
            GPUShadowCaster(bounds: nil, forceVisible: false, part: 1, instance: 2),
        ]
        input.instanceStride = 16
        input.copiedBytes = 16
        input.instances = [UInt8](repeating: 0, count: 48)
        input.parts = [IndexedIndirectArguments(indexCount: 3), IndexedIndirectArguments(indexCount: 6)]
        input.segments = [0, 1]
        return input
    }
}
