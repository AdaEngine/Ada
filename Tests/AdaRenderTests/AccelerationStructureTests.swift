@testable import AdaRender
import Foundation
import Math
import Testing

private final class FakeBuffer: Buffer, @unchecked Sendable {
    var label: String?
    let length: Int
    init(length: Int) { self.length = length }
    func setData(_: UnsafeMutableRawPointer, byteCount _: Int, offset _: Int) {}
    func contents() -> UnsafeMutableRawPointer { fatalError("not mapped") }
    func unmap() {}
}

private final class FakeIndexBuffer: IndexBuffer, @unchecked Sendable {
    var label: String?
    let length: Int
    let indexFormat: IndexBufferFormat
    init(length: Int, format: IndexBufferFormat = .uInt32) {
        self.length = length
        indexFormat = format
    }
    func setData(_: UnsafeMutableRawPointer, byteCount _: Int, offset _: Int) {}
    func contents() -> UnsafeMutableRawPointer { fatalError("not mapped") }
    func unmap() {}
}

private final class FakeStructure: AccelerationStructure, @unchecked Sendable {
    let kind: AccelerationStructureKind
    init(_ kind: AccelerationStructureKind) { self.kind = kind }
}

@Suite("Acceleration structure inputs")
struct AccelerationStructureTests {
    private func geometry(
        stride: Int = 12, offset: Int = 0, vertices: Int = 3, bufferLength: Int = 36, indexCount: Int = 0, indexLength: Int = 0,
        format: IndexBufferFormat = .uInt32
    ) -> AccelerationStructureGeometry {
        AccelerationStructureGeometry(
            vertexBuffer: FakeBuffer(length: bufferLength), vertexOffset: offset, vertexStride: stride, vertexCount: vertices,
            indexBuffer: indexCount > 0 ? FakeIndexBuffer(length: indexLength, format: format) : nil, indexCount: indexCount
        )
    }

    @Test func aTightTriangleListIsValidAndCountsItsTriangles() throws {
        let value = geometry(vertices: 6, bufferLength: 72)
        try value.validate()
        #expect(value.triangleCount == 2)
    }

    @Test func indexedGeometryCountsTrianglesFromTheIndices() throws {
        let value = geometry(vertices: 4, bufferLength: 48, indexCount: 6, indexLength: 24)
        try value.validate()
        #expect(value.triangleCount == 2)
    }

    @Test func aStrideBelowOneVertexOrOffAlignmentIsRejected() {
        #expect(throws: AccelerationStructureError.self) { try geometry(stride: 8).validate() }
        #expect(throws: AccelerationStructureError.self) { try geometry(stride: 14, bufferLength: 64).validate() }
        #expect(throws: AccelerationStructureError.self) { try geometry(offset: 2, bufferLength: 40).validate() }
    }

    @Test func positionsMustFitInsideTheVertexBuffer() throws {
        #expect(throws: AccelerationStructureError.self) { try geometry(bufferLength: 35).validate() }
        try geometry(stride: 32, vertices: 3, bufferLength: 32 * 2 + 12).validate()
        #expect(throws: AccelerationStructureError.self) { try geometry(stride: 32, vertices: 3, bufferLength: 32 * 2 + 11).validate() }
    }

    @Test func emptyOrPartialTrianglesAreRejected() {
        #expect(throws: AccelerationStructureError.self) { try geometry(vertices: 0).validate() }
        #expect(throws: AccelerationStructureError.self) { try geometry(vertices: 4, bufferLength: 48).validate() }
        #expect(throws: AccelerationStructureError.self) { try geometry(vertices: 4, bufferLength: 48, indexCount: 4, indexLength: 16).validate() }
    }

    @Test func theIndexBufferMustHoldEveryIndex() throws {
        #expect(throws: AccelerationStructureError.self) { try geometry(indexCount: 3, indexLength: 11).validate() }
        try geometry(indexCount: 3, indexLength: 12).validate()
        try geometry(indexCount: 3, indexLength: 6, format: .uInt16).validate()
        #expect(throws: AccelerationStructureError.self) { try geometry(indexCount: 3, indexLength: 5, format: .uInt16).validate() }
    }

    @Test func instanceTransformsAreRowMajorWithTranslationLast() {
        let structure = FakeStructure(.bottomLevel(triangleCapacity: 1))
        let translated = AccelerationStructureInstance(structure: structure, transform: .identity.translatedBy(Vector3(2, 3, 4)))
        #expect(translated.rowMajor3x4 == [1, 0, 0, 2, 0, 1, 0, 3, 0, 0, 1, 4])
        #expect(AccelerationStructureInstance(structure: structure).rowMajor3x4 == [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0])
        var scaled = Transform3D.identity
        scaled.x.x = 2
        scaled.y.y = 3
        scaled.z.z = 4
        #expect(AccelerationStructureInstance(structure: structure, transform: scaled).rowMajor3x4 == [2, 0, 0, 0, 0, 3, 0, 0, 0, 0, 4, 0])
    }

    @Test func instancesKeepTheirMaskAndIdentifier() {
        let instance = AccelerationStructureInstance(structure: FakeStructure(.bottomLevel(triangleCapacity: 1)), mask: 2, instanceID: 73)
        #expect(instance.mask == 2 && instance.instanceID == 73)
        #expect(AccelerationStructureInstance(structure: FakeStructure(.topLevel(instanceCapacity: 1))).mask == 0xff)
    }

    @Test func devicesWithoutRayTracingReportNoSupportAndCreateNothing() {
        let device = HeadlessRenderBackend().renderDevice
        #expect(!device.supportsRayQueries)
        #expect(device.createAccelerationStructure(.bottomLevel(triangleCapacity: 4)) == nil)
        #expect(device.createAccelerationStructure(.topLevel(instanceCapacity: 4)) == nil)
    }
}
