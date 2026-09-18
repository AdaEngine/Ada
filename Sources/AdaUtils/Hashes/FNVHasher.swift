//
//  FNVHasher.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/17/23.
//

/// Calculate unique FNV Hash function
/// - SeeAlso: Article about FNV - https://en.wikipedia.org/wiki/Fowler–Noll–Vo_hash_function
@frozen public struct FNVHasher: UniqueHasher {
    #if arch(arm64) || arch(x86_64)  // 64-bit
        static let OffsetBasis: UInt = 14_695_981_039_346_656_037

        @usableFromInline
        static let prime: UInt = 1_099_511_628_211
    #else  // 32-bit
        static let OffsetBasis: UInt = 2_166_136_261

        @usableFromInline
        static let prime: UInt = 16_777_619
    #endif

    @usableFromInline
    var hash: UInt

    public init() {
        hash = Self.OffsetBasis
    }

    @inlinable
    public mutating func combine<H>(_ value: H) where H: UniqueHashable {
        self.hash ^= UInt(truncatingIfNeeded: value.uniqueHashValue)
        self.hash = UInt(hash) &* Self.prime
    }

    public mutating func combine(bytes: UnsafeRawBufferPointer) {
        for index in 0..<bytes.count {
            unsafe self.hash ^= UInt(bytes[index])
            self.hash = UInt(hash) &* Self.prime
        }
    }

    public func finalize() -> Int {
        Int(truncatingIfNeeded: self.hash)
    }
}

extension String: UniqueHashable {
    public func hash(into hasher: inout FNVHasher) {
        unsafe self.utf8.withContiguousStorageIfAvailable { pointer in
            unsafe hasher.combine(bytes: UnsafeRawBufferPointer(pointer))
        }

        hasher.combine(0xFF as UInt8)  // terminator
    }
}

extension Int: UniqueHashable {
    public func hash(into hasher: inout FNVHasher) {
        var value = self
        unsafe withUnsafeBytes(of: &value) {
            unsafe hasher.combine(bytes: $0)
        }
    }
}

extension UInt32: UniqueHashable {
    public func hash(into hasher: inout FNVHasher) {
        var value = self
        unsafe withUnsafeBytes(of: &value) {
            unsafe hasher.combine(bytes: $0)
        }
    }
}

extension UInt64: UniqueHashable {
    public func hash(into hasher: inout FNVHasher) {
        var value = self
        unsafe withUnsafeBytes(of: &value) {
            unsafe hasher.combine(bytes: $0)
        }
    }
}

extension UInt8: UniqueHashable {
    public func hash(into hasher: inout FNVHasher) {
        var value = self
        unsafe withUnsafeBytes(of: &value) {
            unsafe hasher.combine(bytes: $0)
        }
    }
}

extension Float: UniqueHashable {
    public func hash(into hasher: inout FNVHasher) {
        hasher.combine(self.bitPattern)
    }
}

extension Double: UniqueHashable {
    public func hash(into hasher: inout FNVHasher) {
        hasher.combine(self.bitPattern)
    }
}
