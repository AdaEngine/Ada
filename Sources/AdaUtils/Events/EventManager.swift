//
//  EventManager.swift
//  AdaEngine
//
//  Created by v.prusakov on 7/3/22.
//

/// A type that can be sent as an event.
public protocol Event: Sendable {}

/// An object on which events can be published and subscribed.
public final class EventManager: @unchecked Sendable {
    public static let `default`: EventManager = EventManager()

    public init() {}

    @LocalIsolated
    private var subscribers: [ObjectIdentifier: WeakSet<EventSubscriber>] = [:]

    public func subscribe<T: Event>(
        to _: T.Type,
        on source: EventSource? = nil,
        completion: @escaping @Sendable (T) -> Void
    ) -> Cancellable {
        let subscriber = EventSubscriber(source: source, completion: completion)

        let key = ObjectIdentifier(T.self)
        self.subscribers[key, default: []].insert(subscriber)

        return AnyCancellable(subscriber)
    }

    public func send<T: Event>(_ event: T) {
        let key = ObjectIdentifier(T.self)
        self.subscribers[key]?
            .forEach { subscriber in
                subscriber.completion?(event)
            }
    }

    public func send<T: Event>(_ event: T, source: EventSource) {
        let key = ObjectIdentifier(T.self)
        self.subscribers[key]?
            .forEach { subscriber in
                if let eventSource = subscriber.source, eventSource !== source {
                    return
                }

                subscriber.completion?(event)
            }
    }
}

/// An object that hold event subscriber.
private final class EventSubscriber: Cancellable, @unchecked Sendable {
    let source: EventSource?
    private(set) var completion: (@Sendable (any Sendable) -> Void)?

    init<T: Sendable>(source: EventSource?, completion: @escaping @Sendable (T) -> Void) {
        self.source = source
        self.completion = { value in
            completion(value as! T)
        }
    }

    func cancel() {
        self.completion = nil
    }
}

/// A type on which events can be published and subscribed.
public protocol EventSource: AnyObject, Sendable {
    func subscribe<E: Event>(
        to event: E.Type,
        on eventSource: EventSource?,
        completion: @escaping @Sendable (E) -> Void
    ) -> Cancellable
}

extension EventSource {
    public func subscribe<E: Event>(
        to event: E.Type,
        completion: @escaping @Sendable (E) -> Void
    ) -> Cancellable {
        return self.subscribe(to: event, on: self, completion: completion)
    }
}
