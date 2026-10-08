//
//  VisibilitySystemTests.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 12.12.2025.
//

import Testing
@_spi(Internal) @testable import AdaRender
@_spi(Internal) import AdaECS
import AdaTransform
import AdaUtils
import AdaUtilsTesting
import Math

@Suite(
    "Visibility System Tests",
    .environments {
        $0.ecs.useSystemDependencies = false
    }
)
struct VisibilitySystemTests {

    let world: World

    init() {
        self.world = World()
        self.world.addSystem(TransformSystem.self, on: .preUpdate)
        self.world.addSystem(VisibilitySystem.self, on: .preUpdate)
    }

    // MARK: - Helper Methods
    
    /// Creates a frustum that represents a simple view volume looking down -Z axis.
    /// The frustum is centered at origin, with near plane at z = -1 and far plane at z = -100.
    /// Width and height are approximately 10 units at near plane.
    private func createTestFrustum() -> Frustum {
        var frustum = Frustum()
        
        // Planes order: left, right, top, bottom, near, far
        // Normals point INTO the contained volume
        
        // Left plane: x >= -5 (normal points right, +X)
        frustum.planes[0] = Plane(normal: Vector3(1, 0, 0), d: 5)
        
        // Right plane: x <= 5 (normal points left, -X)
        frustum.planes[1] = Plane(normal: Vector3(-1, 0, 0), d: 5)
        
        // Top plane: y <= 5 (normal points down, -Y)
        frustum.planes[2] = Plane(normal: Vector3(0, -1, 0), d: 5)
        
        // Bottom plane: y >= -5 (normal points up, +Y)
        frustum.planes[3] = Plane(normal: Vector3(0, 1, 0), d: 5)
        
        // Near plane: z <= -1 (normal points into frustum, -Z)
        frustum.planes[4] = Plane(normal: Vector3(0, 0, -1), d: -1)
        
        // Far plane: z >= -100 (normal points into frustum, +Z)
        frustum.planes[5] = Plane(normal: Vector3(0, 0, 1), d: 100)
        
        return frustum
    }
    
    /// Creates a camera entity with the given frustum and active state.
    private func createCameraEntity(
        in world: World,
        frustum: Frustum,
        isActive: Bool = true
    ) -> Entity {
        var camera = Camera()
        camera.isActive = isActive
        camera.computedData.frustum = frustum
        
        return world.spawn("Camera") {
            camera
            VisibleEntities()
            Transform()
        }
    }
    
    /// Creates an entity with bounding box at the given position.
    private func createBoundedEntity(
        in world: World,
        name: String = "Entity",
        position: Vector3,
        halfExtents: Vector3 = Vector3(0.5, 0.5, 0.5),
        visibility: Visibility = .visible
    ) -> Entity {
        let aabb = AABB(center: position, halfExtents: halfExtents)
        return world.spawn(name) {
            Transform(position: position)
            BoundingComponent(bounds: .aabb(aabb))
            visibility
        }
    }

    private func createEntityWithLocalBounds(
        in world: World,
        name: String = "Entity",
        position: Vector3,
        localCenter: Vector3 = .zero,
        halfExtents: Vector3 = Vector3(0.5, 0.5, 0.5),
        visibility: Visibility = .visible
    ) -> Entity {
        let aabb = AABB(center: localCenter, halfExtents: halfExtents)
        return world.spawn(name) {
            Transform(position: position)
            BoundingComponent(bounds: .aabb(aabb))
            visibility
        }
    }

    // MARK: - Tests
    
    @Test("Entity inside frustum should be visible")
    func entityInsideFrustumIsVisible() async {
        let frustum = createTestFrustum()
        let camera = createCameraEntity(in: world, frustum: frustum)
        
        // Entity at center of frustum (z = -10, well within -1 to -100 range)
        let entity = createBoundedEntity(
            in: world,
            name: "Inside Entity",
            position: Vector3(0, 0, -10)
        )
        
        await world.runScheduler(.preUpdate)

        let visibleEntities = camera.components[VisibleEntities.self]!
        #expect(visibleEntities.entityIds.contains(entity.id))
        #expect(visibleEntities.entities.contains(where: { $0.id == entity.id }))
    }

