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
}

/// This components indicates that entity will not affected by frustum culling.
@Component
public struct NoFrustumCulling: Sendable {
    public init() {}
}
