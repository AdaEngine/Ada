//
//  BillboardComponent.swift
//  AdaEngine
//

import AdaECS
import AdaRender
import AdaTransform
import Math

/// Makes an entity rotate so its local forward axis faces the active camera.
@Component
public struct BillboardComponent: Codable, Hashable, Sendable {
    /// Axes on which the billboard is allowed to rotate.
    public enum RotationMode: String, Codable, Hashable, Sendable {
        /// Rotate freely toward the camera.
        case all

        /// Rotate only around the world up axis.
        case yAxis
    }

    public var rotationMode: RotationMode
    public var isEnabled: Bool

    public init(rotationMode: RotationMode = .all, isEnabled: Bool = true) {
        self.rotationMode = rotationMode
        self.isEnabled = isEnabled
    }
}

/// Updates billboard rotations before global transforms are propagated.
@PlainSystem
public struct BillboardSystem: Sendable {
    @Query<Camera, GlobalTransform>
    private var cameras

    @Query<Entity, BillboardComponent, Ref<Transform>, GlobalTransform>
    private var billboards

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        var activeCameraTransform: GlobalTransform?
        cameras.forEach { camera, transform in
            guard activeCameraTransform == nil, camera.isActive else {
                return
            }
            activeCameraTransform = transform
        }
        guard let cameraTransform = activeCameraTransform else {
            return
        }

        let cameraPosition = cameraTransform.matrix.origin
        billboards.forEach { entity, billboard, transform, globalTransform in
            guard billboard.isEnabled else {
                return
            }

            let position = globalTransform.matrix.origin
            var target = cameraPosition
            if billboard.rotationMode == .yAxis {
                target.y = position.y
            }
            guard target != position else {
                return
            }

            let globalRotation = Transform3D.lookAt(eye: position, center: target).rotation
            if let parentTransform = entity.parent?.components[GlobalTransform.self] {
                let desiredGlobalTransform = Transform3D(
                    translation: position,
                    rotation: globalRotation,
                    scale: globalTransform.matrix.scale
                )
                transform.rotation = (parentTransform.matrix.inverse * desiredGlobalTransform).rotation
            } else {
                transform.rotation = globalRotation
            }
        }
    }
}
