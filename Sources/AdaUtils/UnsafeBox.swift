//
//  UnsafeBox.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 20.11.2025.
//

/// Holds and manage pointer to instance.
@propertyWrapper
@safe
public struct UnsafeBox<T> {
    @usableFromInline
    let box: _UnsafeBox

    @inlinable
    public var wrappedValue: T {
        _read {
            yield unsafe box.pointer.assumingMemoryBound(to: T.self).pointee
        }
        _modify {
            yield unsafe &box.pointer.assumingMemoryBound(to: T.self).pointee
        }
    }

    @inlinable
    public var projectedValue: UnsafeMutablePointer<T> {
        unsafe self.box.pointer.assumingMemoryBound(to: T.self)
    }

    @inlinable
    public init(_ block: () -> T) {
        unsafe self.box = _UnsafeBox(block())
    }

    @inlinable
    public init(_ wrappedValue: consuming T) {
        unsafe self.box = _UnsafeBox(wrappedValue)
    }

    @inlinable
    public init(_ pointer: UnsafeMutablePointer<T>) {
        unsafe self.box = _UnsafeBox(pointer)
    }

    init(_ box: _UnsafeBox) {
        unsafe self.box = box
    }

    @inlinable
    public func getPointer() -> UnsafeMutablePointer<T> {
        unsafe self.box.pointer.assumingMemoryBound(to: T.self)
    }

    @inlinable
    public subscript<U>(dynamicMember dynamicMember: WritableKeyPath<T, U>) -> U {
        _read {
            yield self.wrappedValue[keyPath: dynamicMember]
        }
        _modify {
            yield &self.wrappedValue[keyPath: dynamicMember]
        }
    }
}

extension UnsafeBox: Sendable where T: Sendable {}

extension UnsafeBox: Equatable where T: Equatable {
    public static func == (lhs: UnsafeBox<T>, rhs: UnsafeBox<T>) -> Bool {
        lhs.wrappedValue == rhs.wrappedValue
    }
}

extension UnsafeBox: CustomStringConvertible {
    public var description: String {
        return unsafe """
        UnsafeBox(\(String(describing: self.getPointer().pointee))
        """
    }
}

extension UnsafeBox: Hashable where T: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.wrappedValue)
    }
}

extension UnsafeBox: Codable where T: Codable {
    public init(from decoder: any Decoder) throws {
        let value = try T(from: decoder)
        unsafe self.box = _UnsafeBox(value)
    }

    public func encode(to encoder: any Encoder) throws {
        try wrappedValue.encode(to: encoder)
    }
}

extension UnsafeMutablePointer {
    @inlinable
    public func unsafeBox() -> UnsafeBox<Pointee> {
        unsafe UnsafeBox(self)
    }
}

@unsafe
@usableFromInline
final class _UnsafeBox: @unchecked Sendable {
    @usableFromInline
    let pointer: UnsafeMutableRawPointer

    private let automanaged: Bool
    private let deallocator: ((UnsafeMutableRawPointer) -> Void)?

    @usableFromInline
    init<T>(_ instance: consuming T) {
        unsafe pointer = .allocate(byteCount: MemoryLayout<T>.stride, alignment: MemoryLayout<T>.alignment)
        unsafe pointer.initializeMemory(as: T.self, to: instance)
        unsafe deallocator = {
            unsafe $0.assumingMemoryBound(to: T.self)
                .deinitialize(count: 1)
        }
        unsafe automanaged = true
    }

    @usableFromInline
    init<T>(_ pointer: UnsafeMutablePointer<T>) {
        unsafe self.pointer = UnsafeMutableRawPointer(pointer)
        unsafe self.deallocator = nil
        unsafe self.automanaged = false
    }

    @usableFromInline
    init(_ pointer: OpaquePointer) {
        unsafe self.pointer = UnsafeMutableRawPointer(pointer)
        unsafe self.deallocator = nil
        unsafe self.automanaged = false
    }

    deinit {
        guard unsafe self.automanaged else {
            return
        }
        unsafe deallocator?(pointer)
        unsafe pointer.deallocate()
    }
}

@safe
public struct UnsafeAnyBox {
    @usableFromInline
    let box: _UnsafeBox

    @inlinable
    public init<T>(_ block: () -> T) {
        unsafe self.box = _UnsafeBox(block())
    }

    @inlinable
    public init<T>(_ wrappedValue: consuming T) {
        unsafe self.box = _UnsafeBox(wrappedValue)
    }

    @inlinable
    public init(_ opaque: OpaquePointer) {
        unsafe self.box = _UnsafeBox(opaque)
    }

    @inlinable
    public init<T>(_ pointer: UnsafeMutablePointer<T>) {
        unsafe self.box = _UnsafeBox(pointer)
    }

    public func bind<T>(to _: T.Type) -> UnsafeBox<T> {
        return unsafe UnsafeBox(box)
    }
}
