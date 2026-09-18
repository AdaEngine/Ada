//
//  UpdatableProperty.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 07.06.2024.
//

import AdaUtils
import Logging

/// A protocol that defines a property that can be updated.
public protocol UpdatableProperty {
    /// Update the property.
    ///
    /// - Returns: The property.
    @MainActor func update()
}

// MARK: - State Storage

/// A container that keeps state storages for a specific view node.
@MainActor
final class ViewStateContainer {
    private var storages: [ViewStatePropertyKey: UpdatablePropertyStorage] = [:]

    func storage<Value>(
        for key: ViewStatePropertyKey,
        initialValue: @autoclosure () -> StateStorage<Value>
    ) -> StateStorage<Value> {
        if let storage = storages[key] as? StateStorage<Value> {
            return storage
        }

        let storage = initialValue()
        storages[key] = storage
        return storage
    }
}

struct ViewStatePropertyKey: Hashable {
    let ordinal: Int
    let label: String
    let valueType: ObjectIdentifier
}

@MainActor
protocol ViewStateBindable {
    var stateValueType: ObjectIdentifier { get }

    func bind(to container: ViewStateContainer, key: ViewStatePropertyKey)
}

/// A protocol that defines a property that can be stored.
protocol PropertyStoragable {
    /// The storage of the property.
    ///
    /// - Returns: The storage of the property.
    @MainActor var storage: UpdatablePropertyStorage { get }
}

/// A storage for a updatable property.
@MainActor
class UpdatablePropertyStorage {
    /// The nodes that need to be updated.
    private(set) var nodes: WeakSet<ViewNode> = []

    /// The name of the property.
    var propertyName: String = ""

    nonisolated init() {}

    /// Update the property.
    ///
    /// - Returns: The property.
    func update() {
        let animationController = BindingAnimationTransaction.currentController

        nodes.forEach { node in
            if node.shouldNotifyAboutChanges {
                Logger(label: "org.adaengine.AdaUI")
                    .info("\(type(of: node.content)): \(propertyName) changed.")
            }

            let isStateUpdate = self is AnyStateStorage

            if let animationController {
                node.performWithTransientAnimationController(animationController) {
                    node.invalidateContent(propagateLayout: !isStateUpdate)
                }
                node.owner?.addTransientAnimationController(animationController)
            } else {
                node.invalidateContent(propagateLayout: !isStateUpdate)
            }

            if let containerView = node.owner?.containerView {
                // Content invalidation can change layout without changing the container frame.
                // `setNeedsLayout()` schedules `layoutSubviews` → `place()` before the next draw;
                // `setNeedsDisplay` alone only repaints with stale layout until something (e.g. resize) relayouts.
                if isStateUpdate {
                    node.markNeedsLayout()
                    containerView.setNeedsDisplay(in: node.visualAbsoluteFrame())
                } else {
                    containerView.setNeedsLayout()
                }
            }
        }
    }

    /// Register a node to update.
    ///
    /// - Parameter viewNode: The view node to register.
    @MainActor
    func registerNodeToUpdate(_ viewNode: ViewNode) {
        nodes.insert(viewNode)
        viewNode.storages.insert(self)
    }
}

@MainActor
protocol AnyStateStorage: AnyObject {}
