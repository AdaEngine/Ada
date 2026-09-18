//
//  MeshArray.swift
//  AdaEngine
//
//  Created by v.prusakov on 11/9/21.
//

import AdaUtils
import Math

/// An object that holds the data for a mesh.
public struct MeshBuffer<Element>: Sequence {
    /// A type representing the sequence’s elements.
    public typealias Element = Element

    /// A type representing the iterator of the mesh buffer.
    public typealias Iterator = ChunkIterator<Element>

    internal var buffer: _MeshBuffer

    // MARK: - Public Methods

    public func makeIterator() -> Iterator {
        return Iterator(buffer: self.buffer)
    }

    /// Access the buffer as an array.
    public var elements: [Element] {
        return self.buffer.getData()
    }

    /// Get the number of elements in the buffer.
    public var count: Int {
        return self.buffer.count
    }

    /// Iterate over pairs of elements.
    public func forEach(_ body: (Element, Element) throws -> Void) rethrows {
        let iterator = ChunkIterator<(Element, Element)>(buffer: self.buffer)

        while let element = iterator.next() {
            try body(element.0, element.1)
        }
    }

    /// Iterate over three elements per step.
    public func forEach(_ body: (Element, Element, Element) throws -> Void) rethrows {
        let iterator = ChunkIterator<(Element, Element, Element)>(buffer: self.buffer)

        while let element = iterator.next() {
            try body(element.0, element.1, element.2)
        }
    }

    /// Iterate over four elements per step.
    public func forEach(_ body: (Element, Element, Element, Element) throws -> Void) rethrows {
        let iterator = ChunkIterator<(Element, Element, Element, Element)>(buffer: self.buffer)

        while let element = iterator.next() {
            try body(element.0, element.1, element.2, element.3)
        }
    }

    // MARK: - Internal Methods

    var indices: [UInt32] {
        return self.buffer.getIndices()
    }

    init(buffer: _MeshBuffer) {
        self.buffer = buffer
    }
}

extension MeshBuffer {
    @safe
    public struct ChunkIterator<T>: IteratorProtocol {
        private let buffer: _MeshBuffer
        private let currentChunk: UnsafeMutablePointer<Int>

        internal init(buffer: _MeshBuffer) {
            self.buffer = buffer
            unsafe self.currentChunk = UnsafeMutablePointer<Int>.allocate(capacity: MemoryLayout<Int>.size)
            unsafe self.currentChunk.pointee = 0
        }

        public func next() -> T? {
            let nextElement = unsafe self.buffer.getChunk(withOffset: currentChunk.pointee, type: T.self)
            unsafe currentChunk.pointee += MemoryLayout<T>.stride

            if nextElement == nil {
                unsafe currentChunk.deinitialize(count: 1)
                unsafe currentChunk.deallocate()
                return nil
            }

            return nextElement
        }
    }
}

extension MeshBuffer: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Element...) {
        let type: Mesh.ElementType

        if let valueType = elements.first {
            switch valueType {
            case is Int8:
                type = .int8
            case is UInt8:
                type = .uint8
            case is Int16:
                type = .int16
            case is UInt16:
                type = .uint16
            case is Int32:
                type = .int32
            case is UInt32:
                type = .uint32
            case is Float:
                type = .float
            case is Vector2:
                type = .vector2
            case is Vector3:
                type = .vector3
            case is Vector4:
                type = .vector4
            default:
                fatalError("[MeshBuffer] Type not supported.")
            }
        } else {
            fatalError("[MeshBuffer] Unrelated type.")
        }

        self.init(buffer: _MeshBuffer(elements: elements, indices: [], elementType: type))
    }
}

@safe
class _MeshBuffer: Equatable, @unchecked Sendable {
    internal let bytes: UnsafeMutableRawBufferPointer
    private let indicesPointer: UnsafeMutableBufferPointer<UInt32>
    internal let elementSize: Int
    internal let elementType: Mesh.ElementType

    init<Element>(elements: [Element], indices: [UInt32], elementType: Mesh.ElementType) {
        let elementSize = MemoryLayout<Element>.stride
        self.elementType = elementType
        self.elementSize = elementSize

        let bytes = UnsafeMutableRawBufferPointer.allocate(
            byteCount: elementSize * elements.count,
            alignment: MemoryLayout<Element>.alignment
        )

        if !elements.isEmpty {
            unsafe elements.withUnsafeBufferPointer { pointer in
                guard let sourceAddress = pointer.baseAddress else {
                    return
                }
                unsafe bytes.baseAddress?
                    .copyMemory(
                        from: sourceAddress,
                        byteCount: elementSize * elements.count
                    )
            }
        }

        unsafe self.bytes = bytes
        unsafe self.indicesPointer = UnsafeMutableBufferPointer<UInt32>.allocate(capacity: indices.count)
        _ = unsafe self.indicesPointer.initialize(from: indices)
    }