    @Test("Entity local bounds are tested using global transform")
    func entityLocalBoundsAreTestedUsingGlobalTransform() async {
        let frustum = createTestFrustum()
        let camera = createCameraEntity(in: world, frustum: frustum)

        let entity = createEntityWithLocalBounds(
            in: world,
            name: "Translated Entity",
            position: Vector3(0, 0, -10)
        )

        await world.runScheduler(.preUpdate)
        await world.runScheduler(.preUpdate)

        let visibleEntities = camera.components[VisibleEntities.self]!
        #expect(visibleEntities.entityIds.contains(entity.id))
    }
    
    @Test("Entity outside frustum (behind camera) should be culled")
    func entityBehindCameraIsCulled() async {
        let frustum = createTestFrustum()
        let camera = createCameraEntity(in: world, frustum: frustum)
        
        // Entity behind camera (z = 10, positive Z is behind)
        let entity = createBoundedEntity(
            in: world,
            name: "Behind Entity",
            position: Vector3(0, 0, 10)
        )
        
        await world.runScheduler(.preUpdate)

        let visibleEntities = camera.components[VisibleEntities.self]!
        #expect(!visibleEntities.entityIds.contains(entity.id))
    }
    
    @Test("Entity outside frustum (too far left) should be culled")
    func entityTooFarLeftIsCulled() async {
        let frustum = createTestFrustum()
        let camera = createCameraEntity(in: world, frustum: frustum)
        
        // Entity far to the left (x = -20, outside the -5 to 5 range)
        let entity = createBoundedEntity(
            in: world,
            name: "Left Entity",
            position: Vector3(-20, 0, -10)
        )
        
        await world.runScheduler(.preUpdate)

        let visibleEntities = camera.components[VisibleEntities.self]!
        #expect(!visibleEntities.entityIds.contains(entity.id))
    }
    
    @Test("Entity outside frustum (too far right) should be culled")
    func entityTooFarRightIsCulled() async {
        let frustum = createTestFrustum()
        let camera = createCameraEntity(in: world, frustum: frustum)
        
        // Entity far to the right (x = 20, outside the -5 to 5 range)
        let entity = createBoundedEntity(
            in: world,
            name: "Right Entity",
            position: Vector3(20, 0, -10)
        )
        
        await world.runScheduler(.preUpdate)

        let visibleEntities = camera.components[VisibleEntities.self]!
        #expect(!visibleEntities.entityIds.contains(entity.id))
    }
    
    @Test("Entity outside frustum (above) should be culled")
    func entityAboveIsCulled() async {
        let frustum = createTestFrustum()
        let camera = createCameraEntity(in: world, frustum: frustum)
        
        // Entity above (y = 20, outside the -5 to 5 range)
        let entity = createBoundedEntity(
            in: world,
            name: "Above Entity",
            position: Vector3(0, 20, -10)
        )
        
        await world.runScheduler(.preUpdate)

        let visibleEntities = camera.components[VisibleEntities.self]!
        #expect(!visibleEntities.entityIds.contains(entity.id))
    }
    
    @Test("Entity outside frustum (below) should be culled")
    func entityBelowIsCulled() async {
        let frustum = createTestFrustum()
        let camera = createCameraEntity(in: world, frustum: frustum)
        
        // Entity below (y = -20, outside the -5 to 5 range)
        let entity = createBoundedEntity(
            in: world,
            name: "Below Entity",
            position: Vector3(0, -20, -10)
        )
        
        await world.runScheduler(.preUpdate)

        let visibleEntities = camera.components[VisibleEntities.self]!
        #expect(!visibleEntities.entityIds.contains(entity.id))
    }
    
