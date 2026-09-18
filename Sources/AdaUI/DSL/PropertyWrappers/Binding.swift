//
//  Binding.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 28.06.2024.
//

import AdaAnimation

@MainActor
enum BindingAnimationTransaction {
    private(set) static var currentController: UIAnimationController?

    static func withAnimation<Result>(_ animation: Animation?, _ operation: () throws -> Result) rethrows -> Result {
        let previousController = currentController
        currentController = animation.map { UIAnimationController(animation: $0) }
        defer { currentController = previousController }
        return try operation()
    }
}

/// A property wrapper type that can read and write a value owned by a source of truth.
///
/// Use a binding to create a two-way connection between a property that stores data, and a view that displays and changes the data.
/// A binding connects a property to a source of truth stored elsewhere, instead of storing data directly.
/// For example, a button that toggles between play and pause can create a binding to a property of its parent view using the Binding property wrapper.
@propertyWrapper
public struct Binding<T>: UpdatableProperty {
    private enum Storage {
        case closures(get: () -> T, set: (T) -> Void)
        case mainActorClosures(get: @MainActor () -> T, set: @MainActor (T) -> Void)
        case state(StateStorage<T>)
    }

    /// The underlying value referenced by the binding variable.
    @MainActor
    public var wrappedValue: T {
        get {
            switch storage {
            case let .closures(getValue, _):
                return getValue()
            case let .mainActorClosures(getValue, _):
                return getValue()
            case let .state(stateStorage):
                return stateStorage.value
            }
        }
        nonmutating set {
            switch storage {
            case let .closures(_, setValue):
                setValue(newValue)
            case let .mainActorClosures(_, setValue):
                setValue(newValue)
            case let .state(stateStorage):
                stateStorage.value = newValue
                stateStorage.update()
            }
        }
    }

    private let storage: Storage

    /// Initialize a new binding.
    ///
    /// - Parameter get: The getter function.
    /// - Parameter set: The setter function.
    @preconcurrency
    public init(get: @escaping () -> T, set: @escaping (T) -> Void) {
        self.storage = .closures(get: get, set: set)
    }

    private init(mainActorGet get: @escaping @MainActor () -> T, set: @escaping @MainActor (T) -> Void) {
        self.storage = .mainActorClosures(get: get, set: set)
    }

    @preconcurrency
    @MainActor
    init(storage: StateStorage<T>) {
        self.storage = .state(storage)
    }

    /// Update the binding.
    ///
    /// - Returns: The binding.
    public func update() {}

    /// Returns a binding that applies an animation to changes made through it.
    ///
    /// - Parameter animation: The animation to apply. Pass `nil` to leave changes unanimated.
    /// - Returns: An animated binding.
    @MainActor
    public func animation(_ animation: Animation? = .default) -> Binding<T> {
        Binding<T>(
            mainActorGet: {
                self.wrappedValue
            },
            set: { @MainActor newValue in
                BindingAnimationTransaction.withAnimation(animation) {
                    self.wrappedValue = newValue
                }
            }
        )
    }

    /// Create a constant binding.
    ///
    /// - Parameter value: The value to bind.
    /// - Returns: A constant binding.
    public static func constant<Value>(_ value: Value) -> Binding<Value> {
        Binding<Value>(
            get: { return value },
            set: { _ in }
        )
    }

    /// Create a binding from a reference.
    ///
    /// - Parameter reference: The reference to bind.
    /// - Returns: A binding from a reference.
    @MainActor
    subscript<Subject>(dynamicMember keyPath: WritableKeyPath<T, Subject>) -> Binding<Subject> {
        return Binding<Subject>(
            mainActorGet: { self.wrappedValue[keyPath: keyPath] },
            set: { self.wrappedValue[keyPath: keyPath] = $0 }
        )
    }
}
