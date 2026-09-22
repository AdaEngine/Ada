//
//  MainScheduler.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 01.06.2025.
//

import AdaECS
import AdaUtils

/// The plugin that sets up the main scheduler.
package struct MainSchedulerPlugin: Plugin {
    package init() {}

    /// Setup the main scheduler.
    /// - Parameter app: The app to setup the main scheduler for.
    package func setup(in app: AppWorlds) {
        let mainScheduler = Scheduler(name: .main)
        app.updateScheduler = .main

        app.main.addScheduler(mainScheduler)
        app.main.addSchedulers(
            // Special
            .startup,
            .fixed,

            // Update
            .networkReceive,
            .preUpdate,
            .update,
            .networkSend,
            .networkInterpolate,
            .postUpdate,

            // Fixed
            .fixedPreUpdate,
            .physicsSync,
            .physicsStep,
            .physicsWriteback,
            .fixedUpdate,
            .fixedPostUpdate
        )

        app
            .addSystem(DefaultSchedulerRunner.self, on: .main)
            .addSystem(FixedTimeSchedulerSystem.self, on: .fixed)
        app.insertResource(
            DefaultSchedulerOrder(
                order: [
                    .networkReceive,
                    .preUpdate,
                    .update,
                    // Apply fixed-step writes before post-update systems derive
                    // render state such as GlobalTransform.
                    .fixed,
                    .networkSend,
                    .networkInterpolate,
                    .postUpdate,
                ]
            )
        )
        app.addSystem(GameLoopBeganSystem.self, on: .preUpdate)
    }
}

extension SchedulerName {
    static let main: SchedulerName = "Main"
    static let fixed: SchedulerName = "FixedMain"
}

// FIXME: Hack to works with AnimatedTexture
@System
@inline(__always)
func GameLoopBegan(
    _ deltaTime: Res<DeltaTime?>
) {
    guard let deltaTime = deltaTime.wrappedValue else {
        return
    }
    EventManager.default.send(EngineEvents.MainLoopBegan(deltaTime: deltaTime.deltaTime))
}

/// The system that runs the fixed time scheduler.
@PlainSystem
public struct FixedTimeSchedulerSystem {
    @Local
    private var fixedTimestep: FixedTimestep

    let order: [SchedulerName] = [
        .fixedPreUpdate,
        .physicsSync,
        .physicsStep,
        .physicsWriteback,
        .fixedUpdate,
        .fixedPostUpdate,
    ]

    public init(world _: World) {
        self.fixedTimestep = FixedTimestep(stepsPerSecond: 60)
    }

    @Res<DeltaTime>
    private var time

    public func update(context: UpdateContext) async {
        let deltaTime = time.deltaTime
        let result = self.fixedTimestep.advance(with: deltaTime)

        if result.isFixedTick {
            let step = self.fixedTimestep.step
            let world = context.world
            world.insertResource(FixedTime(deltaTime: step))
            for scheduler in order {
                await world.runScheduler(scheduler)
            }
        }
    }
}

extension SchedulerName {
    /// Receives and applies network data before gameplay systems run.
    public static let networkReceive = SchedulerName(rawValue: "networkReceive")

    /// Captures authoritative state after fixed simulation and sends network data.
    public static let networkSend = SchedulerName(rawValue: "networkSend")

    /// Applies client presentation interpolation before transform propagation.
    public static let networkInterpolate = SchedulerName(rawValue: "networkInterpolate")

    /// The scheduler that synchronizes ECS state into physics backends.
    public static let physicsSync = SchedulerName(rawValue: "physicsSync")

    /// The scheduler that advances physics backends.
    public static let physicsStep = SchedulerName(rawValue: "physicsStep")

    /// The scheduler that writes physics results back into ECS state.
    public static let physicsWriteback = SchedulerName(rawValue: "physicsWriteback")

    /// The fixed pre-update scheduler.
    public static let fixedPreUpdate = SchedulerName(rawValue: "fixedPreUpdate")

    /// The fixed update scheduler.
    public static let fixedUpdate = SchedulerName(rawValue: "fixedUpdate")

    /// The fixed post-update scheduler.
    public static let fixedPostUpdate = SchedulerName(rawValue: "fixedPostUpdate")
}