    deinit {
        unsafe self.bytes.deallocate()
        unsafe self.indicesPointer.deallocate()
    }

    // MARK: - Internal

    static func == (lhs: _MeshBuffer, rhs: _MeshBuffer) -> Bool {
        unsafe lhs.bytes.elementsEqual(rhs.bytes) && lhs.indicesPointer.elementsEqual(rhs.indicesPointer) && lhs.elementSize == rhs.elementSize
    }

    var count: Int {
        return unsafe self.bytes.count / self.elementSize
    }

    func iterateByElements(_ block: (Int, UnsafeMutableRawPointer) -> Void) {
        var currentIndex = 0
        let count = self.count
        guard let baseAddress = unsafe self.bytes.baseAddress else {
            return
        }

        while currentIndex < count {
            let pointer = unsafe baseAddress.advanced(by: currentIndex * self.elementSize)

            unsafe block(currentIndex, pointer)

            currentIndex += 1
        }
    }

    func getChunk<T>(withOffset offset: Int, type _: T.Type) -> T? {
        guard unsafe offset < self.bytes.endIndex else {
            return nil
        }
        return unsafe self.bytes.load(fromByteOffset: offset, as: T.self)
    }

    func getIndices() -> [UInt32] {
        unsafe Array(self.indicesPointer)
    }

    func getData<Element>() -> [Element] {
        unsafe Array(self.bytes.bindMemory(to: Element.self))
    }
}

extension MeshBuffer: Equatable {}

extension MeshBuffer where Element == Int8 {
    /// Create buffer from an array of elements.
    public init(_ array: [Element]) {
        self.buffer = _MeshBuffer(elements: array, indices: [], elementType: .int8)
    }

    /// Create buffer from an array of element values and an array of indices into that value array.
    public init(elements: [Element], indices: [UInt32]) {
        self.buffer = _MeshBuffer(elements: elements, indices: indices, elementType: .int8)
    }

    /// Create a buffer from any sequence of elements.
    public init<S>(_ sequence: S) where S: Sequence, S.Element == Element {
        self.buffer = _MeshBuffer(elements: Array(sequence), indices: [], elementType: .int8)
    }
}

extension MeshBuffer where Element == UInt8 {
    /// Create buffer from an array of elements.
    public init(_ array: [Element]) {
        self.buffer = _MeshBuffer(elements: array, indices: [], elementType: .uint8)
    }

    /// Create buffer from an array of element values and an array of indices into that value array.
    public init(elements: [Element], indices: [UInt32]) {
        self.buffer = _MeshBuffer(elements: elements, indices: indices, elementType: .uint8)
    }

    /// Create a buffer from any sequence of elements.
    public init<S>(_ sequence: S) where S: Sequence, S.Element == Element {
        self.buffer = _MeshBuffer(elements: Array(sequence), indices: [], elementType: .uint8)
    }
}

extension MeshBuffer where Element == Int16 {
    /// Create buffer from an array of elements.
    public init(_ array: [Element]) {
        self.buffer = _MeshBuffer(elements: array, indices: [], elementType: .int16)
    }

    /// Create buffer from an array of element values and an array of indices into that value array.
    public init(elements: [Element], indices: [UInt32]) {
        self.buffer = _MeshBuffer(elements: elements, indices: indices, elementType: .int16)
    }

    /// Create a buffer from any sequence of elements.
    public init<S>(_ sequence: S) where S: Sequence, S.Element == Element {
        self.buffer = _MeshBuffer(elements: Array(sequence), indices: [], elementType: .int16)
    }
}

extension MeshBuffer where Element == UInt16 {
    /// Create buffer from an array of elements.
    public init(_ array: [Element]) {
        self.buffer = _MeshBuffer(elements: array, indices: [], elementType: .uint16)
    }

    /// Create buffer from an array of element values and an array of indices into that value array.
    public init(elements: [Element], indices: [UInt32]) {
        self.buffer = _MeshBuffer(elements: elements, indices: indices, elementType: .uint16)
    }

    /// Create a buffer from any sequence of elements.
    public init<S>(_ sequence: S) where S: Sequence, S.Element == Element {
        self.buffer = _MeshBuffer(elements: Array(sequence), indices: [], elementType: .uint16)
    }
}

extension MeshBuffer where Element == Int32 {
    /// Create buffer from an array of elements.
    public init(_ array: [Element]) {
        self.buffer = _MeshBuffer(elements: array, indices: [], elementType: .int32)
    }

    /// Create buffer from an array of element values and an array of indices into that value array.
    public init(elements: [Element], indices: [UInt32]) {
        self.buffer = _MeshBuffer(elements: elements, indices: indices, elementType: .int32)
    }

    /// Create a buffer from any sequence of elements.
    public init<S>(_ sequence: S) where S: Sequence, S.Element == Element {
        self.buffer = _MeshBuffer(elements: Array(sequence), indices: [], elementType: .int32)
    }
}

