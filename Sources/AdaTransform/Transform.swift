//
//  Transform.swift
//  AdaEngine
//
//  Created by v.prusakov on 11/1/21.
//

import AdaECS
import AdaUtils
import Math

/// A component that defines the scale, rotation, and translation of an entity.
@Component(required: [GlobalTransform.self])
public struct Transform: Codable, Hashable, Sendable {
    /// The rotation of the entity specified as a unit quaternion.
    public var rotation: Quat

    /// The scaling factor applied to the entity.
    public var scale: Vector3

    /// The position of the entity along the x, y, and z axes.
    public var position: Vector3

    /// Create a new transform component from rotation, scale and position.
    public init(
        rotation: Quat = .identity,
        scale: Vector3 = [1, 1, 1],
        position: Vector3 = .zero
    ) {
        self.rotation = rotation
        self.scale = scale
        self.position = position
    }

    /// Create a new transform component from transformation matrix.
    public init(matrix: Transform3D) {
        self.rotation = matrix.rotation
        self.scale = matrix.scale
        self.position = matrix.origin
    }
}

extension Transform {
    /// Return matrix
    public var matrix: Transform3D {
        Transform3D(
            translation: self.position,
            rotation: self.rotation,
            scale: self.scale
        )
    }
}

/// A component that describe global transform of an entity
///
/// - Note: To update position, scale or rotation of an entity, use ``Transform`` component.
@Component
public struct GlobalTransform: Hashable, Sendable, Codable {
    public internal(set) var matrix: Transform3D
}

extension GlobalTransform: DefaultValue {
    public static let defaultValue: GlobalTransform = GlobalTransform(matrix: .identity)
}

extension GlobalTransform {
    public func getTransform() -> Transform {
        Transform(
            rotation: self.matrix.rotation,
            scale: self.matrix.scale,
            position: self.matrix.origin
        )
    }
}
