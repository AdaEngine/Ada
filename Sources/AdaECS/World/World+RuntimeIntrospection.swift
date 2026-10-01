import AdaUtils
import Foundation

extension World {
    public func getComponents(for entity: Entity.ID) -> [(typeName: String, component: any Component)] {
        guard let location = self.entities.entities[entity] else {
            return []
        }

        let chunk = self.archetypes
            .archetypes[location.archetypeId]
            .chunks
            .chunks[location.chunkIndex]

        return chunk.getComponents(for: entity)
            .map { _, component in
                (String(reflecting: type(of: component)), component)
            }
    }

    public func getComponent(named typeName: String, from entity: Entity.ID) -> (any Component)? {
        guard let componentType = RuntimeTypeRegistry.componentType(named: typeName) else {
            return getComponents(for: entity).first { $0.typeName == typeName }?.component
        }
        guard let location = self.entities.entities[entity] else {
            return nil
        }

        let chunk = self.archetypes
            .archetypes[location.archetypeId]
            .chunks
            .chunks[location.chunkIndex]

        return chunk.getComponents(for: entity)
            .first { id, _ in
                id == componentType.identifier
            }?
            .1
    }

    public func hasComponent(named typeName: String, in entity: Entity.ID) -> Bool {
        guard let componentType = RuntimeTypeRegistry.componentType(named: typeName) else {
            return false
        }
        return self.has(componentType.identifier, in: entity)
    }

    @discardableResult
    public func insertDefaultComponent(named typeName: String, into entity: Entity.ID) -> Bool {
        guard let component = RuntimeTypeRegistry.makeDefaultComponent(named: typeName) else {
            return false
        }
        insertTypeErasedComponent(component, into: entity)
        return true
    }

    public func getResource(named typeName: String) -> (any Resource)? {
        guard let resourceType = RuntimeTypeRegistry.resourceType(named: typeName) else {
            return nil
        }
        return self.resources.getResource(resourceType)
    }

    @_spi(Scripting)
    public func readResourceField(
        type: any Resource.Type,
        field: ReflectedComponentField
    ) -> ReflectedFieldValue? {
        guard
            let data = resources.getResourceData(for: type),
            let pointer = unsafe data.pointer.buffer.pointer.baseAddress,
            let readPointer = unsafe field.readPointer
        else {
            return nil
        }
        return unsafe readPointer(UnsafeRawPointer(pointer))
    }

    /// Reads one reflected component field within the caller's declared ECS access scope.
    @_spi(Scripting)
    public func readComponentField(
        component: ComponentId,
        entity: Entity.ID,
        field: ReflectedComponentField
    ) -> ReflectedFieldValue? {
        guard let location = entities.entities[entity] else {
            return nil
        }
        let chunk = archetypes.archetypes[location.archetypeId].chunks.chunks[location.chunkIndex]
        guard
            let data = chunk.componentsData[component],
            let base = unsafe data.data.buffer.pointer.baseAddress,
            let read = unsafe field.readPointer
        else { return nil }
        let pointer = unsafe base.advanced(by: location.chunkRow * data.data.layout.size)
        return unsafe read(UnsafeRawPointer(pointer))
    }

    /// Writes a reflected component field and updates its change tick without a structural mutation.
    @_spi(Scripting)
    @discardableResult
    public func writeComponentField(
        component: ComponentId,
        entity: Entity.ID,
        field: ReflectedComponentField,
        value: ReflectedFieldValue
    ) -> Bool {
        guard field.accepts(value), let location = entities.entities[entity] else {
            return false
        }
        let chunk = archetypes.archetypes[location.archetypeId].chunks.chunks[location.chunkIndex]
        guard
            let data = chunk.componentsData[component],
            let base = unsafe data.data.buffer.pointer.baseAddress,
            let ticks = unsafe data.changeTicks.buffer.pointer.baseAddress?.assumingMemoryBound(to: Tick.self),
            let write = unsafe field.writePointer
        else { return false }
        let pointer = unsafe base.advanced(by: location.chunkRow * data.data.layout.size)
        guard unsafe write(pointer, value) else {
            return false
        }
        unsafe ticks.advanced(by: location.chunkRow).pointee = currentTick
        return true
    }

    @_spi(Scripting)
    @discardableResult
    public func writeResourceField(
        type: any Resource.Type,
        field: ReflectedComponentField,
        value: ReflectedFieldValue
    ) -> Bool {
        guard
            field.accepts(value),
            let data = resources.getResourceData(for: type),
            let pointer = unsafe data.pointer.buffer.pointer.baseAddress,
            let writePointer = unsafe field.writePointer,
            unsafe writePointer(pointer, value)
        else {
            return false
        }
        var changedTick = data.changedTick
        changedTick.wrappedValue = currentTick
        return true
    }

    private func insertTypeErasedComponent(_ component: any Component, into entity: Entity.ID) {
        func insert<T: Component>(_ component: T) {
            self.insert(component, for: entity)
        }
        insert(component)
    }
}
