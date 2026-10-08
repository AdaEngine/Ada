//
//  PhysicsWorld2D.swift
//  AdaEngine
//
//  Created by v.prusakov on 7/6/22.
//

import AdaECS
import AdaUtils
import box2d
import Math

#if canImport(Dispatch)
    import Dispatch
#endif

/// A protocol that defines a delegate for the physics world.
public protocol PhysicsWorld2DDelegate: AnyObject, Sendable {
    /// Called when the physics world is about to solve a collision.
    ///
    /// - Parameters:
    ///   - world: The physics world.
    ///   - entityA: The first entity.
    ///   - entityB: The second entity.
    ///   - manifold: The manifold.
    /// - Returns: A Boolean value indicating whether the collision should be solved.
    func physicsWorldOnPreSolve(
        _ world: PhysicsWorld2D,
        entityA: Entity,
        entityB: Entity,
        manifold: Manifold2D?
    ) -> Bool

    /// Called when the physics world is about to filter a collision.
    ///
    /// - Parameters:
    ///   - world: The physics world.
    ///   - entityA: The first entity.
    ///   - entityB: The second entity.
    /// - Returns: A Boolean value indicating whether the collision should be filtered.
    func physicsWorldOnCustomFilterCalled(
        _ world: PhysicsWorld2D,
        entityA: Entity,
        entityB: Entity
    ) -> Bool
}

/// An object that holds and simulates all 2D physics bodies.
public final class PhysicsWorld2D: Codable, @unchecked Sendable {
    /// The coding keys for the physics world.
    enum CodingKeys: CodingKey {
        case substepIterations
        case gravity
    }

    /// The delegate of the physics world.
    public weak var delegate: PhysicsWorld2DDelegate?

    /// The substep iterations.
    public var substepIterations: Int = 4

    /// Contains world gravity.
    public var gravity: Vector2 {
        get {
            b2World_GetGravity(worldId).asVector2
        }
        set {
            b2World_SetGravity(worldId, newValue.b2Vec)
        }
    }

    /// Enable/disable continuous collision between dynamic and static bodies.
    /// Generally you should keep continuous collision enabled to prevent fast moving objects from
    /// going through static objects. The performance gain from disabling continuous collision is minor.
    public var isContinuousEnabled: Bool {
        get {
            b2World_IsContinuousEnabled(worldId)
        }
        set {
            b2World_EnableContinuous(worldId, newValue)
        }
    }

    /// Enable/disable constraint warm starting. Advanced feature for testing.
    /// Disabling sleeping greatly reduces stability and provides no performance gain.
    public var isWarmStartingEnabled: Bool {
        get {
            b2World_IsWarmStartingEnabled(worldId)
        }
        set {
            b2World_EnableWarmStarting(worldId, newValue)
        }
    }

    /// Enable/disable sleep. If your application does not need sleeping, you can gain
    /// some performance by disabling sleep completely at the world level.
    public var isSleepEnabled: Bool {
        get {
            b2World_IsSleepingEnabled(worldId)
        }
        set {
            b2World_EnableSleeping(worldId, newValue)
        }
    }

    /// Adjust the restitution threshold. It is recommended not to make this value very small
    /// because it will prevent bodies from sleeping. Usually in meters per second.
    public var restitutionThreshold: Float {
        get {
            b2World_GetRestitutionThreshold(worldId)
        }
        set {
            b2World_SetRestitutionThreshold(worldId, newValue)
        }
    }

    /// Adjust the hit event threshold. This controls the collision speed needed to generate a b2ContactHitEvent.
    /// Usually in meters per second.
    public var hitEventThreshold: Float {
        get {
            b2World_GetHitEventThreshold(worldId)
        }
        set {
            b2World_SetHitEventThreshold(worldId, newValue)
        }
    }
    private let worldId: b2WorldId
    var eventManager: EventManager = .default
    #if canImport(Dispatch)
        private let taskScheduler: Box2DTaskScheduler?
    #endif

