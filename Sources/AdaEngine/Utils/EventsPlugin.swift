//
//  EventsPlugin.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 16.12.2025.
//

import AdaApp
import AdaECS

/// Plugin that adds events to the world.
/// This plugin is responsible for handling the events and updating the handled events.
///
/// - Note: This plugin is automatically added by the `DefaultPlugins` plugin.
public struct EventsPlugin: Plugin {
    public init() {}

    public func setup(in app: borrowing AppWorlds) {
        guard !app.main.supportsEventDelivery else {
            return
        }
        app.insertResource(HandledEvents())
        app.addSystem(EventsUpdateSystem.self, on: .preUpdate)
    }
}
