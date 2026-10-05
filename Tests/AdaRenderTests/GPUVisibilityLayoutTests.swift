import Testing

@testable import AdaRender

@Suite
struct GPUVisibilityLayoutTests {
    @Test
    func indirectAndCandidateLayoutsMatchTheDeviceABI() {
        #expect(MemoryLayout<IndexedIndirectArguments>.stride == 20)
        #expect(MemoryLayout<IndexedIndirectArguments>.offset(of: \.instanceCount) == 4)
        #expect(MemoryLayout<IndexedIndirectArguments>.offset(of: \.baseVertex) == 12)
        #expect(MemoryLayout<GPUVisibilityCandidate>.stride == 48)
        #expect(MemoryLayout<GPUVisibilityCandidate>.offset(of: \.draw) == 32)
    }
}
