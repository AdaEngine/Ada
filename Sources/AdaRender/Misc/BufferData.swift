//
//  BufferData.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 23.11.2025.
//

/// An object that describes the data of a buffer.
public struct BufferData<T> {
    private var storage: [T]

    /// The elements of the buffer data.
    public var elements: [T] {
        _read {
            yield storage
        }
        _modify {
            isChanged = true
            yield &storage
        }
    }
    /// The buffer associated with the buffer data.
    public var buffer: (any Buffer)?
    /// The label of the buffer data.
    public var label: String?
    /// Whether the buffer data has changed.
    public var isChanged: Bool = false

    /// Initialize a new buffer data.
    ///
    /// - Parameter label: The label of the buffer data.
    /// - Parameter elements: The elements of the buffer data.
    public init(label: String? = nil, elements: [T]) {
        self.label = label
        self.storage = elements
    }
}

extension BufferData: Equatable where T: Equatable {
    public static func == (lhs: BufferData<T>, rhs: BufferData<T>) -> Bool {
        lhs.elements == rhs.elements
    }
}

extension BufferData: Hashable where T: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.elements)
    }
}

extension BufferData: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: T...) {
        self.label = nil
        self.storage = elements
    }
}

extension BufferData: RandomAccessCollection {
    public typealias Element = T
    public typealias Index = Int

    public subscript(position: Int) -> T {
        _read {
            yield elements[position]
        }
        _modify {
            yield &elements[position]
        }
    }

    public var startIndex: Int {
        elements.startIndex
    }

    public var endIndex: Int {
        elements.endIndex
    }
}

extension BufferData {
    /// Whether the buffer data is empty.
    public var isEmpty: Bool {
        self.elements.isEmpty
    }

    /// The count of elements in the buffer data.
    public var count: Int {
        self.elements.count
    }

    /// The length of the buffer.
    public var bufferLength: Int {
        self.buffer?.length ?? 0
    }

    /// Write the buffer data to the buffer.
    /// - Parameter renderDevice: The render device to write the buffer data to.
    public mutating func write(to renderDevice: RenderDevice) {
        reserveCapacity(self.elements.count, for: renderDevice)
        guard let buffer else {
            return
        }
        buffer.setElements(&elements)
    }

    /// Reserve capacity for the buffer data.
    /// - Parameter count: The count of elements to reserve capacity for.
    /// - Parameter renderDevice: The render device to reserve capacity for.
    public mutating func reserveCapacity(_ count: Int, for renderDevice: RenderDevice) {
        let newCapacity = MemoryLayout<T>.stride * count
        if bufferLength >= newCapacity {
            return
        }
        self.buffer = renderDevice.createBuffer(label: label, length: newCapacity, options: .storageShared)
        self.isChanged = false
    }

    /// Append an element to the buffer data.
    /// - Parameter element: The element to append.
    public mutating func append(_ element: T) {
        self.elements.append(element)
        self.isChanged = true
    }

    /// Remove all elements from the buffer data.
    public mutating func removeAll() {
        self.elements.removeAll()
    }
}

extension BufferData: Sequence {}

extension BufferData: Sendable where T: Sendable {}
