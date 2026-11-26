//
//  VisibilityComponents.swift
//  AdaEngine
//
//  Created by v.prusakov on 2/10/23.
//

import AdaECS
import AdaUtils

/// Contains information about all visible entities on the camera.
@Component
public struct VisibleEntities: Sendable {
    /// Contains visible entities.
    public var entities: [Entity]

    /// Contains visible entity ids.
    public var entityIds: Set<Entity.ID>

    public init(entities: [Entity] = [], entityIds: Set<Entity.ID> = []) {
        self.entities = entities
        self.entityIds = entityIds
    }
}

/// Contains information about visibility of entity.
/// This component indicates that entity can be rendered on the screen.
/// - Note: By default visibility is always true.
@Component
public enum Visibility: Codable, Sendable, DefaultValue {
    case visible
    case hidden
    case inherited

    public static let defaultValue: Self = .visible

    package func isVisible(inHierarchyOf entity: Entity) -> Bool {
        guard self != .hidden, entity.isActive else {
            return false
        }
        var ancestor = entity.parent
        var slow = entity
        var advanceSlow = false
        while let parent = ancestor {
            guard parent !== slow, parent.isActive, parent.components[Self.self] != .hidden else {
                return false
            }
            ancestor = parent.parent
            // Malformed authored relationships can contain an indirect cycle.
            if advanceSlow, let next = slow.parent {
                slow = next
            }
            advanceSlow.toggle()
        }
        return true
    }
}

/// This components indicates that entity will not affected by frustum culling.
@Component
public struct NoFrustumCulling: Sendable {
    public init() {}
}
