//
//  EventsSender.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 16.12.2025.
//

import AdaUtils

/// Events Sender. Allows you to send events to the world.
/// Each event is stored in the world and can be received by the receiver and available for the next frame.
///
/// Example:
/// ```swift
/// @System
/// func EventSender(
///     _ sender: EventsSender<OnCollide>
/// ) {
///     sender.send(OnCollide(first: entityA, second: entityB))
/// }
/// ```
@propertyWrapper
public final class EventsSender<T: Event>: @unchecked Sendable {
    @usableFromInline
    var storage: Ref<EventsStorage<T>>?

    public var wrappedValue: EventsSender<T> {
        self
    }

    public init() {}

    /// Send a new event to the world.
    /// - Parameter event: The event to send.
    @inlinable
    public func send(_ event: T) {
        self.storage?.wrappedValue.append(event)
    }

    /// Send a new event to the world.
    /// - Parameter event: The event to send.
    @inlinable
    public func callAsFunction(_ event: T) {
        self.storage?.wrappedValue.append(event)
    }

    /// Send a list of events to the world.
    /// - Parameter event: The events to send.
    @inlinable
    public func send(_ events: [T]) {
        self.storage?.wrappedValue.append(events)
    }

    /// Send a list of events to the world.
    /// - Parameter event: The events to send.
    @inlinable
    public func callAsFunction(_ events: [T]) {
        self.storage?.wrappedValue.append(events)
    }
}

extension EventsSender: SystemParameter {
    public static var access: SystemAccessSet {
        var access = SystemAccessSet()
        access.addResourceWrite(EventsStorage<T>.self)
        return access
    }

    public convenience init(from _: World) {
        self.init()
    }

    public func update(from world: World) {
        world.registerEventIfNeeded(T.self)
        self.storage = world.getRefResource(EventsStorage<T>.self)
    }
}