extension MeshBuffer where Element == UInt32 {
    /// Create buffer from an array of elements.
    public init(_ array: [Element]) {
        self.buffer = _MeshBuffer(elements: array, indices: [], elementType: .uint32)
    }

    /// Create buffer from an array of element values and an array of indices into that value array.
    public init(elements: [Element], indices: [UInt32]) {
        self.buffer = _MeshBuffer(elements: elements, indices: indices, elementType: .uint32)
    }

    /// Create a buffer from any sequence of elements.
    public init<S>(_ sequence: S) where S: Sequence, S.Element == Element {
        self.buffer = _MeshBuffer(elements: Array(sequence), indices: [], elementType: .uint32)
    }
}

extension MeshBuffer where Element == Float {
    /// Create buffer from an array of elements.
    public init(_ array: [Element]) {
        self.buffer = _MeshBuffer(elements: array, indices: [], elementType: .float)
    }

    /// Create buffer from an array of element values and an array of indices into that value array.
    public init(elements: [Element], indices: [UInt32]) {
        self.buffer = _MeshBuffer(elements: elements, indices: indices, elementType: .float)
    }

    /// Create a buffer from any sequence of elements.
    public init<S>(_ sequence: S) where S: Sequence, S.Element == Element {
        self.buffer = _MeshBuffer(elements: Array(sequence), indices: [], elementType: .float)
    }
}

extension MeshBuffer where Element == Vector2 {
    /// Create buffer from an array of elements.
    public init(_ array: [Element]) {
        self.buffer = _MeshBuffer(elements: array, indices: [], elementType: .vector2)
    }

    /// Create buffer from an array of element values and an array of indices into that value array.
    public init(elements: [Element], indices: [UInt32]) {
        self.buffer = _MeshBuffer(elements: elements, indices: indices, elementType: .vector2)
    }

    /// Create a buffer from any sequence of elements.
    public init<S>(_ sequence: S) where S: Sequence, S.Element == Element {
        self.buffer = _MeshBuffer(elements: Array(sequence), indices: [], elementType: .vector2)
    }
}

extension MeshBuffer where Element == Vector3 {
    /// Create buffer from an array of elements.
    public init(_ array: [Element]) {
        self.buffer = _MeshBuffer(elements: array, indices: [], elementType: .vector3)
    }

    /// Create buffer from an array of element values and an array of indices into that value array.
    public init(elements: [Element], indecies: [UInt32]) {
        self.buffer = _MeshBuffer(elements: elements, indices: indecies, elementType: .vector3)
    }

    /// Create a buffer from any sequence of elements.
    public init<S>(_ sequence: S) where S: Sequence, S.Element == Element {
        self.buffer = _MeshBuffer(elements: Array(sequence), indices: [], elementType: .vector3)
    }
}

extension MeshBuffer where Element == Vector4 {
    /// Create buffer from an array of elements.
    public init(_ array: [Element]) {
        self.buffer = _MeshBuffer(elements: array, indices: [], elementType: .vector4)
    }

    /// Create buffer from an array of element values and an array of indices into that value array.
    public init(elements: [Element], indices: [UInt32]) {
        self.buffer = _MeshBuffer(elements: elements, indices: indices, elementType: .vector4)
    }

    /// Create a buffer from any sequence of elements.
    public init<S>(_ sequence: S) where S: Sequence, S.Element == Element {
        self.buffer = _MeshBuffer(elements: Array(sequence), indices: [], elementType: .vector4)
    }
}

extension MeshBuffer where Element == Color {
    /// Create buffer from an array of elements.
    public init(_ array: [Element]) {
        self.buffer = _MeshBuffer(elements: array, indices: [], elementType: .vector4)
    }

    /// Create buffer from an array of element values and an array of indices into that value array.
    public init(elements: [Element], indices: [UInt32]) {
        self.buffer = _MeshBuffer(elements: elements, indices: indices, elementType: .vector4)
    }

    /// Create a buffer from any sequence of elements.
    public init<S>(_ sequence: S) where S: Sequence, S.Element == Element {
        self.buffer = _MeshBuffer(elements: Array(sequence), indices: [], elementType: .vector4)
    }
}

/// Mesh buffer stored in the container.
public struct AnyMeshBuffer: Sendable {
    typealias Buffer = _MeshBuffer

    internal let buffer: Buffer

    init(_ buffer: Buffer) {
        self.buffer = buffer
    }

    init<V>(_ meshArray: MeshBuffer<V>) {
        self.buffer = meshArray.buffer
    }

    public var count: Int {
        self.buffer.count
    }

    public var elementType: Mesh.ElementType {
        return self.buffer.elementType
    }

    public func get<Value>(as _: Value.Type) -> MeshBuffer<Value>? {
        let buffer = self.buffer
        return MeshBuffer<Value>(buffer: buffer)
    }
}
