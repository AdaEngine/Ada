@_spi(Internal) import AdaRender
@testable import AdaCorePipelines
import Math
import Testing

private final class FakeStructure: AccelerationStructure, @unchecked Sendable {
    let kind: AccelerationStructureKind
    init(_ kind: AccelerationStructureKind) { self.kind = kind }
}

private final class Token {}

@Suite("Path tracing acceleration structure owner")
struct Render3DAccelerationStructureOwnerTests {
    private let first = PathTracing3DPartKey(vertexBuffer: ObjectIdentifier(Token()), indexBuffer: ObjectIdentifier(Token()), indexCount: 6)
    private let second = PathTracing3DPartKey(vertexBuffer: ObjectIdentifier(Token()), indexBuffer: ObjectIdentifier(Token()), indexCount: 3)

    private func placement(_ key: PathTracing3DPartKey, triangles: Int, shadows: Bool = true, x: Float = 0) -> PathTracing3DPlacement {
        PathTracing3DPlacement(key: key, transform: .identity.translatedBy(Vector3(x, 0, 0)), castsShadows: shadows, triangleCount: triangles)
    }

    // MARK: Instance plan

    @Test func instancesFollowPlacementOrderAndEachStartsWhereThePreviousTrianglesEnd() {
        let plan = PathTracing3DInstancePlan.make([placement(first, triangles: 2), placement(second, triangles: 1), placement(first, triangles: 2, x: 5)])
        #expect(plan.instances.map(\.firstTriangle) == [0, 2, 3])
        #expect(plan.triangleTotal == 5)
        #expect(plan.instances.map(\.key) == [first, second, first])
    }

    @Test func aHitTriangleIsTheInstanceStartPlusThePrimitiveIndex() {
        let plan = PathTracing3DInstancePlan.make([placement(first, triangles: 4), placement(second, triangles: 3)])
        #expect(plan.instances.map { Int($0.firstTriangle) + 2 } == [2, 6])
    }

    @Test func shadowCastersCarryTheShadowBitAndAreStillSeenByEveryRay() {
        let plan = PathTracing3DInstancePlan.make([placement(first, triangles: 1, shadows: true), placement(second, triangles: 1, shadows: false)])
        let masks = plan.instances.map(\.mask)
        #expect(masks.map { $0 & PathTracing3DInstancePlan.shadowCasterMask != 0 } == [true, false])
        #expect(masks.allSatisfy { $0 != 0 })
    }

    @Test func placementsKeepTheirTransforms() {
        let plan = PathTracing3DInstancePlan.make([placement(first, triangles: 1, x: 3)])
        #expect(plan.instances.map(\.transform.w.x) == [3])
    }

    @Test func emptyPartsAndEmptyInputProduceNoInstances() {
        #expect(PathTracing3DInstancePlan.make([]).instances.isEmpty)
        let plan = PathTracing3DInstancePlan.make([placement(first, triangles: 0), placement(second, triangles: 2)])
        #expect(plan.instances.map(\.firstTriangle) == [0] && plan.triangleTotal == 2)
    }

    // MARK: Cache

    @Test func aPartIsBuiltOnceAndSharedByEveryPlacement() {
        let owner = PathTracing3DAccelerationStructures()
        var created = 0
        let make: (Int) -> (any AccelerationStructure)? = { created += 1; return FakeStructure(.bottomLevel(triangleCapacity: $0)) }
        let a = owner.resolveBottom(first, triangleCount: 2, create: make)
        let b = owner.resolveBottom(first, triangleCount: 2, create: make)
        #expect(created == 1 && a?.isNew == true && b?.isNew == false)
        #expect(a.map { ObjectIdentifier($0.structure) } == b.map { ObjectIdentifier($0.structure) })
    }

    @Test func aFailedCreationIsReportedAndNotCached() {
        let owner = PathTracing3DAccelerationStructures()
        #expect(owner.resolveBottom(first, triangleCount: 2, create: { _ in nil }) == nil)
        var created = 0
        #expect(owner.resolveBottom(first, triangleCount: 2, create: { created += 1; return FakeStructure(.bottomLevel(triangleCapacity: $0)) })?.isNew == true)
        #expect(created == 1)
    }

    @Test func unusedPartsAreEvictedAndTheirKeysReturned() {
        let owner = PathTracing3DAccelerationStructures()
        let make: (Int) -> (any AccelerationStructure)? = { FakeStructure(.bottomLevel(triangleCapacity: $0)) }
        _ = owner.resolveBottom(first, triangleCount: 2, create: make)
        _ = owner.resolveBottom(second, triangleCount: 1, create: make)
        #expect(owner.retain([second]) == [first])
        #expect(owner.bottoms.keys.contains(second) && !owner.bottoms.keys.contains(first))
        #expect(owner.resolveBottom(first, triangleCount: 2, create: make)?.isNew == true)
    }

    @Test func theTopLevelStructureGrowsOnlyWhenItsCapacityIsExceeded() {
        let owner = PathTracing3DAccelerationStructures()
        var created: [Int] = []
        let make: (Int) -> (any AccelerationStructure)? = { created.append($0); return FakeStructure(.topLevel(instanceCapacity: $0)) }
        #expect(owner.resolveTop(instanceCount: 3, create: make)?.isNew == true)
        let capacity = created.first ?? 0
        #expect(capacity >= 3)
        #expect(owner.resolveTop(instanceCount: 2, create: make)?.isNew == false)
        #expect(owner.resolveTop(instanceCount: capacity, create: make)?.isNew == false)
        #expect(owner.resolveTop(instanceCount: capacity + 1, create: make)?.isNew == true)
        #expect(created.count == 2 && (created.last ?? 0) > capacity)
    }

    @Test func removingEverythingForgetsTheCache() {
        let owner = PathTracing3DAccelerationStructures()
        _ = owner.resolveBottom(first, triangleCount: 1, create: { FakeStructure(.bottomLevel(triangleCapacity: $0)) })
        _ = owner.resolveTop(instanceCount: 1, create: { FakeStructure(.topLevel(instanceCapacity: $0)) })
        owner.removeAll()
        #expect(owner.bottoms.isEmpty && owner.top == nil)
    }
}
