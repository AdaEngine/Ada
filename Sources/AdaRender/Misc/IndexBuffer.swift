//
//  IndexBuffer.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/18/23.
//

/// The index type for an index buffer that references vertices of geometric primitives.
public enum IndexBufferFormat: UInt8 {
    /// A 32-bit unsigned integer used as a primitive index.
    case uInt32

    /// A 16-bit unsigned integer used as a primitive index.
    case uInt16
}

/// This protocol describe index buffer created for GPU usage.
public protocol IndexBuffer: Buffer {
    /// Index type stored in the buffer.
    var indexFormat: IndexBufferFormat { get }
}
