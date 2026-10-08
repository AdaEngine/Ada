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
        DynamicQueryResult(state: state, componentIDs: componentIDs)
    }

    let state: QueryState
    let componentIDs: [ComponentId]
    let declaredAccess: SystemAccessSet

    public init(
        where predicate: QueryPredicate,
        components: [ComponentId],
        access: SystemAccessSet
    ) {
        self.state = QueryState(predicate: predicate, filter: .all)
        self.componentIDs = components
        self.declaredAccess = access
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

@_spi(Scripting)
public struct DynamicQueryResult: Sendable {
    let state: QueryState
    let componentIDs: [ComponentId]

    public func makeCursor() -> DynamicQueryCursor {
        DynamicQueryCursor(state: state, componentIDs: componentIDs)
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
    private let state: QueryState
    private var archetypePosition = 0
    private var chunkPosition = 0
    private var rowPosition = -1
    private var columns: [Column] = []
    private var columnsAreBound = false

    public private(set) var entityID: Entity.ID = -1

    init(state: QueryState, componentIDs: [ComponentId]) {
        self.state = state
        self.componentIDs = componentIDs
        self.columns.reserveCapacity(componentIDs.count)
    }

    public func reset() {
        archetypePosition = 0
        chunkPosition = 0
        rowPosition = -1
        columns.removeAll(keepingCapacity: true)
        columnsAreBound = false
        entityID = -1
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
            entityID = candidateID
            return true
        }
        entityID = -1
        return false
    }

    public func read(
        componentAt componentIndex: Int,
        field: ReflectedComponentField
    ) -> ReflectedFieldValue? {
        guard
            columns.indices.contains(componentIndex), rowPosition >= 0,
            let readPointer = unsafe field.readPointer
        else {
            return nil
        }
        let column = columns[componentIndex]
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
            field.accepts(value), let writePointer = unsafe field.writePointer
        else {
            return false
        }
        let column = columns[componentIndex]
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
        for componentID in componentIDs {
            guard
                let componentData = chunk.componentsData[componentID], !chunk.isEmpty,
                let data = unsafe componentData.data.buffer.pointer.baseAddress,
                let changedTicks = unsafe componentData.changeTicks.buffer.pointer.baseAddress?
                    .assumingMemoryBound(to: Tick.self)
            else {
                return false
            }
            unsafe columns.append(
                Column(
                    data: data,
                    stride: componentData.data.layout.size,
                    changedTicks: changedTicks
                )
            )
        }
        columnsAreBound = true
        return true
    }
}