    /// - Parameter gravity: default gravity is 9.8.
    nonisolated init(
        gravity: Vector2 = [0, -9.81],
        workerCount: Int = PhysicsSimulationThreading.recommendedWorkerCount
    ) {
        var worldDef = unsafe b2DefaultWorldDef()
        unsafe worldDef.gravity = gravity.b2Vec
        unsafe worldDef.enableSleep = true
        unsafe worldDef.enableContinuous = true
        #if canImport(Dispatch)
            let clampedWorkerCount = max(1, workerCount)
            let scheduler = clampedWorkerCount > 1 ? Box2DTaskScheduler(workerCount: clampedWorkerCount) : nil
            if let scheduler {
                unsafe worldDef.workerCount = Int32(clampedWorkerCount)
                unsafe worldDef.enqueueTask = PhysicsSimulationThreading_Box2DEnqueueTask
                unsafe worldDef.finishTask = PhysicsSimulationThreading_Box2DFinishTask
                unsafe worldDef.userTaskContext = Unmanaged.passUnretained(scheduler).toOpaque()
            }
            self.taskScheduler = scheduler
        #endif
        self.worldId = unsafe b2CreateWorld(&worldDef)
        b2World_EnableWarmStarting(worldId, true)

        let unsafeWorldPtr = unsafe Unmanaged.passUnretained(self).toOpaque()
        unsafe b2World_SetPreSolveCallback(worldId, PhysicsWorld2D_PreSolve, unsafeWorldPtr)
        unsafe b2World_SetCustomFilterCallback(worldId, PhysicsWorld2D_CustomFilterCallback, unsafeWorldPtr)
    }

    deinit {
        b2DestroyWorld(worldId)
    }

    nonisolated public convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let gravity = try container.decode(Vector2.self, forKey: .gravity)

        self.init(gravity: gravity)

