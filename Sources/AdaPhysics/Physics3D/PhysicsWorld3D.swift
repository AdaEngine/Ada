//
//  PhysicsWorld3D.swift
//  AdaEngine
//
//  Created by Codex on 7/6/26.
//

import AdaECS
import box3d
import Foundation
import Math

/// Box3D-backed 3D physics world.
public final class PhysicsWorld3D: Codable, @unchecked Sendable {
    private let worldId: b3WorldId

    private var configuredSubStepCount: Int32

    /// Number of workers used by the Box3D scheduler.
    public var workerCount: Int {
        Int(b3World_GetWorkerCount(worldId))
    }

    /// Number of solver substeps performed for each fixed physics tick.
    public var subStepCount: Int32 {
        get { configuredSubStepCount }
        set { configuredSubStepCount = max(1, newValue) }
    }

    public var gravity: Vector3 {
        get {
            b3World_GetGravity(worldId).asVector3
        }

        set {
            b3World_SetGravity(worldId, newValue.b3Vec)
        }
    }

    public var isSleepingEnabled: Bool {
        get {
            b3World_IsSleepingEnabled(worldId)
        }

        set {
            b3World_EnableSleeping(worldId, newValue)
        }
    }

    public init(
        gravity: Vector3 = [0, -9.81, 0],
        workerCount: Int = PhysicsSimulationThreading.recommendedWorkerCount,
        subStepCount: Int32 = 2
    ) {
        var worldDef = b3DefaultWorldDef()
        worldDef.gravity = gravity.b3Vec
        worldDef.workerCount = UInt32(max(1, workerCount))
        self.worldId = b3CreateWorld(&worldDef)
        self.configuredSubStepCount = max(1, subStepCount)
        b3World_EnableWarmStarting(worldId, true)
    }

    deinit {
        b3DestroyWorld(worldId)
    }

    public convenience init(from _: Decoder) throws {
        self.init()
    }

    public func encode(to _: Encoder) throws {}

    public func updateSimulation(_ deltaTime: Float, subStepCount: Int32? = nil) {
        b3World_Step(worldId, deltaTime, max(1, subStepCount ?? configuredSubStepCount))
    }

    func recordPerformance(into metrics: PhysicsPerformanceMetrics) {
        metrics.record(
            b3World_GetProfile(worldId),
            counters: b3World_GetCounters(worldId)
        )
    }

    /// Iterates only bodies moved by the most recent simulation step.
    func forEachMovedBody(_ body: (Entity, Vector3, Quat) -> Void) {
        let events = b3World_GetBodyEvents(worldId)
        guard events.moveCount > 0, let moveEvents = events.moveEvents else {
            return
        }

        for index in 0..<Int(events.moveCount) {
            let event = moveEvents[index]
            guard let userData = event.userData else {
                continue
            }

            let runtimeBody = Unmanaged<Body3D>.fromOpaque(userData).takeUnretainedValue()
            guard let entity = runtimeBody.entity else {
                continue
            }

            body(
                entity,
                event.transform.p.asVector3,
                event.transform.q.asQuat
            )
        }
    }

    func createBody(with definition: b3BodyDef, for entity: Entity) -> Body3D {
        let body = withUnsafePointer(to: definition) {
            b3CreateBody(self.worldId, $0)
        }
        let bodyWrapper = Body3D(world: self, bodyId: body, entity: entity)
        let pointer = Unmanaged.passUnretained(bodyWrapper).toOpaque()
        b3Body_SetUserData(body, pointer)
        return bodyWrapper
    }
}

extension Vector3 {
    var b3Vec: b3Vec3 {
        b3Vec3(x: self.x, y: self.y, z: self.z)
    }
}

extension b3Vec3 {
    var asVector3: Vector3 {
        Vector3(x: self.x, y: self.y, z: self.z)
    }
}

extension Quat {
    var b3Quat: box3d.b3Quat {
        box3d.b3Quat(v: b3Vec3(x: self.x, y: self.y, z: self.z), s: self.w)
    }
}

extension b3Quat {
    var asQuat: Quat {
        Quat(x: self.v.x, y: self.v.y, z: self.v.z, w: self.s)
    }
}

extension PhysicsBodyMode {
    var b3Type: b3BodyType {
        switch self {
        case .static: return b3_staticBody
        case .dynamic: return b3_dynamicBody
        case .kinematic: return b3_kinematicBody
        }
    }

    init(b3BodyType: b3BodyType) {
        switch b3BodyType {
        case b3_staticBody: self = .static
        case b3_dynamicBody: self = .dynamic
        case b3_kinematicBody: self = .kinematic
        default: self = .static
        }
    }
}
