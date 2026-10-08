//
//  DismissAction.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 25.03.2026.
//

import AdaUtils

/// An action that dismisses a presentation.
///
/// Use the ``EnvironmentValues/dismiss`` environment value to get an instance
/// of this structure. Then call the instance to perform the dismissal.
///
/// ```swift
/// struct DetailView: View {
///     @Environment(\.dismiss) var dismiss
///
///     var body: some View {
///         Button("Close") { dismiss() }
///     }
/// }
/// ```
public struct DismissAction: Sendable, Hashable {
    /// Stores a main-actor-only dismissal closure behind stable identity so the
    /// public value can be copied through EnvironmentValues.
    private final class Storage: @unchecked Sendable {
        let action: @MainActor () -> Void

        init(action: @escaping @MainActor () -> Void) {
            self.action = action
        }
    }

    private let storage: Storage

    public init(_ action: @escaping @MainActor () -> Void) {
        self.storage = Storage(action: action)
    }

    @MainActor
    public func callAsFunction() {
        storage.action()
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        ObjectIdentifier(lhs.storage) == ObjectIdentifier(rhs.storage)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(storage))
    }
}

extension EnvironmentValues {
    /// An action that dismisses the current presentation.
    @Entry public var dismiss: DismissAction = DismissAction {}
}