        self.substepIterations = try container.decode(Int.self, forKey: .substepIterations)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.gravity, forKey: .gravity)
        try container.encode(self.substepIterations, forKey: .substepIterations)
    }

    // MARK: - Raycasting

    /// An array of collision cast hit results.
    /// Each hit indicates where the ray, starting at a given point and traveling in a given direction, hit a particular entity in the scene.
    public func raycast(
        from startPoint: Vector2,
        to endPoint: Vector2,
        query: CollisionCastQueryType = .all,
        mask: CollisionGroup = .all
    ) -> [Raycast2DHit] {
        switch query {
        case .first:
            var filter = b2DefaultQueryFilter()
            filter.maskBits = mask.rawValue

            let result = b2World_CastRayClosest(
                worldId,
                startPoint.b2Vec,
                (endPoint - startPoint).b2Vec,
                filter
            )

            let shape = BoxShape2D(shape: result.shapeId)
            guard let entity = shape.body?.entity else {
                return []
            }

            let distance = (startPoint - endPoint).squaredLength * result.fraction

            return [
                Raycast2DHit(
                    entity: entity,
                    point: result.point.asVector2,
                    normal: result.normal.asVector2,
                    distance: distance
                )
            ]
        case .all:
            return []
        }
    }

    /// An array of collision cast hit results.
    /// Each hit indicates where the ray, starting at a given point and traveling in a given direction, hit a particular entity in the world.
    public func raycast(
        from ray: Ray,
        query: CollisionCastQueryType = .all,
        mask: CollisionGroup = .all
    ) -> [Raycast2DHit] {
        return self.raycast(from: ray.origin.xy, to: ray.direction.xy, query: query, mask: mask)
    }

    // MARK: - Internal

    @MainActor
    func updateSimulation(_ delta: TimeInterval) {
        b2World_Step(
            worldId,
            Float(delta), /* timeStep */
            Int32(self.substepIterations) /* velocityIterations */
        )
    }

    func recordPerformance(into metrics: PhysicsPerformanceMetrics) {
        metrics.record(
            b2World_GetProfile(worldId),
            counters: b2World_GetCounters(worldId)
        )
    }

    /// Iterates the contiguous Box2D move-event stream produced by the latest simulation step.
    func forEachMovedBody(_ body: (Entity, Vector2, Quat) -> Void) {
        let events = unsafe b2World_GetBodyEvents(worldId)
        guard unsafe events.moveCount > 0, let moveEvents = unsafe events.moveEvents else {
            return
        }

        for index in unsafe 0..<Int(events.moveCount) {
            let event = unsafe moveEvents[index]
            guard let userData = unsafe event.userData else {
                continue
            }

            let runtimeBody = unsafe Unmanaged<Body2D>.fromOpaque(userData).takeUnretainedValue()
            guard let entity = runtimeBody.entity else {
                continue
            }

            let position = unsafe event.transform.p.asVector2
            let rotation = unsafe Quat(
                axis: [0, 0, 1],
                angle: -b2Rot_GetAngle(event.transform.q)
            )

            body(
                entity,
                position,
                rotation
            )
        }
    }

    func debugDraw(with definitions: b2DebugDraw) {
        var definitions = unsafe definitions
        unsafe b2World_Draw(worldId, &definitions)
    }

    @MainActor
    func processContacts() {
        let contactEvents = unsafe b2World_GetContactEvents(self.worldId)

        for index in unsafe 0..<contactEvents.beginCount {
            let contact = unsafe contactEvents.beginEvents[Int(index)]
            onBeginContact(contact)
        }

        for index in unsafe 0..<contactEvents.endCount {
            let contact = unsafe contactEvents.endEvents[Int(index)]
            onEndContact(contact)
        }

        for index in unsafe 0..<contactEvents.hitCount {
            let contact = unsafe contactEvents.hitEvents[Int(index)]
            onHitContact(contact)
        }
    }

    @MainActor
    func processSensors() {
        let sensorEvents = unsafe b2World_GetSensorEvents(self.worldId)

        for index in unsafe 0..<sensorEvents.beginCount {
            let contact = unsafe sensorEvents.beginEvents[Int(index)]
            onSensorBeginContact(contact)
        }

        for index in unsafe 0..<sensorEvents.endCount {
            let contact = unsafe sensorEvents.endEvents[Int(index)]
            onSensorEndContact(contact)
        }
    }

    nonisolated func destroyBody(_ body: Body2D) {
        b2DestroyBody(body.bodyId)
    }

    func createBody(with definition: b2BodyDef, for entity: Entity) -> Body2D {
        let body = unsafe withUnsafePointer(to: definition) {
            unsafe b2CreateBody(self.worldId, $0)
        }

        let body2d = Body2D(world: self, bodyId: body, entity: entity)
        let pointer = unsafe Unmanaged.passUnretained(body2d).toOpaque()
        unsafe b2Body_SetUserData(body, pointer)

        return body2d
    }
}

extension PhysicsWorld2D {
    @MainActor
    private func onSensorBeginContact(_ contact: b2SensorBeginTouchEvent) {
        let shapeIdA = BoxShape2D(shape: contact.sensorShapeId)
        let shapeIdB = BoxShape2D(shape: contact.visitorShapeId)
        let bodyA = shapeIdA.body
        let bodyB = shapeIdB.body

        guard let entityA = bodyA?.entity, let entityB = bodyB?.entity else {
            return
        }

        let event = CollisionEvents.Began(
            entityA: entityA,
            entityB: entityB,
            impulse: 0
        )

        self.eventManager.send(event)
    }

    @MainActor
    private func onSensorEndContact(_ contact: b2SensorEndTouchEvent) {
        let shapeIdA = BoxShape2D(shape: contact.sensorShapeId)
        let shapeIdB = BoxShape2D(shape: contact.visitorShapeId)

        guard shapeIdA.isValid && shapeIdB.isValid else {
            return
        }

        let bodyA = shapeIdA.body
        let bodyB = shapeIdB.body

        guard let entityA = bodyA?.entity, let entityB = bodyB?.entity else {
            return
        }

        let event = CollisionEvents.Ended(
            entityA: entityA,
            entityB: entityB
        )

        self.eventManager.send(event)
    }

