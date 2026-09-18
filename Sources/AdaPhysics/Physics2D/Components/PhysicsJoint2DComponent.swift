//
//  PhysicsJoint2DComponent.swift
//  AdaEngine
//
//  Created by v.prusakov on 7/18/22.
//

import AdaECS
import AdaUtils
import Math

public final class PhysicsJoint2DDescriptor: Codable, Sendable {
    let joint: Joint

    enum Joint: Codable, Sendable {
        case rope(Entity.ID, Entity.ID, Vector2, Vector2)
        case revolute(Entity.ID)
    }

    internal init(joint: Joint) {
        self.joint = joint
    }

    @MainActor
    public static func rope(entityA: Entity, entityB: Entity) -> PhysicsJoint2DDescriptor {
        return PhysicsJoint2DDescriptor(joint: .rope(entityA.id, entityB.id, .zero, .zero))
    }

    @MainActor
    public static func revolute(entityA: Entity) -> PhysicsJoint2DDescriptor {
        return PhysicsJoint2DDescriptor(joint: .revolute(entityA.id))
    }
}

@Component
public struct PhysicsJoint2DComponent: @unchecked Sendable {
    let jointDescriptor: PhysicsJoint2DDescriptor

    var runtimeJoint: UnsafeAnyBox?

    public init(joint: PhysicsJoint2DDescriptor) {
        self.jointDescriptor = joint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.jointDescriptor = try container.decode(PhysicsJoint2DDescriptor.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.jointDescriptor)
    }
}
