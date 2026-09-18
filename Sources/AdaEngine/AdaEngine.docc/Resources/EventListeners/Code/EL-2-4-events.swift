/// Events the scene triggers.
public enum SceneEvents {

    /// An event triggered once when scene is ready to use and will starts update soon.
    public struct OnReady: Event {
        public let scene: Scene
    }

    /// Raised after an entity is added to the scene.
    public struct DidAddEntity: Event {
        public let entity: Entity
    }

    /// Raised before an entity is removed from the scene.
    public struct WillRemoveEntity: Event {
        public let entity: Entity
    }

    /// An event triggered once per frame interval that you can use to execute custom logic for each frame.
    public struct Update: Event {

        /// The updated scene.
        public let scene: Scene

        /// The elapsed time since the last update.
        public let deltaTime: TimeInterval
    }
}

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