    @MainActor
    private func onBeginContact(_ contact: b2ContactBeginTouchEvent) {
        let shapeIdA = BoxShape2D(shape: contact.shapeIdA)
        let shapeIdB = BoxShape2D(shape: contact.shapeIdB)
        let bodyA = shapeIdA.body
        let bodyB = shapeIdB.body

        guard let entityA = bodyA?.entity, let entityB = bodyB?.entity else {
            return
        }

        let event = CollisionEvents.Began(
            entityA: entityA,
            entityB: entityB,
            impulse: 0
        )

        self.eventManager.send(event)
    }

    @MainActor
    private func onEndContact(_ contact: b2ContactEndTouchEvent) {
        let shapeIdA = BoxShape2D(shape: contact.shapeIdA)
        let shapeIdB = BoxShape2D(shape: contact.shapeIdB)

        guard shapeIdA.isValid && shapeIdB.isValid else {
            return
        }

        let bodyA = shapeIdA.body
        let bodyB = shapeIdB.body

        guard let entityA = bodyA?.entity, let entityB = bodyB?.entity else {
            return
        }

        let event = CollisionEvents.Ended(
            entityA: entityA,
            entityB: entityB
        )

        self.eventManager.send(event)
    }

    private func onHitContact(_: b2ContactHitEvent) {
        // TODO: Not implemented
    }
}

private func PhysicsWorld2D_PreSolve(
    _ shapeA: b2ShapeId,
    _ shapeB: b2ShapeId,
    _ manifold: UnsafeMutablePointer<b2Manifold>?,
    _ context: UnsafeMutableRawPointer?
) -> Bool {
    guard let context = unsafe context else {
        return false
    }
    let world = unsafe Unmanaged<PhysicsWorld2D>.fromOpaque(context).takeUnretainedValue()
    let manifold = unsafe manifold.flatMap { ptr in
        unsafe Manifold2D(
            normal: ptr.pointee.normal.asVector2,
            rollingImpulse: ptr.pointee.rollingImpulse
        )
    }

    let shapeIdA = BoxShape2D(shape: shapeA)
    let shapeIdB = BoxShape2D(shape: shapeB)

    guard shapeIdA.isValid && shapeIdB.isValid else {
        return false
    }

    let bodyA = shapeIdA.body
    let bodyB = shapeIdB.body

    guard let entityA = bodyA?.entity, let entityB = bodyB?.entity else {
        return false
    }

    return world.delegate?
        .physicsWorldOnPreSolve(
            world,
            entityA: entityA,
            entityB: entityB,
            manifold: manifold
        ) ?? true
}

private func PhysicsWorld2D_CustomFilterCallback(
    _ shapeA: b2ShapeId,
    _ shapeB: b2ShapeId,
    _ context: UnsafeMutableRawPointer?
) -> Bool {
    guard let context = unsafe context else {
        return true
    }
    let world = unsafe Unmanaged<PhysicsWorld2D>.fromOpaque(context).takeUnretainedValue()
    let shapeIdA = BoxShape2D(shape: shapeA)
    let shapeIdB = BoxShape2D(shape: shapeB)

    guard shapeIdA.isValid && shapeIdB.isValid else {
        return true
    }

    let bodyA = shapeIdA.body
    let bodyB = shapeIdB.body

    guard let entityA = bodyA?.entity, let entityB = bodyB?.entity else {
        return true
    }

    return world.delegate?
        .physicsWorldOnCustomFilterCalled(
            world,
            entityA: entityA,
            entityB: entityB
        ) ?? true
}

// MARK: - Casting

extension Vector2 {
    var b2Vec: b2Vec2 {
        get {
            return unsafe unsafeBitCast(self, to: b2Vec2.self)
        }

        set {
            self = unsafe unsafeBitCast(newValue, to: Vector2.self)
        }
    }
}

extension b2Vec2 {
    var asVector2: Vector2 {
        return unsafe unsafeBitCast(self, to: Vector2.self)
    }
}

extension PhysicsBodyMode {
    var b2Type: b2BodyType {
        switch self {
        case .static: return b2_staticBody
        case .dynamic: return b2_dynamicBody
        case .kinematic: return b2_kinematicBody
        }
    }

