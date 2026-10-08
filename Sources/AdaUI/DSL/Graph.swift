//
//  Graph.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 27.06.2024.
//

import AdaUtils
import Foundation

#if canImport(Glibc)
    import Glibc
#endif
#if canImport(Darwin)
    import Darwin.C
#endif
#if os(Windows)
    import WinSDK
#endif

@MainActor
final class ViewGraph {
    private static var viewsTypeToDebug: Set<ObjectIdentifier> = []

    static func registerViewToDebugUpdate<V: View>(_: V.Type) {
        viewsTypeToDebug.insert(ObjectIdentifier(V.self))
    }

    static func shouldNotifyAboutChanges(_ content: any View.Type) -> Bool {
        viewsTypeToDebug.contains(ObjectIdentifier(content))
    }
}

@MainActor
public struct _ViewInputs {
    weak var parentNode: ViewNode?
    var layout: any Layout = VStackLayout()
    var environment: EnvironmentValues
    var propertyStorages: [PropertyStoragable] = []
    var gestures: [_Gesture] = []

    /// Accumulated environment transform from `.environment()` / `.transformEnvironment()` modifiers
    /// in the current modifier chain. Set by `_ViewInputsViewModifier._makeModifier` and consumed by
    /// `_ViewInputsViewModifier._makeView` to store on the resulting node.
    var pendingEnvironmentTransform: ((inout EnvironmentValues) -> Void)?

    func makeNode<T: View>(from content: T) -> ViewNode {
        T._makeView(_ViewGraphNode(value: content), inputs: self).node
    }

    /// Method can find and register ``State``, ``Binding``, ``Environment`` property wrappers
    /// in new _ViewInputs value.
    func resolveStorages<T>(in content: T, stateContainer: ViewStateContainer? = nil) -> Self {
        var newSelf = self
        let mirror = Mirror(reflecting: content)
        var stateOrdinal = 0

        let storages = mirror.children.compactMap { label, property -> PropertyStoragable? in
            guard let storagable = property as? PropertyStoragable else {
                return nil
            }

            if let bindable = property as? ViewStateBindable {
                let key = ViewStatePropertyKey(
                    ordinal: stateOrdinal,
                    label: label ?? "",
                    valueType: bindable.stateValueType
                )
                stateOrdinal += 1

                guard let stateContainer else {
                    return nil
                }
                bindable.bind(to: stateContainer, key: key)
            }

            if let env = storagable.storage as? ViewContextStorage {
                env.values = self.environment
            }

            let storage = storagable.storage
            storage.propertyName = label ?? ""
            return storagable
        }
        newSelf.propertyStorages.append(contentsOf: storages)
        return newSelf
    }

    func requiresStateContainer<T>(for content: T) -> Bool {
        let mirror = Mirror(reflecting: content)
        return mirror.children.contains { _, property in
            property is ViewStateBindable
        }
    }

    /// Inflate all found storages to view node.
    @MainActor
    func registerNodeForStorages(_ node: ViewNode) {
        for storage in propertyStorages {
            if let viewContextStorage = storage.storage as? ViewContextStorage {
                viewContextStorage.values = node.environment
            }
            storage.storage.registerNodeToUpdate(node)
        }
    }
}

/// Contains resolved view node.
@MainActor
public struct _ViewOutputs {
    let node: ViewNode
}

/// Contains information for make list of views.
public struct _ViewListInputs {
    let input: _ViewInputs
}

/// Contains list of resolved view nodes.
public struct _ViewListOutputs {
    var outputs: [_ViewOutputs]
}

public struct _ViewGraphNode<Value>: Equatable {
    let value: Value

    subscript<U>(keyPath: KeyPath<Value, U>) -> _ViewGraphNode<U> {
        _ViewGraphNode<U>(value: self.value[keyPath: keyPath])
    }

    public static func == (lhs: _ViewGraphNode<Value>, rhs: _ViewGraphNode<Value>) -> Bool where Value: Equatable {
        lhs.value == rhs.value
    }

    public static func == (lhs: _ViewGraphNode<Value>, rhs: _ViewGraphNode<Value>) -> Bool {
        // if its pod, we can compare it together using memcmp.
        if _isPOD(Value.self) {
            let memSize = MemoryLayout<Value>.size
            return unsafe withUnsafePointer(to: lhs.value) { lhsPtr in
                unsafe withUnsafePointer(to: rhs.value) { rhsPtr in
                    unsafe memcmp(lhsPtr, rhsPtr, memSize) == 0
                }
            }
        } else {
            // For another hand we should compare it using reflection or smth else
            return false
        }
    }
}
