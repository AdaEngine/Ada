//
//  QueryFilter.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/21/25.
//

/// Filter for entity query.
public struct QueryFilter: OptionSet, Sendable {
    /// The raw value of the query filter.
    public typealias RawValue = UInt8

    /// The raw value of the query filter.
    public var rawValue: UInt8

    /// Initialize a new query filter.
    /// - Parameter rawValue: The raw value of the query filter.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Returns entities which added to world.
    public static let added = Self(rawValue: 1 << 0)

    /// Returns entities which stored in world.
    public static let stored = Self(rawValue: 1 << 1)

    /// Returns entities which wait removing from world.
    public static let removed = Self(rawValue: 1 << 2)

    /// Filter that include all values.
    public static let all: QueryFilter = [.added, .stored, .removed]
}

/// A protocol for filters.
public protocol Filter: Sendable, WorldQueryTarget {
    /// Check if the filter can match any row in the archetype.
    /// Archetype-only filters use this to avoid per-row work.
    @inlinable
    static func predicate(in archetype: borrowing Archetype) -> Bool

    /// True when the filter must be checked for each row in a matching archetype.
    @inlinable
    static var requiresRowEvaluation: Bool { get }

    /// Check if the filter is satisfied for an archetype.
    /// - Parameter archetype: The archetype to check.
    /// - Returns: True if the filter is satisfied for the archetype, otherwise false.
    @inlinable
    static func condition(
        state: State,
        fetch: Fetch,
        at row: Int
    ) -> Bool
}

extension Filter {
    @inlinable
    public static func predicate(in _: borrowing Archetype) -> Bool {
        true
    }

    @inlinable
    public static var requiresRowEvaluation: Bool {
        true
    }
}

/// A filter that includes entities with a specific component.
public struct With<T: Component>: Filter {
    public typealias State = Void
    public typealias Fetch = ComponentMaskSet

    @inlinable
    public static var requiresRowEvaluation: Bool {
        false
    }

    @inlinable
    public static func predicate(in archetype: borrowing Archetype) -> Bool {
        archetype.componentLayout.maskSet.contains(T.identifier)
    }

    @inlinable
    public static func _initState(world _: World) {}

    @inlinable
    public static func _initFetch(world _: World, state _: Void, lastTick _: Tick, currentTick _: Tick) -> ComponentMaskSet {
        ComponentMaskSet()
    }

    @inlinable
    public static func _setData(
        state _: Void,
        fetch _: ComponentMaskSet,
        chunk _: Chunk,
        archetype: Archetype
    ) -> ComponentMaskSet {
        archetype.componentLayout.maskSet
    }

    @inlinable
    @inline(__always)
    public static func condition(
        state _: State,
        fetch: ComponentMaskSet,
        at _: Int
    ) -> Bool {
        return fetch.contains(T.self)
    }
}

/// A filter that excludes entities with a specific component.
public struct Without<T: Component>: Filter {
    public typealias State = Void
    public typealias Fetch = ComponentMaskSet

    @inlinable
    public static var requiresRowEvaluation: Bool {
        false
    }

    @inlinable
    public static func predicate(in archetype: borrowing Archetype) -> Bool {
        !archetype.componentLayout.maskSet.contains(T.identifier)
    }

    @inlinable
    public static func _initState(world _: World) {}

    @inlinable
    public static func _initFetch(world _: World, state _: Void, lastTick _: Tick, currentTick _: Tick) -> ComponentMaskSet {
        ComponentMaskSet()
    }

    @inlinable
    public static func _setData(
        state _: Void,
        fetch _: ComponentMaskSet,
        chunk _: Chunk,
        archetype: Archetype
    ) -> ComponentMaskSet {
        archetype.componentLayout.maskSet
    }

    @inlinable
    @inline(__always)
    public static func condition(state _: Void, fetch: ComponentMaskSet, at _: Int) -> Bool {
        return !fetch.contains(T.self)
    }
}

/// A filter that combines two filters with a logical AND operation.
public struct And<each T: Filter>: Filter {
    public typealias State = _State
    public typealias Fetch = _Fetch

    public struct _State: Sendable {
        @usableFromInline
        var states: (repeat (each T).State)

        @usableFromInline
        init(states: (repeat (each T).State)) {
            self.states = states
        }
    }

    public static var access: SystemAccessSet {
        var access = SystemAccessSet()
        for filter in repeat (each T).self {
            access.formUnion(filter.access)
        }
        return access
    }

    public struct _Fetch {
        @usableFromInline
        var fetches: (repeat (each T).Fetch)

        @usableFromInline
        init(fetches: (repeat (each T).Fetch)) {
            self.fetches = fetches
        }
    }

    @inlinable
    public static var requiresRowEvaluation: Bool {
        for filter in repeat (each T).self {
            if filter.requiresRowEvaluation { // swiftlint:disable:this for_where
                return true
            }
        }
        return false
    }

