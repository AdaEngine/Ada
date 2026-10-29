import AdaUtils

/// A query whose component types are resolved at runtime.
///
/// The query binds component columns once per chunk and advances through rows
/// without materializing entity identifiers. Raw pointers remain private to
/// AdaECS and are valid only while the cursor is executing in its system scope.
@_spi(Scripting)
@propertyWrapper
public struct DynamicQuery: Sendable {
    public var wrappedValue: DynamicQueryResult {
        DynamicQueryResult(state: state, componentIDs: componentIDs, options: options)
    }

    let state: QueryState
    let componentIDs: [ComponentId]
    let declaredAccess: SystemAccessSet
    let options: DynamicQueryOptions

    /// - Parameters:
    ///   - components: Components the cursor fetches, in the order scripts address them by slot.
    ///   - optionalComponents: Fetched components that rows may lack. Their archetypes still match.
    ///   - changedComponents: Rows match only when at least one of these changed since the system last ran.
    ///   - addedComponents: Rows match only when at least one of these was added since the system last ran.
    public init(
        where predicate: QueryPredicate,
        components: [ComponentId],
        optionalComponents: Set<ComponentId> = [],
        changedComponents: [ComponentId] = [],
        addedComponents: [ComponentId] = [],
        access: SystemAccessSet
    ) {
        // A tick filter can only match an archetype that stores at least one of its components.
        func containingAny(_ ids: [ComponentId]) -> QueryPredicate {
            QueryPredicate { archetype in ids.contains { archetype.componentLayout.maskSet.contains($0) } }
        }
        var combined = predicate
        if !changedComponents.isEmpty { combined = combined && containingAny(changedComponents) }
        if !addedComponents.isEmpty { combined = combined && containingAny(addedComponents) }
        self.state = QueryState(predicate: combined, filter: .all)
        self.componentIDs = components
        self.declaredAccess = access
        self.options = DynamicQueryOptions(
            optional: optionalComponents,
            changed: changedComponents,
            added: addedComponents
        )
    }

    // SystemParameter requires this initializer, while DynamicQuery requires an explicit plan.
    // swiftlint:disable:next unavailable_function
    public init(from _: World) {
        preconditionFailure("DynamicQuery must be initialized with a runtime query plan.")
    }
}

extension DynamicQuery: SystemParameter {
    public var access: SystemAccessSet {
        declaredAccess
    }

    public func finish(_: World) {}

    public func update(from world: World) {
        state.updateArchetypes(in: world)
    }
}

struct DynamicQueryOptions: Sendable {
    var optional: Set<ComponentId>
    var changed: [ComponentId]
    var added: [ComponentId]
}

@_spi(Scripting)
public struct DynamicQueryResult: Sendable {
    let state: QueryState
    let componentIDs: [ComponentId]
    let options: DynamicQueryOptions

    public func makeCursor() -> DynamicQueryCursor {
        DynamicQueryCursor(state: state, componentIDs: componentIDs, options: options)
    }
}

@_spi(Scripting)
public final class DynamicQueryCursor: @unchecked Sendable {
    @safe
    private struct Column {
        let data: UnsafeMutableRawPointer
        let stride: Int
        let changedTicks: UnsafeMutablePointer<Tick>
    }

    private let componentIDs: [ComponentId]
    private let options: DynamicQueryOptions
    private let state: QueryState
    private var archetypePosition = 0
    private var chunkPosition = 0
    private var rowPosition = -1
    /// One entry per fetched component; `nil` where an optional component is absent from the chunk.
    private var columns: [Column?] = []
    private var changedTicks: [UnsafeMutablePointer<Tick>] = []
    private var addedTicks: [UnsafeMutablePointer<Tick>] = []
    private var columnsAreBound = false

    public private(set) var entityID: Entity.ID = -1

    init(state: QueryState, componentIDs: [ComponentId], options: DynamicQueryOptions) {
        self.state = state
        self.componentIDs = componentIDs
        self.options = options
        self.columns.reserveCapacity(componentIDs.count)
    }

    public func reset() {
        archetypePosition = 0
        chunkPosition = 0
        rowPosition = -1
        columns.removeAll(keepingCapacity: true)
        changedTicks.removeAll(keepingCapacity: true)
        addedTicks.removeAll(keepingCapacity: true)
        columnsAreBound = false
        entityID = -1
    }

    /// Starts a separate traversal of the same query plan. Nested loops must not
    /// advance or reset the cursor that owns an outer loop's component views.
    public func makeIndependentCursor() -> DynamicQueryCursor {
        DynamicQueryCursor(state: state, componentIDs: componentIDs, options: options)
    }

    public func advance() -> Bool {
        guard let world = state.world else {
            return false
        }

        while archetypePosition < state.archetypeIndecies.count {
            let archetypeIndex = state.archetypeIndecies[archetypePosition]
            guard world.archetypes.archetypes.indices.contains(archetypeIndex) else {
                moveToNextArchetype()
                continue
            }
            let archetype = world.archetypes.archetypes[archetypeIndex]
            guard chunkPosition < archetype.chunks.chunks.count else {
                moveToNextArchetype()
                continue
            }
            let chunk = archetype.chunks.chunks[chunkPosition]
            if rowPosition + 1 >= chunk.count {
                chunkPosition += 1
                rowPosition = -1
                columnsAreBound = false
                continue
            }
            if !columnsAreBound {
                guard bindColumns(in: chunk) else {
                    return false
                }
            }

            rowPosition += 1
            let candidateID = chunk.entities[rowPosition]
            guard
                let location = state.entities.entities[candidateID],
                archetype.entities.indices.contains(location.archetypeRow),
                archetype.entities[location.archetypeRow].isActive
            else {
                continue
            }
            guard passesTickFilters() else {
                continue
            }
            entityID = candidateID
            return true
        }
        entityID = -1
        return false
    }

