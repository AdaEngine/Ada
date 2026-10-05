@testable import AdaRender
import Testing

@Suite("Sparse vertex buffer slots")
struct VertexBufferSlotTests {
    @Test func meshInstancesAndDefaultsKeepTheirEngineIndices() {
        var descriptor = VertexDescriptor()
        descriptor.attributes[0] = .attribute(.vector3, name: "position", bufferIndex: 0, offset: 0)
        descriptor.attributes[5] = .attribute(.vector4, name: "instanceModel", bufferIndex: 3, offset: 0)
        descriptor.attributes[6] = .attribute(.vector4, name: "instanceColor", bufferIndex: 3, offset: 64)
        descriptor.attributes[13] = .attribute(.vector4, name: "defaultJoints", bufferIndex: 4, offset: 32)
        #expect(descriptor.activeBufferIndices == [0, 3, 4])
    }

    @Test func emptyDescriptorHasNoVertexBufferSlots() {
        #expect(VertexDescriptor().activeBufferIndices.isEmpty)
    }
}
