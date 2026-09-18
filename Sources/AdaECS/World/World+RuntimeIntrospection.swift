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
        field: EditorComponentFieldDescriptor
    ) -> EditorFieldValue? {
        guard
            let data = resources.getResourceData(for: type),
            let pointer = unsafe data.pointer.buffer.pointer.baseAddress,
            let readPointer = unsafe field.readPointer
        else {
            return nil
        }
        return unsafe readPointer(UnsafeRawPointer(pointer))
    }

    @_spi(Scripting)
    @discardableResult
    public func writeResourceField(
        type: any Resource.Type,
        field: EditorComponentFieldDescriptor,
        value: EditorFieldValue
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
