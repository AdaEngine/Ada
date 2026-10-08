//
//  State.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 08.06.2024.
//

@MainActor
public struct State<Value>: UpdatableProperty, PropertyStoragable {
    final class Handle {
        var storage: StateStorage<Value>?
        let makeInitialValue: (@MainActor () -> Value)?

        init(makeInitialValue: (@MainActor () -> Value)?) {
            self.makeInitialValue = makeInitialValue
        }
    }

    private let handle: Handle

    var storage: UpdatablePropertyStorage {
        return self.currentStorage()
    }

    public var wrappedValue: Value {
        _read {
            yield currentStorage().value
        }
        nonmutating _modify {
            let storage = currentStorage()
            yield &storage.value
            storage.update()
        }
    }

    public var projectedValue: Binding<Value> {
        Binding(storage: currentStorage())
    }

    public init(wrappedValue: Value) {
        self.handle = Handle(makeInitialValue: { wrappedValue })
    }

    public init(initialValue: Value) {
        self.handle = Handle(makeInitialValue: { initialValue })
    }

    public func update() {}

    public static func _makeStorage(_ makeInitialValue: @escaping @MainActor () -> Value) -> State<Value> {
        Self(makeInitialValue: makeInitialValue)
    }

    public static func _makeStorage(initialValue: Value) -> State<Value> {
        Self(initialValue: initialValue)
    }

    private init(makeInitialValue: (@MainActor () -> Value)?) {
        self.handle = Handle(makeInitialValue: makeInitialValue)
    }

    private func currentStorage() -> StateStorage<Value> {
        if let storage = handle.storage {
            return storage
        }

        guard let makeInitialValue = handle.makeInitialValue else {
            fatalError("State storage was read before it was initialized.")
        }

        let storage = StateStorage(value: makeInitialValue())
        handle.storage = storage
        return storage
    }
}

final class StateStorage<Value>: UpdatablePropertyStorage, AnyStateStorage {
    var value: Value

    init(value: Value) {
        self.value = value
    }
}

extension State: ViewStateBindable {
    var stateValueType: ObjectIdentifier {
        ObjectIdentifier(Value.self)
    }

    func bind(to container: ViewStateContainer, key: ViewStatePropertyKey) {
        let storage = container.storage(
            for: key,
            initialValue: self.handle.storage ?? StateStorage(value: initialValue())
        )
        self.handle.storage = storage
    }

    private func initialValue() -> Value {
        guard let makeInitialValue = handle.makeInitialValue else {
            fatalError("State storage was bound before it was initialized.")
        }
        return makeInitialValue()
    }
}

@attached(accessor, names: named(get), named(set))
@attached(peer, names: prefixed(`_`), prefixed(`__`), prefixed(`$`))
public macro State() = #externalMacro(module: "AdaEngineMacros", type: "StateMacro")

@attached(accessor, names: named(get), named(set))
@attached(peer, names: prefixed(`_`), prefixed(`__`), prefixed(`$`))
public macro State<Value>(initialValue: Value) = #externalMacro(module: "AdaEngineMacros", type: "StateMacro")

@attached(accessor, names: named(get), named(set))
@attached(peer, names: prefixed(`_`), prefixed(`__`), prefixed(`$`))
public macro State<Value>(wrappedValue: Value) = #externalMacro(module: "AdaEngineMacros", type: "StateMacro")
