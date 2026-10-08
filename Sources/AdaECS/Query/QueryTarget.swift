//
//  QueryTarget.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 22.05.2025.
//

import AdaUtils

public protocol WorldQueryTarget: Sendable, ~Copyable {
    associatedtype Fetch

    associatedtype State: Sendable

    /// The access this target requires when fetched by a system query.
    static var access: SystemAccessSet { get }

    @inlinable
    static func _initState(world: World) -> State

    @inlinable
    static func _initFetch(
        world: World,
        state: State,
        lastTick: Tick,
        currentTick: Tick
    ) -> Fetch

    @inlinable
    static func _setData(
        state: State,
        fetch: Fetch,
        chunk: Chunk,
        archetype: Archetype,
    ) -> Fetch
}

extension WorldQueryTarget {
    public static var access: SystemAccessSet {
        SystemAccessSet()
    }
}

/// A protocol that allows to use components and entities as query targets.
public protocol QueryTarget: WorldQueryTarget, ~Copyable {
    /// Check that entity contains target.
    /// - Parameter entity: The entity to check.
    /// - Returns: True if the entity contains the target, otherwise false.
    @inlinable
    static func _queryTargetContains(in entity: Entity) -> Bool

    /// Create a new query target from an entity.
    /// - Parameter entity: The entity to create a query target from.
    /// - Returns: A new query target.
    @inlinable
    static func _queryFetch(
        for entity: Entity,
        state: State,
        fetch: Fetch,
        at row: Int
    ) -> Self?

    /// Check if an archetype contains the target.
    /// - Parameter archetype: The archetype to check.
    /// - Returns: True if the archetype contains the target, otherwise false.
    @inlinable
    static func _queryContains(in archetype: borrowing Archetype) -> Bool
}

extension Component {
    public static var access: SystemAccessSet {
        var access = SystemAccessSet()
        access.addComponentRead(Self.self)
        return access
    }

    @inlinable
    public static func _initState(world _: World) -> ComponentId {
        return Self.identifier
    }

    @inlinable
    public static func _initFetch(
        world _: World,
        state _: ComponentId,
        lastTick _: Tick,
        currentTick _: Tick
    ) -> ReadFetch<Self> {
        unsafe ReadFetch(data: nil)
    }

    public static func _queryFetch(
        for _: Entity,
        state _: ComponentId,
        fetch: ReadFetch<Self>,
        at row: Int
    ) -> Self? {
        unsafe fetch.data?[row]
    }

    public static func _setData(
        state _: ComponentId,
        fetch: ReadFetch<Self>,
        chunk: Chunk,
        archetype _: Archetype
    ) -> ReadFetch<Self> {
        guard let slice = unsafe chunk.getComponentSlice(for: Self.self) else {
            return fetch
        }
        return unsafe ReadFetch(data: slice)
    }

    @inlinable
    public static func _queryTargetContains(in entity: Entity) -> Bool {
        return entity.components.has(Self.self)
    }

    @inlinable
    public static func _queryContains(in archetype: borrowing Archetype) -> Bool {
        archetype.componentLayout.maskSet.contains(Self.identifier)
    }
}

@safe
public struct RefFetch<T> {
    @usableFromInline
    var data: UnsafeMutableBufferPointer<T>?

    @usableFromInline
    var added: UnsafeMutableBufferPointer<Tick>?

    @usableFromInline
    var change: UnsafeMutableBufferPointer<Tick>?

    @usableFromInline
    var lastTick: Tick
    @usableFromInline
    var currentTick: Tick

    @usableFromInline
    init(
        data: UnsafeMutableBufferPointer<T>?,
        added: UnsafeMutableBufferPointer<Tick>?,
        change: UnsafeMutableBufferPointer<Tick>?,
        lastTick: Tick,
        currentTick: Tick
    ) {
        unsafe self.data = data
        unsafe self.added = added
        unsafe self.change = change
        self.lastTick = lastTick
        self.currentTick = currentTick
    }
}

@safe
public struct ReadFetch<T> {
    var data: UnsafeBufferPointer<T>?

    @usableFromInline
    init(data: UnsafeBufferPointer<T>?) {
        unsafe self.data = data
    }
}

extension Ref: WorldQueryTarget where T: Component {}
extension Ref: QueryTarget where T: Component {
    public static var access: SystemAccessSet {
        var access = SystemAccessSet()
        access.addComponentWrite(T.self)
        return access
    }