    init(b2BodyType: b2BodyType) {
        switch b2BodyType {
        case b2_staticBody: self = .static
        case b2_dynamicBody: self = .dynamic
        case b2_kinematicBody: self = .kinematic
        default:
            self = .static
        }
    }
}

// MARK: - b2RaycastCallback

/// A hit result of a collision cast.
public struct Raycast2DHit {
    /// The entity that was hit.
    public let entity: Entity

    /// The point of the hit.
    public let point: Vector2

    /// The normal of the hit.
    public let normal: Vector2

    /// The distance from the ray origin to the hit, or the convex shape travel distance.
    public let distance: Float
}

private final class _Raycast2DCallback {
    var results: [Raycast2DHit] = []

    let startPoint: Vector2
    let endPoint: Vector2
    let query: CollisionCastQueryType
    let mask: CollisionGroup

    enum RaycastReporting {
        static let `continue`: Float = 1.0
        static let terminate: Float = 0.0
    }

    init(startPoint: Vector2, endPoint: Vector2, query: CollisionCastQueryType, mask: CollisionGroup) {
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.query = query
        self.mask = mask
    }

    //    func reportFixture(_ fixture: b2Fixture, point: b2Vec2, normal: b2Vec2, fraction: Float) -> Float {
    //        let fixtureBody = fixture.GetBody()!
    //        let userData = fixtureBody.GetUserData().pointee
    //
    //        let filterData = fixture.GetFilterData().pointee
    //
    //        if !(filterData.maskBits == self.mask.rawValue) {
    //            return RaycastReporting.continue
    //        }
    //
    //        let pointer = UnsafeRawPointer(OpaquePointer(bitPattern: userData.pointer)!)
    //        let body = Unmanaged<Body2D>.fromOpaque(pointer).takeUnretainedValue()
    //
    //        guard let entity = body.entity else {
    //            return RaycastReporting.continue
    //        }
    //
    //        // FIXME: Check distance
    //        let distance = (self.startPoint - self.endPoint).squaredLength * fraction
    //
    //        let result = Raycast2DHit(
    //            entity: entity,
    //            point: point.asVector2,
    //            normal: normal.asVector2,
    //            distance: distance
    //        )
    //
    //        self.results.append(result)
    //
    //        if query == .first {
    //            return RaycastReporting.terminate
    //        } else {
    //            return RaycastReporting.continue
    //        }
    //    }
}

//
// func testScene() {
//    var worldDef = b2DefaultWorldDef()
//    let world = b2CreateWorld(&worldDef)
//
//    var groundDef = b2DefaultBodyDef()
//    groundDef.position = b2Vec2(x: 0, y: -10)
//    let groundId = b2CreateBody(world, &groundDef)
//
//    var groundBox = b2MakeBox(50, 10)
//
//    var groundShapeDef = b2DefaultShapeDef()
//    b2CreatePolygonShape(groundId, &groundShapeDef, &groundBox);
//
//    var dynamicDef = b2DefaultBodyDef()
//    dynamicDef.position = b2Vec2(x: 0, y: 4)
//    dynamicDef.type = b2_dynamicBody
//    dynamicDef.fixedRotation = true
//    let dynamicId = b2CreateBody(world, &dynamicDef)
//
//    var dynamicBox = b2MakeBox(1, 1)
//    var dynamicShapeDef = b2DefaultShapeDef()
//    dynamicShapeDef.density = 1
//    b2CreatePolygonShape(dynamicId, &dynamicShapeDef, &dynamicBox)
//
//    let timespamp: Float = 1.0 / 60.0
//
//    for _ in 0..<130 {
//        b2World_Step(world, timespamp, 4)
//        var dynamicPosition = b2Body_GetPosition(dynamicId)
//        print("Dynamic position: \(dynamicPosition.x) \(dynamicPosition.y)")
//    }
// }

/// A manifold of a collision.
public struct Manifold2D: Sendable {
    /// The normal of the manifold.
    public let normal: Vector2
    /// The rolling impulse of the manifold.
    public let rollingImpulse: Float
}
