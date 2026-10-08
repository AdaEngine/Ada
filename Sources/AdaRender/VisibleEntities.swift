//
//  VisibleEntities.swift
//  AdaEngine
//
//  Created by v.prusakov on 2/6/23.
//

import AdaECS
import AdaTransform
import AdaUtils
import Math

// TODO: (Vlad) add sphere supports

/// System for detect wich entities is visible on camera.
/// All cameras has frustum and each entity should has ``BoundingComponent`` to be detected.
/// If entity doesn't has ``BoundingComponent`` than system tries to add it.
/// If entity has ``NoFrustumCulling`` than it will ignore frustum culling.
@PlainSystem(dependencies: [
    .after(CameraSystem.self)
])
public struct VisibilitySystem {
    @Query<Camera, Ref<VisibleEntities>>
    private var cameras

    @Query<Entity, Visibility, BoundingComponent, GlobalTransform>
    private var entities

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        self.cameras.forEach { camera, visibleEntities in
            if !camera.isActive {
                return
            }

            let frustum = camera.computedData.frustum
            var entityIds = Set<Entity.ID>()
            var entities: [Entity] = []
            self.entities.forEach { entity, visibility, bounding, globalTransform in
                if visibility == .hidden {
                    return
                }
                if entity.components.has(NoFrustumCulling.self) {
                    entityIds.insert(entity.id)
                    entities.append(entity)
                    return
                }
                switch bounding.bounds {
                case let .aabb(aabb):
                    if !frustum.intersectsAABB(aabb.transformed(by: globalTransform.matrix)) {
                        return
                    }
                    entityIds.insert(entity.id)
                    entities.append(entity)
                }
            }
            visibleEntities.entities = entities
            visibleEntities.entityIds = entityIds
        }
    }
}

extension AABB {
    func transformed(by transform: Transform3D) -> AABB {
        let min = self.min
        let max = self.max
        var transformedMin = (transform * Vector4(min, 1)).xyz
        var transformedMax = transformedMin

        for corner in [
            Vector3(min.x, min.y, max.z),
            Vector3(min.x, max.y, min.z),
            Vector3(min.x, max.y, max.z),
            Vector3(max.x, min.y, min.z),
            Vector3(max.x, min.y, max.z),
            Vector3(max.x, max.y, min.z),
            max,
        ] {
            let transformedCorner = (transform * Vector4(corner, 1)).xyz
            transformedMin = Vector3(
                Swift.min(transformedMin.x, transformedCorner.x),
                Swift.min(transformedMin.y, transformedCorner.y),
                Swift.min(transformedMin.z, transformedCorner.z)
            )
            transformedMax = Vector3(
                Swift.max(transformedMax.x, transformedCorner.x),
                Swift.max(transformedMax.y, transformedCorner.y),
                Swift.max(transformedMax.z, transformedCorner.z)
            )
        }

        return AABB(min: transformedMin, max: transformedMax)
    }
}