    public static func _initFetch(
        world _: World,
        state _: ComponentId,
        lastTick: Tick,
        currentTick: Tick
    ) -> RefFetch<T> {
        unsafe RefFetch(
            data: nil,
            added: nil,
            change: nil,
            lastTick: lastTick,
            currentTick: currentTick
        )
    }

    public static func _initState(world _: World) -> ComponentId {
        T.identifier
    }

    @inlinable
    public static func _queryTargetContains(in entity: Entity) -> Bool {
        T._queryTargetContains(in: entity)
    }

    public static func _setData(
        state _: ComponentId,
        fetch: RefFetch<T>,
        chunk: Chunk,
        archetype _: Archetype
    ) -> RefFetch<T> {
        var newFetch = fetch
        guard
            let slice = unsafe chunk.getMutableComponentSlice(for: T.self),
            let ticks = chunk.getMutableComponentTicksSlice(for: T.self)
        else {
            return fetch
        }
        unsafe newFetch.data = UnsafeMutableBufferPointer(
            start: slice,
            count: chunk.count
        )
        unsafe newFetch.added = UnsafeMutableBufferPointer(
            start: ticks.added,
            count: chunk.count
        )
        unsafe newFetch.change = UnsafeMutableBufferPointer(
            start: ticks.changed,
            count: chunk.count
        )
        return newFetch
    }

    public static func _queryFetch(
        for _: Entity,
        state _: ComponentId,
        fetch: RefFetch<T>,
        at row: Int
    ) -> Ref<T>? {
        return unsafe Ref(
            pointer: unsafe fetch.data?.baseAddress?.advanced(by: row),
            changeTick: ChangeDetectionTick(
                added: fetch.added?.baseAddress?.advanced(by: row).unsafeBox(),
                change: fetch.change?.baseAddress?.advanced(by: row).unsafeBox(),
                lastTick: fetch.lastTick,
                currentTick: fetch.currentTick
            )
        )
    }

    @inlinable
    public static func _queryContains(in archetype: borrowing Archetype) -> Bool {
        return archetype.componentLayout.maskSet.contains(T.identifier)
    }
}

extension Entity: QueryTarget {
    public static var access: SystemAccessSet {
        SystemAccessSet()
    }

    public static func _setData(
        state _: Void,
        fetch _: Void,
        chunk _: Chunk,
        archetype _: Archetype
    ) {}

    public static func _queryFetch(
        for entity: Entity,
        state _: (),
        fetch _: (),
        at _: Int
    ) -> Self? {
        entity as? Self
    }

    public static func _initState(world _: World) {}

    public static func _initFetch(
        world _: World,
        state _: Void,
        lastTick _: Tick,
        currentTick _: Tick
    ) {}

    @inlinable
    public static func _queryTargetContains(in _: Entity) -> Bool {
        return true
    }

    /// Always returns true because entity is always present in an archetype.
    @inlinable
    public static func _queryContains(in _: borrowing Archetype) -> Bool {
        return true
    }
}

extension Optional: WorldQueryTarget where Wrapped: QueryTarget {}
extension Optional: QueryTarget where Wrapped: QueryTarget {
    public typealias State = Wrapped.State
    public typealias Fetch = Wrapped.Fetch

    public static var access: SystemAccessSet {
        Wrapped.access
    }

    @inlinable
    public static func _setData(
        state: Wrapped.State,
        fetch: Wrapped.Fetch,
        chunk: Chunk,
        archetype: Archetype
    ) -> Wrapped.Fetch {
        Wrapped._setData(state: state, fetch: fetch, chunk: chunk, archetype: archetype)
    }

    @inlinable
    public static func _queryFetch(
        for entity: Entity,
        state: Wrapped.State,
        fetch: Wrapped.Fetch,
        at row: Int
    ) -> Wrapped?? {
        .some(
            Wrapped._queryFetch(for: entity, state: state, fetch: fetch, at: row)
        )
    }

    @inlinable
    public static func _initState(world: World) -> State {
        Wrapped._initState(world: world)
    }

    @inlinable
    public static func _initFetch(world: World, state: State, lastTick: Tick, currentTick: Tick) -> Fetch {
        Wrapped._initFetch(world: world, state: state, lastTick: lastTick, currentTick: currentTick)
    }

    @inlinable
    public static func _queryTargetContains(in entity: Entity) -> Bool {
        Wrapped._queryTargetContains(in: entity)
    }

    @inlinable
    public static func _queryContains(in archetype: borrowing Archetype) -> Bool {
        return Wrapped._queryContains(in: archetype)
    }
}