    @Test("Entity beyond far plane should be culled")
    func entityBeyondFarPlaneIsCulled() async {
        let frustum = createTestFrustum()
        let camera = createCameraEntity(in: world, frustum: frustum)
        
        // Entity beyond far plane (z = -200, beyond -100 far plane)
        let entity = createBoundedEntity(
            in: world,
            name: "Far Entity",
            position: Vector3(0, 0, -200)
        )
        
        await world.runScheduler(.preUpdate)

        let visibleEntities = camera.components[VisibleEntities.self]!
        #expect(!visibleEntities.entityIds.contains(entity.id))
    }
    
    @Test("Entity with hidden visibility should not be visible")
    func hiddenEntityIsNotVisible() async {
        let frustum = createTestFrustum()
        let camera = createCameraEntity(in: world, frustum: frustum)
        
        // Entity inside frustum but marked as hidden
        let entity = createBoundedEntity(
            in: world,
            name: "Hidden Entity",
            position: Vector3(0, 0, -10),
            visibility: .hidden
        )
        
        await world.runScheduler(.preUpdate)

        let visibleEntities = camera.components[VisibleEntities.self]!
        #expect(!visibleEntities.entityIds.contains(entity.id))
    }
    
    @Test("Inactive camera should not update visible entities")
    func inactiveCameraDoesNotUpdateVisibleEntities() async {
        let frustum = createTestFrustum()
        let camera = createCameraEntity(in: world, frustum: frustum, isActive: false)
        
        // Entity inside frustum
        _ = createBoundedEntity(
            in: world,
            name: "Entity",
            position: Vector3(0, 0, -10)
        )
        
        await world.runScheduler(.preUpdate)

        let visibleEntities = camera.components[VisibleEntities.self]!
        #expect(visibleEntities.entities.isEmpty)
        #expect(visibleEntities.entityIds.isEmpty)
    }
    
    @Test("Multiple entities with mixed visibility")
    func multipleEntitiesWithMixedVisibility() async {
        let frustum = createTestFrustum()
        let camera = createCameraEntity(in: world, frustum: frustum)
        
        // Entity 1: Inside frustum, visible
        let entity1 = createBoundedEntity(
            in: world,
            name: "Visible Inside",
            position: Vector3(0, 0, -10)
        )
        
        // Entity 2: Inside frustum, hidden
        let entity2 = createBoundedEntity(
            in: world,
            name: "Hidden Inside",
            position: Vector3(1, 1, -15),
            visibility: .hidden
        )
        
        // Entity 3: Outside frustum, visible
        let entity3 = createBoundedEntity(
            in: world,
            name: "Visible Outside",
            position: Vector3(100, 0, -10)
        )
        
        // Entity 4: Inside frustum, visible
        let entity4 = createBoundedEntity(
            in: world,
            name: "Another Visible",
            position: Vector3(-2, 2, -50)
        )
        
        await world.runScheduler(.preUpdate)

        let visibleEntities = camera.components[VisibleEntities.self]!
        
        // Entity 1 and 4 should be visible
        #expect(visibleEntities.entityIds.contains(entity1.id))
        #expect(visibleEntities.entityIds.contains(entity4.id))
        
        // Entity 2 (hidden) and 3 (outside) should not be visible
        #expect(!visibleEntities.entityIds.contains(entity2.id))
        #expect(!visibleEntities.entityIds.contains(entity3.id))
        
        #expect(visibleEntities.entities.count == 2)
    }