    @inlinable
    public static func predicate(in archetype: borrowing Archetype) -> Bool {
        for filter in repeat (each T).self {
            if !filter.predicate(in: archetype) { // swiftlint:disable:this for_where
                return false
            }
        }
        return true
    }

    @inlinable
    public static func _initState(world: World) -> _State {
        _State(
            states: (repeat (each T)._initState(world: world))
        )
    }

    @inlinable
    public static func _initFetch(world: World, state: _State, lastTick: Tick, currentTick: Tick) -> _Fetch {
        _Fetch(
            fetches: (repeat (each T)._initFetch(
                    world: world,
                    state: each state.states,
                    lastTick: lastTick,
                    currentTick: currentTick
                ))
        )
    }

    @inlinable
    public static func _setData(
        state: _State,
        fetch: _Fetch,
        chunk: Chunk,
        archetype: Archetype
    ) -> _Fetch {
        var newFetch = fetch
        newFetch.fetches =
            (repeat (each T)
                ._setData(
                    state: each state.states,
                    fetch: each fetch.fetches,
                    chunk: chunk,
                    archetype: archetype
                ))
        return newFetch
    }

    @inlinable
    @inline(__always)
    public static func condition(
        state: State,
        fetch: Fetch,
        at row: Int
    ) -> Bool {
        for (filter, state, fetch) in repeat ((each T).self, each state.states, each fetch.fetches) {
            if !filter.condition(state: state, fetch: fetch, at: row) { // swiftlint:disable:this for_where
                return false
            }
        }
        return true
    }
}

public struct Not<T: Filter>: Filter {
    public typealias State = T.State
    public typealias Fetch = T.Fetch

    public static var access: SystemAccessSet {
        T.access
    }

    @inlinable
    public static func _initState(world: World) -> T.State {
        T._initState(world: world)
    }

    @inlinable
    public static func _initFetch(world: World, state: T.State, lastTick: Tick, currentTick: Tick) -> T.Fetch {
        T._initFetch(world: world, state: state, lastTick: lastTick, currentTick: currentTick)
    }

    @inlinable
    public static func _setData(state: T.State, fetch: T.Fetch, chunk: Chunk, archetype: Archetype) -> T.Fetch {
        T._setData(state: state, fetch: fetch, chunk: chunk, archetype: archetype)
    }

    @inlinable
    @inline(__always)
    public static func condition(state: T.State, fetch: T.Fetch, at row: Int) -> Bool {
        !T.condition(state: state, fetch: fetch, at: row)
    }
}

/// A filter that combines two filters with a logical OR operation.
public struct Or<each T: Filter>: Filter {
    public typealias State = _State
    public typealias Fetch = _Fetch

    public struct _State: Sendable {
        @usableFromInline
        var states: (repeat (each T).State)

        @usableFromInline
        init(states: (repeat (each T).State)) {
            self.states = states
        }
    }

    public static var access: SystemAccessSet {
        var access = SystemAccessSet()
        for filter in repeat (each T).self {
            access.formUnion(filter.access)
        }
        return access
    }

    public struct _Fetch {
        @usableFromInline
        var fetches: (repeat (each T).Fetch)

        @usableFromInline
        init(fetches: (repeat (each T).Fetch)) {
            self.fetches = fetches
        }
    }

    @inlinable
    public static var requiresRowEvaluation: Bool {
        for filter in repeat (each T).self {
            if filter.requiresRowEvaluation { // swiftlint:disable:this for_where
                return true
            }
        }
        return false
    }

    @inlinable
    public static func predicate(in archetype: borrowing Archetype) -> Bool {
        for filter in repeat (each T).self {
            if filter.predicate(in: archetype) { // swiftlint:disable:this for_where
                return true
            }
        }
        return false
    }

    @inlinable
    public static func _initState(world: World) -> _State {
        _State(
            states: (repeat (each T)._initState(world: world))
        )
    }

    @inlinable
    public static func _initFetch(world: World, state: _State, lastTick: Tick, currentTick: Tick) -> _Fetch {
        _Fetch(
            fetches: (repeat (each T)._initFetch(
                    world: world,
                    state: each state.states,
                    lastTick: lastTick,
                    currentTick: currentTick
                ))
        )
    }

    @inlinable
    public static func _setData(state: _State, fetch: _Fetch, chunk: Chunk, archetype: Archetype) -> _Fetch {
        var newFetch = fetch
        newFetch.fetches =
            (repeat (each T)
                ._setData(
                    state: each state.states,
                    fetch: each fetch.fetches,
                    chunk: chunk,
                    archetype: archetype
                ))
        return newFetch
    }

