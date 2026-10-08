//
//  UniqueHashable.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/17/23.
//

/// A type that can be hashed into a ``UniqueHasher`` to produce an unique integer hash value.
public protocol UniqueHashable: Equatable {
    associatedtype HasherFunction: UniqueHasher

    /// The unique hash value.
    var uniqueHashValue: Int { get }

    /// Hashes the essential components of this value by feeding them into the given hasher.
    func hash(into hasher: inout HasherFunction)
}

extension UniqueHashable {
    public var uniqueHashValue: Int {
        var hasher = HasherFunction()
        self.hash(into: &hasher)
        return hasher.finalize()
    }
}

/// The universal hash function used by Set and Dictionary.
public protocol UniqueHasher {
    /// Creates a new hasher.
    init()

    /// Adds the given value to this hasher, mixing its essential parts into the
    /// hasher state.
    ///
    /// - Parameter value: A value to add to the hasher.
    mutating func combine<H>(_ value: H) where H: UniqueHashable

    /// Adds the contents of the given buffer to this hasher, mixing it into the
    /// hasher state.
    ///
    /// - Parameter bytes: A raw memory buffer.
    mutating func combine(bytes: UnsafeRawBufferPointer)

    /// Finalizes the hasher state and returns the hash value.
    ///
    /// Finalizing consumes the hasher: it is illegal to finalize a hasher you
    /// don't own, or to perform operations on a finalized hasher. (These may
    /// become compile-time errors in the future.)
    ///
    /// - Returns: The hash value calculated by the hasher.
    func finalize() -> Int
}
