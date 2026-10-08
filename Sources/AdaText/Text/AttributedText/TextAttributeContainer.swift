//
//  TextAttributeContainer.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/7/23.
//

/// A container for attribute keys and values.
@dynamicMemberLookup
public struct TextAttributeContainer: Hashable, @unchecked Sendable {
    typealias Container = [ObjectIdentifier: AnyHashable]

    private(set) var container: Container = [:]

    public init() {}

    init(container: Container) {
        self.container = container
    }

    public mutating func merge(
        _ attributes: Self,
        mergePolicy: AttributedText.AttributeMergePolicy = .keepNew
    ) {
        self.container.merge(
            attributes.container,
            uniquingKeysWith: { old, new in
                return mergePolicy == .keepNew ? new : old
            }
        )
    }

    public mutating func merging(
        _ attributes: Self,
        mergePolicy: AttributedText.AttributeMergePolicy = .keepNew
    ) -> Self {
        let newContainer = self.container.merging(
            attributes.container,
            uniquingKeysWith: { old, new in
                return mergePolicy == .keepNew ? new : old
            }
        )

        return Self(container: newContainer)
    }
}

// MARK: - Subscripts

extension TextAttributeContainer {
    /// Returns style for specific type.
    public subscript<T: TextAttributeKey>(_ type: T.Type) -> T.Value? {
        get {
            return self.container[ObjectIdentifier(type)] as? T.Value
        }

        set {
            self.container[ObjectIdentifier(type), default: T.defaultValue] = newValue
        }
    }

    public subscript<T>(dynamicMember keyPath: WritableKeyPath<TextAttributeContainer, T>) -> T {
        get {
            return self[keyPath: keyPath]
        }

        set {
            self[keyPath: keyPath] = newValue
        }
    }
}