    @inlinable
    @inline(__always)
    public static func condition(
        state: State,
        fetch: Fetch,
        at row: Int
    ) -> Bool {
        for (filter, state, fetch) in repeat ((each T).self, each state.states, each fetch.fetches) {
            if filter.condition(state: state, fetch: fetch, at: row) { // swiftlint:disable:this for_where
                return true
            }
        }
        return false
    }
}

public struct Changed<T: Component>: Filter {
    @safe
    public struct ChangedFetch {
        @usableFromInline
        var ticks: UnsafeMutablePointer<Tick>?
        @usableFromInline
        var lastTick: Tick
        @usableFromInline
        var currentTick: Tick

        @usableFromInline
        init(
            ticks: UnsafeMutablePointer<Tick>? = nil,
            lastTick: Tick,
            currentTick: Tick
        ) {
            unsafe self.ticks = ticks
            self.lastTick = lastTick
            self.currentTick = currentTick
        }
    }

    public typealias State = Void
    public typealias Fetch = ChangedFetch

    public static var access: SystemAccessSet {
        var access = SystemAccessSet()
        access.addComponentRead(T.self)
        return access
    }

    @inlinable
    public static func predicate(in archetype: borrowing Archetype) -> Bool {
        archetype.componentLayout.maskSet.contains(T.identifier)
    }

    @inlinable
    public static func _initState(world _: World) {}

    @inlinable
    public static func _initFetch(
        world _: World,
        state _: Void,
        lastTick: Tick,
        currentTick: Tick
    ) -> ChangedFetch {
        unsafe ChangedFetch(lastTick: lastTick, currentTick: currentTick)
    }

    @inlinable
    public static func _setData(
        state _: Void,
        fetch: ChangedFetch,
        chunk: Chunk,
        archetype _: Archetype
    ) -> ChangedFetch {
        var newFetch = fetch
        guard let slice = chunk.getMutableComponentTicksSlice(for: T.self) else {
            return fetch
        }
        unsafe newFetch.ticks = slice.changed
        return newFetch
    }

    @inlinable
    @inline(__always)
    public static func condition(state _: Void, fetch: ChangedFetch, at row: Int) -> Bool {
        guard let tick = unsafe fetch.ticks?.advanced(by: row).pointee else {
            return false
        }
        return tick.isNewerThan(lastTick: fetch.lastTick, currentTick: fetch.currentTick)
    }
}

public struct Added<T: Component>: Filter {
    @safe
    public struct AddedFetch {
        @usableFromInline
        var ticks: UnsafeMutablePointer<Tick>?
        @usableFromInline
        var lastTick: Tick
        @usableFromInline
        var currentTick: Tick

        @usableFromInline
        init(
            ticks: UnsafeMutablePointer<Tick>? = nil,
            lastTick: Tick,
            currentTick: Tick
        ) {
            unsafe self.ticks = ticks
            self.lastTick = lastTick
            self.currentTick = currentTick
        }
    }

    public typealias State = Void
    public typealias Fetch = AddedFetch

    public static var access: SystemAccessSet {
        var access = SystemAccessSet()
        access.addComponentRead(T.self)
        return access
    }

    @inlinable
    public static func predicate(in archetype: borrowing Archetype) -> Bool {
        archetype.componentLayout.maskSet.contains(T.identifier)
    }

    @inlinable
    public static func _initState(world _: World) {}

    @inlinable
    public static func _initFetch(
        world _: World,
        state _: Void,
        lastTick: Tick,
        currentTick: Tick
    ) -> AddedFetch {
        unsafe AddedFetch(lastTick: lastTick, currentTick: currentTick)
    }

    @inlinable
    public static func _setData(
        state _: Void,
        fetch: AddedFetch,
        chunk: Chunk,
        archetype _: Archetype
    ) -> AddedFetch {
        var newFetch = fetch
        guard let slice = chunk.getMutableComponentTicksSlice(for: T.self) else {
            return fetch
        }
        unsafe newFetch.ticks = slice.added
        return newFetch
    }

    @inlinable
    @inline(__always)
    public static func condition(state _: Void, fetch: AddedFetch, at row: Int) -> Bool {
        guard let tick = unsafe fetch.ticks?.advanced(by: row).pointee else {
            return false
        }
        return tick == fetch.lastTick
    }
}

/// A filter that includes all entities.
public struct NoFilter: Filter {
    public typealias State = Void
    public typealias Fetch = Void

    @inlinable
    public static var requiresRowEvaluation: Bool {
        false
    }

    @inlinable
    public static func _initState(world _: World) {}

    @inlinable
    public static func _initFetch(world _: World, state _: Void, lastTick _: Tick, currentTick _: Tick) {}

    @inlinable
    public static func _setData(state _: Void, fetch _: Void, chunk _: Chunk, archetype _: Archetype) {}

    @inlinable
    @inline(__always)
    public static func condition(state _: Void, fetch _: Void, at _: Int) -> Bool {
        true
    }
}