    /// Whether the current row has the component at `componentIndex`. Always true for a required component.
    public func isPresent(componentAt componentIndex: Int) -> Bool {
        columns.indices.contains(componentIndex) && columns[componentIndex] != nil && rowPosition >= 0
    }

    /// Copies a typed fetched value without exposing the query's raw storage. The
    /// identity check prevents same-layout component types from aliasing each other.
    public func readTyped<C: Component>(_ type: C.Type, componentAt index: Int) -> C? {
        guard componentIDs.indices.contains(index), componentIDs[index] == type.identifier,
              columns.indices.contains(index), rowPosition >= 0, entityID >= 0, let column = columns[index] else { return nil }
        let pointer = unsafe column.data.advanced(by: rowPosition * column.stride).assumingMemoryBound(to: C.self)
        return unsafe pointer.pointee
    }

    /// Mutates a typed fetched value within the caller's declared write scope.
    /// No pointer escapes the closure; mutation stamps the component's change tick.
    @discardableResult
    public func updateTyped<C: Component>(_ type: C.Type, componentAt index: Int, _ update: (inout C) throws -> Void) rethrows -> Bool {
        guard componentIDs.indices.contains(index), componentIDs[index] == type.identifier,
              columns.indices.contains(index), rowPosition >= 0, entityID >= 0, let column = columns[index] else { return false }
        let pointer = unsafe column.data.advanced(by: rowPosition * column.stride).assumingMemoryBound(to: C.self)
        defer { unsafe column.changedTicks.advanced(by: rowPosition).pointee = state.world.currentTick }
        try unsafe update(&pointer.pointee)
        return true
    }

    private func passesTickFilters() -> Bool {
        guard !changedTicks.isEmpty || !addedTicks.isEmpty || !options.changed.isEmpty || !options.added.isEmpty else {
            return true
        }
        let world = state.world!
        let lastTick = state.lastTick
        let currentTick = world.currentTick
        func anyNewer(_ ticks: [UnsafeMutablePointer<Tick>], required: Bool) -> Bool {
            guard required else { return true }
            return ticks.contains { unsafe $0.advanced(by: rowPosition).pointee.isNewerThan(lastTick: lastTick, currentTick: currentTick) }
        }
        return anyNewer(changedTicks, required: !options.changed.isEmpty)
            && anyNewer(addedTicks, required: !options.added.isEmpty)
    }

    public func read(
        componentAt componentIndex: Int,
        field: ReflectedComponentField
    ) -> ReflectedFieldValue? {
        guard
            columns.indices.contains(componentIndex), rowPosition >= 0,
            let column = columns[componentIndex],
            let readPointer = unsafe field.readPointer
        else {
            return nil
        }
        let pointer = unsafe UnsafeRawPointer(column.data.advanced(by: rowPosition * column.stride))
        return unsafe readPointer(pointer)
    }

    @discardableResult
    public func write(
        componentAt componentIndex: Int,
        field: ReflectedComponentField,
        value: ReflectedFieldValue
    ) -> Bool {
        guard
            columns.indices.contains(componentIndex), rowPosition >= 0,
            let column = columns[componentIndex],
            field.accepts(value), let writePointer = unsafe field.writePointer
        else {
            return false
        }
        let pointer = unsafe column.data.advanced(by: rowPosition * column.stride)
        guard unsafe writePointer(pointer, value) else {
            return false
        }
        unsafe column.changedTicks.advanced(by: rowPosition).pointee = state.world.currentTick
        return true
    }

    private func moveToNextArchetype() {
        archetypePosition += 1
        chunkPosition = 0
        rowPosition = -1
        columnsAreBound = false
    }

    private func bindColumns(in chunk: Chunk) -> Bool {
        columns.removeAll(keepingCapacity: true)
        changedTicks.removeAll(keepingCapacity: true)
        addedTicks.removeAll(keepingCapacity: true)
        guard !chunk.isEmpty else {
            return false
        }
        for componentID in componentIDs {
            guard
                let componentData = chunk.componentsData[componentID],
                let data = unsafe componentData.data.buffer.pointer.baseAddress,
                let changed = unsafe componentData.changeTicks.buffer.pointer.baseAddress?
                    .assumingMemoryBound(to: Tick.self)
            else {
                // An absent optional component leaves a hole; an absent required one ends the query.
                guard options.optional.contains(componentID) else {
                    return false
                }
                columns.append(nil)
                continue
            }
            unsafe columns.append(
                Column(
                    data: data,
                    stride: componentData.data.layout.size,
                    changedTicks: changed
                )
            )
        }
        for componentID in options.changed {
            if let ticks = unsafe chunk.componentsData[componentID]?.changeTicks.buffer.pointer.baseAddress?
                .assumingMemoryBound(to: Tick.self) {
                unsafe changedTicks.append(ticks)
            }
        }
        for componentID in options.added {
            if let ticks = unsafe chunk.componentsData[componentID]?.addedTicks.buffer.pointer.baseAddress?
                .assumingMemoryBound(to: Tick.self) {
                unsafe addedTicks.append(ticks)
            }
        }
        columnsAreBound = true
        return true
    }
}
