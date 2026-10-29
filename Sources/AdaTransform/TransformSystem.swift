//
//  TransformSystem.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/5/24.
//

import AdaECS
import AdaUtils
import Math

/// A system that updates the global transform of the entity.
@PlainSystem
public struct TransformSystem {
    @FilterQuery<
        Entity,
        Transform,
        Ref<GlobalTransform>,
        Or<
            Changed<Transform>,
            Added<Transform>,
            Added<GlobalTransform>
        >
    >
    private var query

    @Commands
    private var commands

    public init(world _: World) {}

    public func update(context _: UpdateContext) async {
        self.query.batched().forEach { _, transform, globalTransform in
            globalTransform.wrappedValue = GlobalTransform(matrix: transform.matrix)
        }
    }
}

/// A system that updates the global transform of the children of the entity.
@PlainSystem(dependencies: [
    .after(TransformSystem.self)
])
public struct ChildTransformSystem {
    @FilterQuery<
        Entity,
        Transform,
        RelationshipComponent,
        Or<
            Changed<Transform>,
            Added<Transform>,
            Changed<RelationshipComponent>,
            Added<RelationshipComponent>
        >
    >
    private var query

    @Commands
    private var commands

    public init(world _: World) {}

    public func update(context: UpdateContext) async {
        var dirty: Set<Entity.ID> = []
        self.query.batched().forEach { entity, _, _ in dirty.insert(entity.id) }
        var propagated: Set<Entity.ID> = []
        self.query.batched().forEach { entity, transform, relationship in
            // A changed ancestor will propagate the complete branch. Visiting
            // every changed bone separately otherwise repeats all descendants.
            guard !hasDirtyAncestor(entity.id, relationship: relationship, dirty: dirty, world: context.world) else { return }
            guard propagated.insert(entity.id).inserted else { return }
            let globalTransform = resolveGlobalTransform(
                for: entity,
                transform: transform,
                relationship: relationship,
                world: context.world
            )
            commands
                .entity(entity.id)
                .insert(globalTransform)

            updateChildren(
                relationship.children,
                world: context.world,
                parentTransform: globalTransform,
                propagated: &propagated
            )
        }
        // Invalid cycles have no topmost dirty node. Bound their traversal too,
        // while still updating each dirty entity at most once.
        self.query.batched().forEach { entity, transform, relationship in
            guard propagated.insert(entity.id).inserted else { return }
            let global = resolveGlobalTransform(for: entity, transform: transform, relationship: relationship, world: context.world)
            commands.entity(entity.id).insert(global)
            updateChildren(relationship.children, world: context.world, parentTransform: global, propagated: &propagated)
        }
    }

    private func hasDirtyAncestor(_ entity: Entity.ID, relationship: RelationshipComponent,
                                  dirty: Set<Entity.ID>, world: World) -> Bool {
        if let parent = relationship.parent, dirty.contains(parent) { return true }
        var parent = relationship.parent
        var visited: Set<Entity.ID> = [entity]
        while let id = parent, visited.insert(id).inserted {
            // Propagation stops at transformless nodes; descendants behind such
            // a gap must keep their own independent update.
            guard world.get(Transform.self, from: id) != nil else { return false }
            if dirty.contains(id) { return true }
            parent = world.get(RelationshipComponent.self, from: id)?.parent
        }
        return false
    }

    private func resolveGlobalTransform(
        for entity: Entity,
        transform: Transform,
        relationship: RelationshipComponent,
        world: World
    ) -> GlobalTransform {
        var matrix = transform.matrix
        var parentId = relationship.parent
        var visited = Set([entity.id])

        while let currentParentId = parentId,
            visited.insert(currentParentId).inserted,
            let parentTransform = world.get(Transform.self, from: currentParentId) {
            matrix = parentTransform.matrix * matrix
            parentId = world.get(RelationshipComponent.self, from: currentParentId)?.parent
        }

        return GlobalTransform(matrix: matrix)
    }

    /// Update the children of the entity.
    ///
    /// - Parameter children: The children of the entity.
    /// - Parameter parentTransform: The parent transform of the entity.
    private func updateChildren(
        _ children: some Sequence<Entity.ID>,
        world: World,
        parentTransform: GlobalTransform,
        propagated: inout Set<Entity.ID>
    ) {
        for child in children {
            guard propagated.insert(child).inserted, let childTransform = world.get(Transform.self, from: child) else {
                continue
            }

            let newMatrix = parentTransform.matrix * childTransform.matrix
            commands
                .entity(child)
                .insert(GlobalTransform(matrix: newMatrix))

            if let relationship = world.get(RelationshipComponent.self, from: child) {
                updateChildren(relationship.children, world: world, parentTransform: GlobalTransform(matrix: newMatrix), propagated: &propagated)
            }
        }
    }
}
