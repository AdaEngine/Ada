//
//  Entity.swift
//  AdaEngine
//
//  Created by v.prusakov on 11/1/21.
//

// TODO: (Vlad) Make a benchmark
// FIXME: (Vlad) I think we should store components in ComponentTable and avoid storing them in ComponentSet. (Think about after benchmark)

import AdaUtils
import OrderedCollections

/// Describe an entity and its characteristics.
/// Entity in ECS based architecture is the main object that holds components.
open class Entity: Identifiable, @unchecked Sendable {
    static let notAllocatedId = -25_102_018

    /// Contains entity name.
    public let name: String

    /// Contains unique identifier of entity.
    public package(set) var id: Int

    /// Contains components specific for current entity.
    public var components: ComponentSet

    /// The dispose bag of the entity.
    var disposeBag: Set<AnyCancellable> = []

    /// A Boolean that indicates whether the entity is active.
    /// - Note:  AdaEngine doesn’t simulate or render inactive entities.
    public var isActive: Bool = true

    /// Contains reference for world where entity placed.
    public internal(set) weak var world: World? {
        didSet {
            self.components.world = world
        }
    }

    /// Create a new entity with not allocated id. To track that entity in the world use ``World/addEntity(_:)``
    /// - Parameter name: Name of entity. By default is `Entity`.
    public init(name: String = "Entity") {
        self.name = name
        self.id = Self.notAllocatedId
        self.components = ComponentSet(entity: self.id)
    }

    /// Create a new entity with not allocated id. To track that entity in the world use ``World/addEntity(_:)``
    /// - Parameter name: Name of entity. By default is `Entity`.
    public init(
        name: String = "Entity",
        @ComponentsBuilder components: () -> ComponentsBundle
    ) {
        self.name = name
        self.id = Self.notAllocatedId
        self.components = ComponentSet(entity: self.id)
        for component in components().components {
            self.components.notFlushedComponents[type(of: component).identifier] = component
        }
    }

    /// Create a new entity with id.
    /// - Parameter name: Name of entity. By default is `Entity`.
    init(name: String = "Entity", id: Int) {
        self.name = name
        self.id = id
        self.components = ComponentSet(entity: self.id)
    }

    // MARK: - Codable

    /// Create entity from decoder.
    public required convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let id = try container.decode(Int.self, forKey: .id)
        self.init(name: name, id: id)
        self.components = try container.decode(ComponentSet.self, forKey: .components)
        self.components.entity = id
    }

    /// Encode the entity to an encoder.
    /// - Parameter encoder: The encoder to encode the entity to.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.components, forKey: .components)
    }

    // MARK: - Public

    /// Remove entity from world.
    /// - Note: Entity will removed on next update tick.
    public func removeFromWorld(recursively: Bool = false) {
        self.world?.removeEntityOnNextTick(self, recursively: recursively)
    }

    /// Copy the entity.
    /// - Returns: A new entity with the same components.
    open func copy() -> Entity {
        let entity = Entity(name: self.name, id: Self.notAllocatedId)
        entity.components = self.components.copy()
        entity.components.entity = entity.id
        entity.isActive = self.isActive
        return entity
    }
}

// MARK: - Hashable

extension Entity: Hashable {
    /// Check if two entities are equal.
    /// - Parameter lhs: The left entity.
    /// - Parameter rhs: The right entity.
    /// - Returns: True if the two entities are equal, otherwise false.
    public static func == (lhs: Entity, rhs: Entity) -> Bool {
        return lhs.id == rhs.id && lhs.name == rhs.name
    }

    /// Hash the entity.
    /// - Parameter hasher: The hasher to hash the entity.
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.name)
        hasher.combine(self.id)
    }
}

extension Entity: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name
        case components
    }
}

extension Entity: CustomStringConvertible {
    /// A textual representation of the entity.
    public var description: String {
        """
        Entity(
            id: \(self.id), 
            name: \(self.name), 
            components: \(self.components)
        )
        """
    }
}

extension Cancellable {
    /// Stores this type-erasing cancellable instance in the entity.
    /// - Note: This cancellable will be canceled when the entity is removed.
    /// - Parameter entity: The entity to store the cancellable in.
    public func store(in entity: Entity) {
        if let anyCancellable = self as? AnyCancellable {
            entity.disposeBag.insert(anyCancellable)
        } else {
            entity.disposeBag.insert(AnyCancellable(self))
        }
    }
}
