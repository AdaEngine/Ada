//
//  CollisionEvents.swift
//  AdaEngine
//
//  Created by v.prusakov on 7/11/22.
//

import AdaECS
import AdaUtils

/// Events associated with collisions.
public enum CollisionEvents {
    /// An event raised when two objects collide.
    public struct Began: Event {
        /// The first entity involved in the collision.
        public let entityA: Entity

        /// The second entity involved in the collision.
        public let entityB: Entity

        /// The estimated strength of the impact.
        public let impulse: Float
    }

    /// An event raised when two objects, previously in contact, separate.
    public struct Ended: Event {
        /// The first entity involved in the collision.
        public let entityA: Entity

        /// The second entity involved in the collision.
        public let entityB: Entity
    }
}
