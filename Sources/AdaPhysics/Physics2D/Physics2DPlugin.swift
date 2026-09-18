//
//  Physics2DPlugin.swift
//  AdaEngine
//
//  Created by v.prusakov on 8/11/22.
//

import AdaApp
import AdaCorePipelines
import AdaECS
import AdaRender
import AdaUtils
import Math

/// Setup 2D physics to the scene.
public struct Physics2DPlugin: Plugin {
    public let gravity: Vector2

    public init(gravity: Vector2 = [0, -9.81]) {
        self.gravity = gravity
    }

    public func setup(in app: AppWorlds) {
        let threading =
            app.getResource(PhysicsSimulationThreading.self)
            ?? {
                let resource = PhysicsSimulationThreading()
                app.insertResource(resource)
                return resource
            }()

        PhysicsBody2DComponent.registerComponent()
        PhysicsJoint2DComponent.registerComponent()
        Collision2DComponent.registerComponent()

        app
            .insertResource(
                Physics2DWorldHolder(
                    world: PhysicsWorld2D(
                        gravity: gravity,
                        workerCount: threading.box2DWorkerCount
                    )
                )
            )
            .insertResource(PhysicsDebugOptions())
            .addSystem(Physics2DSyncSystem.self, on: .physicsSync)
            .addSystem(Physics2DUpdateSystem.self, on: .physicsStep)
            .addSystem(Physics2DWritebackSystem.self, on: .physicsWriteback)
            .addSystem(PhysicsEventProxySystem.self, on: .startup)

        guard let renderWorld = app.getSubworldBuilder(by: .renderWorld) else {
            return
        }
        renderWorld
            .insertResource(ExtractedPhysicsDebugShapes())
            .insertResource(PhysicsDebugDrawData.defaultValue)
            .insertResource(PhysicsDebugBatches())
            .insertResource(PhysicsDebugLineDrawPass())
            .insertResource(PhysicsDebugCircleDrawPass())
            .insertResource(RenderPipelines(configurator: LinePipeline()))
            .insertResource(RenderPipelines(configurator: CirclePipeline()))
            .addSystem(ExtractPhysicsDebugSystem.self, on: .extract)
            .addSystem(PreparePhysicsDebugSystem.self, on: .prepare)
            .addSystem(PhysicsDebugRenderSystem.self, on: .update)
    }
}

/// Resource contains ``PhysicsWorld2D``.
public struct Physics2DWorldHolder: Resource {
    public let world: PhysicsWorld2D
}

extension World {
    /// Returns ``PhysicsWorld2D`` instance is ``Physics2DPlugin`` is connected to the scene.
    /// - Note: ``Physics2DPlugin`` connected by default on first update tick in current scene.
    @MainActor
    public var physicsWorld2D: PhysicsWorld2D? {
        return self.getResource(Physics2DWorldHolder.self)?.world
    }
}

@System
func PhysicsEventProxy(
    _ collisionBeganSender: EventsSender<CollisionEvents.Began>,
    _ collisionEndSender: EventsSender<CollisionEvents.Ended>,
    _ eventDisposeBag: Local<Set<AnyCancellable>> = .init([])
) {
    EventManager.default
        .subscribe(to: CollisionEvents.Began.self) { event in
            collisionBeganSender(event)
        }
        .store(in: &eventDisposeBag.wrappedValue)

    EventManager.default
        .subscribe(to: CollisionEvents.Ended.self) { event in
            collisionEndSender(event)
        }
        .store(in: &eventDisposeBag.wrappedValue)
}
