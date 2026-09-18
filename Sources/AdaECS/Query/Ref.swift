//
//  Ref.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 22.05.2025.
//

import AdaUtils

/// A reference to a component.
/// Used to mutate component values via ``Query``.
@dynamicMemberLookup
@propertyWrapper
@safe
public struct Ref<T>: Sendable, ChangeDetectionable {
    nonisolated(unsafe) private let pointer: UnsafeMutablePointer<T>?
    public var changeTick: ChangeDetectionTick

    /// The wrapped value of the reference.
    @inline(__always)
    public var wrappedValue: T {
        _read {
            guard let pointer = unsafe self.pointer else {
                preconditionFailure("Value \(T.self) is not stored in world.")
            }
            yield unsafe pointer.pointee
        }
        nonmutating _modify {
            guard let pointer = unsafe self.pointer else {
                preconditionFailure("Value \(T.self) is not stored in world.")
            }
            yield unsafe &pointer.pointee
            self.setChanged()
        }
    }

    /// Create a new reference to a component.
    /// - Parameters:
    ///   - get: A closure that returns the component value.
    ///   - set: A closure that sets the component value.
    public init(
        pointer: UnsafeMutablePointer<T>?,
        changeTick: ChangeDetectionTick
    ) {
        unsafe self.pointer = pointer
        self.changeTick = changeTick
    }

    @inline(__always)
    public subscript<U>(dynamicMember dynamicMember: WritableKeyPath<T, U>) -> U {
        _read {
            yield self.wrappedValue[keyPath: dynamicMember]
        }
        nonmutating _modify {
            yield &self.wrappedValue[keyPath: dynamicMember]
        }
    }
}
