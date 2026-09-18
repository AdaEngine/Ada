//
//  KeyframeAnimationPlugin.swift
//  AdaScene
//

import AdaAnimation
import AdaApp
import AdaECS

/// Registers keyframe animation systems and a default ``AnimationClock`` resource.
public struct KeyframeAnimationPlugin: Plugin, Sendable {
    public init() {}

    public func setup(in app: AppWorlds) {
        app.main.insertResource(AnimationClock())
        app
            .addSystem(SyncAnimationClockSystem.self, on: .update)
            .addSystem(KeyframeAnimationApplySystem.self, on: .update)
    }
}
