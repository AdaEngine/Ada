//
//  Events.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 16.12.2025.
//

import AdaUtils

/// Events Receiver. Allows you to receive events from the world.
/// Events object returns an array of events from previous frame.
///
/// Example:
/// ```swift
/// @System
/// func EventReceiver(
///     _ events: Events<OnCollide>
/// ) {
///     for event in events {
///         print("Received event: \(event)")
///     }
/// }
/// ```
@propertyWrapper
public final class Events<T: Event>: @unchecked Sendable {
    private var storage: Ref<EventsStorage<T>>?

    public var wrappedValue: ContiguousArray<T> {
        _read {
            yield self.storage?.wrappedValue.oldEvents ?? []
        }
    }

    /// Returns array of current events
    public var currentEvents: ContiguousArray<T> {
        _read {
            yield self.storage?.wrappedValue.currentEvents ?? []
        }
    }

    public init() {}
}

extension Events: SystemParameter {
    public static var access: SystemAccessSet {
        var access = SystemAccessSet()
        access.addResourceRead(EventsStorage<T>.self)
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

extension Events: Sequence {
    public typealias Element = T
    public typealias Iterator = ContiguousArray<T>.Iterator

    public func makeIterator() -> ContiguousArray<T>.Iterator {
        let storage = self.storage?.wrappedValue.oldEvents ?? []
        return storage.makeIterator()
    }

    /// Check if the events are empty.
    public var isEmpty: Bool {
        guard let events = self.storage?.wrappedValue.oldEvents else {
            return true
        }
        return events.isEmpty
    }

    /// Get the number of events.
    public var count: Int {
        guard let events = self.storage?.wrappedValue.oldEvents else {
            return 0
        }
        return events.count
    }
}