    @Test("A lot of entities with mixed visibility")
    func aLotOfEntitiesWithMixedVisibility() async {
        let frustum = createTestFrustum()
        let camera = createCameraEntity(in: world, frustum: frustum)

        var expectedVisibleEntities: [Entity.ID] = []
        for _ in 0..<10 {
            for indexX in -6..<6 {
                for indexY in -6..<6 {
                    let isVisible = abs(indexX) < 6 && abs(indexY) < 6
                    let entity = createBoundedEntity(
                        in: world,
                        name: "Visible Inside",
                        position: Vector3(Float(indexX), Float(indexY), -10)
                    )

                    if isVisible {
                        expectedVisibleEntities.append(entity.id)
                    }
                }
            }
        }

        await world.runScheduler(.preUpdate)

        let visibleEntities = camera.components[VisibleEntities.self]!
        #expect(visibleEntities.entityIds.count == expectedVisibleEntities.count)
    }

    @Test("Entity at frustum boundary should be visible (intersecting)")
    func entityAtBoundaryIsVisible() async {
        let frustum = createTestFrustum()
        let camera = createCameraEntity(in: world, frustum: frustum)
        
        // Entity at edge of frustum - large enough to intersect
        let entity = createBoundedEntity(
            in: world,
            name: "Boundary Entity",
            position: Vector3(4.5, 0, -10),
            halfExtents: Vector3(1, 1, 1) // Will extend from 3.5 to 5.5, intersecting boundary at 5
        )
        
        await world.runScheduler(.preUpdate)

        let visibleEntities = camera.components[VisibleEntities.self]!
        #expect(visibleEntities.entityIds.contains(entity.id))
    }
    
    @Test("Large entity partially inside frustum should be visible")
    func largeEntityPartiallyInsideIsVisible() async {
        let frustum = createTestFrustum()
        let camera = createCameraEntity(in: world, frustum: frustum)
        
        // Large entity centered outside but extending into frustum
        let entity = createBoundedEntity(
            in: world,
            name: "Large Entity",
            position: Vector3(8, 0, -10),
            halfExtents: Vector3(5, 5, 5) // Extends from 3 to 13, intersecting frustum
        )
        
        await world.runScheduler(.preUpdate)

        let visibleEntities = camera.components[VisibleEntities.self]!
        #expect(visibleEntities.entityIds.contains(entity.id))
    }
    
    @Test("Entity exactly at near plane should be visible")
    func entityAtNearPlaneIsVisible() async {
        let frustum = createTestFrustum()
        let camera = createCameraEntity(in: world, frustum: frustum)
        
        // Entity at near plane
        let entity = createBoundedEntity(
            in: world,
            name: "Near Plane Entity",
            position: Vector3(0, 0, -2),
            halfExtents: Vector3(0.5, 0.5, 1.5) // Extends into valid zone
        )
        
        await world.runScheduler(.preUpdate)

        let visibleEntities = camera.components[VisibleEntities.self]!
        #expect(visibleEntities.entityIds.contains(entity.id))
    }
    
    @Test("Entity exactly at far plane should be visible")
    func entityAtFarPlaneIsVisible() async {
        let frustum = createTestFrustum()
        let camera = createCameraEntity(in: world, frustum: frustum)
        
        // Entity at far plane boundary
        let entity = createBoundedEntity(
            in: world,
            name: "Far Plane Entity",
            position: Vector3(0, 0, -99),
            halfExtents: Vector3(0.5, 0.5, 0.5)
        )
        
        await world.runScheduler(.preUpdate)

        let visibleEntities = camera.components[VisibleEntities.self]!
        #expect(visibleEntities.entityIds.contains(entity.id))
    }
    
