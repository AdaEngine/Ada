//
//  World+Events.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 16.12.2025.
//

import AdaUtils

extension World {
    /// Whether the event lifecycle resource has been installed (normally by EventsPlugin).
    public var supportsEventDelivery: Bool {
        getResource(HandledEvents.self) != nil
    }

    /// Register new event if it is not registered yet.
    /// - Parameter type: The type of the event to register.
    /// - Note: This method is called automatically when you use `Events` or `EventsSender` property wrappers.
    public func registerEventIfNeeded<T: Event>(_: T.Type) {
        guard self.getResource(EventsStorage<T>.self) == nil else {
            return
        }

        self.insertResource(EventsStorage<T>())

        guard let componentId = self.resources.getResourceId(for: EventsStorage<T>.self) else {
            return
        }

        unsafe self.getRefResource(HandledEvents.self)
            .wrappedValue
            .handledEvents
            .append(
                .init(
                    resourceId: componentId,
                    update: { pointer in
                        unsafe pointer
                            .assumingMemoryBound(to: EventsStorage<T>.self)
                            .pointee
                            .swapAndDropOld()
                    }
                )
            )
    }
}

/// Storage for events.
/// Each event is stored in the world and can be received by the receiver and available for the next frame.
public struct EventsStorage<T: Event>: Resource {
    @LocalIsolated
    /// Current events.
    private(set) var currentEvents: ContiguousArray<T>

    /// Old events.
    private(set) var oldEvents: ContiguousArray<T>

    public init() {
        self.currentEvents = []
        self.oldEvents = []
    }

    /// Append a new event to the current events.
    /// - Parameter event: The event to append.
    public mutating func append(_ event: T) {
        self.currentEvents.append(event)
    }

    /// Append a new event to the current events.
    /// - Parameter event: The event to append.
    public mutating func append(_ events: [T]) {
        self.currentEvents.append(contentsOf: events)
    }

    /// Swap and drop old events.
    public mutating func swapAndDropOld() {
        swap(&oldEvents, &currentEvents)
        currentEvents.removeAll(keepingCapacity: true)
    }
}

/// Storage for handled events.
/// Handled events are events that have been processed by the system.
package struct HandledEvents: Resource {
    @safe
    package struct Handle: @unchecked Sendable {
        let resourceId: ComponentId
        let update: (UnsafeMutableRawPointer) -> Void
    }

    var handledEvents: [Handle] = []

    package init(handledEvents: [Handle] = []) {
        self.handledEvents = handledEvents
    }
}

/// System that updates the events.
/// This system is responsible for swapping and dropping old events and updating the handled events.
@PlainSystem
public struct EventsUpdateSystem {
    @Res<HandledEvents>
    private var handledEvents

    public init(world _: World) {}

    public func update(context: UpdateContext) async {
        for handle in handledEvents.handledEvents {
            guard let pointer = unsafe context.world.resources.getPointer(for: handle.resourceId) else {
                continue
            }
            unsafe handle.update(pointer)
        }
    }
}