    @Test("Multiple cameras see different entities")
    func multipleCamerasSeeDifferentEntities() async {
        // Camera 1: Looking at negative Z
        let frustum1 = createTestFrustum()
        let camera1 = createCameraEntity(in: world, frustum: frustum1)
        
        // Camera 2: Looking at positive Z (reversed frustum)
        var frustum2 = Frustum()
        frustum2.planes[0] = Plane(normal: Vector3(1, 0, 0), d: 5)
        frustum2.planes[1] = Plane(normal: Vector3(-1, 0, 0), d: 5)
        frustum2.planes[2] = Plane(normal: Vector3(0, -1, 0), d: 5)
        frustum2.planes[3] = Plane(normal: Vector3(0, 1, 0), d: 5)
        frustum2.planes[4] = Plane(normal: Vector3(0, 0, 1), d: -1)   // Near at z = 1, normal points into frustum (+Z)
        frustum2.planes[5] = Plane(normal: Vector3(0, 0, -1), d: 100) // Far at z = 100, normal points into frustum (-Z)
        let camera2 = createCameraEntity(in: world, frustum: frustum2)
        
        // Entity visible only by camera 1
        let entity1 = createBoundedEntity(
            in: world,
            name: "Entity for Camera 1",
            position: Vector3(0, 0, -10)
        )
        
        // Entity visible only by camera 2
        let entity2 = createBoundedEntity(
            in: world,
            name: "Entity for Camera 2",
            position: Vector3(0, 0, 10)
        )
        
        await world.runScheduler(.preUpdate)

        let visibleEntities1 = camera1.components[VisibleEntities.self]!
        let visibleEntities2 = camera2.components[VisibleEntities.self]!
        
        #expect(visibleEntities1.entityIds.contains(entity1.id))
        #expect(!visibleEntities1.entityIds.contains(entity2.id))
        
        #expect(!visibleEntities2.entityIds.contains(entity1.id))
        #expect(visibleEntities2.entityIds.contains(entity2.id))
    }
    
    @Test("Empty world with camera produces empty visible entities")
    func emptyWorldProducesEmptyVisibleEntities() async {
        let frustum = createTestFrustum()
        let camera = createCameraEntity(in: world, frustum: frustum)
        
        await world.runScheduler(.preUpdate)

        let visibleEntities = camera.components[VisibleEntities.self]!
        #expect(visibleEntities.entities.isEmpty)
        #expect(visibleEntities.entityIds.isEmpty)
    }
    
    @Test("Entity with zero-size bounding box at origin inside frustum is visible")
    func zeroSizeBoundingBoxInsideFrustumIsVisible() async {
        let frustum = createTestFrustum()
        let camera = createCameraEntity(in: world, frustum: frustum)
        
        // Point-like entity inside frustum
        let entity = createBoundedEntity(
            in: world,
            name: "Point Entity",
            position: Vector3(0, 0, -10),
            halfExtents: Vector3.zero
        )
        
        await world.runScheduler(.preUpdate)

        let visibleEntities = camera.components[VisibleEntities.self]!
        #expect(visibleEntities.entityIds.contains(entity.id))
    }
    
    @Test("Visible entities are updated on each system run")
    func visibleEntitiesAreUpdatedOnEachRun() async {
        let frustum = createTestFrustum()
        let camera = createCameraEntity(in: world, frustum: frustum)
        
        // Initially one entity
        let entity1 = createBoundedEntity(
            in: world,
            name: "Entity 1",
            position: Vector3(0, 0, -10)
        )
        
        await world.runScheduler(.preUpdate)

        var visibleEntities = camera.components[VisibleEntities.self]!
        #expect(visibleEntities.entities.count == 1)
        #expect(visibleEntities.entityIds.contains(entity1.id))
        
        // Add another entity
        let entity2 = createBoundedEntity(
            in: world,
            name: "Entity 2",
            position: Vector3(1, 1, -20)
        )
        
        await world.runScheduler(.preUpdate)

        visibleEntities = camera.components[VisibleEntities.self]!
        #expect(visibleEntities.entities.count == 2)
        #expect(visibleEntities.entityIds.contains(entity1.id))
        #expect(visibleEntities.entityIds.contains(entity2.id))
        
        // Remove first entity
        world.removeEntity(entity1)
        
        await world.runScheduler(.preUpdate)

        visibleEntities = camera.components[VisibleEntities.self]!
        #expect(visibleEntities.entities.count == 1)
        #expect(!visibleEntities.entityIds.contains(entity1.id))
        #expect(visibleEntities.entityIds.contains(entity2.id))
    }
}
