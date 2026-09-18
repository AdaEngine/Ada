//
//  Buffer.swift
//  AdaEngine
//
//  Created by v.prusakov on 11/4/21.
//

/// This protocol describe buffer created for GPU usage.
public protocol Buffer: AnyObject, Sendable {
    /// A string that identifies the resource.
    var label: String? { get set }

    /// The logical size of the buffer, in bytes.
    var length: Int { get }

    /// Set data to the buffer's storage.
    /// - Parameter bytes: A pointer to the data which will be copied.
    /// - Parameter byteCount: Count of bytes which will be copied.
    /// - Parameter offset: Offset position where want to place copied data.
    func setData(_ bytes: UnsafeMutableRawPointer, byteCount: Int, offset: Int)

    /// Gets the system address of the buffer’s storage allocation.
    ///
    /// - Returns: A pointer to the shared copy of the buffer data, or NULL for buffers allocated with a private resource storage mode
    func contents() -> UnsafeMutableRawPointer

    /// Unmap the buffer's storage.
    func unmap()

    // /// Map the buffer's storage.
    // /// - Parameter mode: The mode of the buffer mapping.
    // /// - Parameter offset: The offset of the buffer mapping.
    // /// - Parameter size: The size of the buffer mapping.
    // /// - Parameter block: The block to be executed when the buffer is mapped.
    // func map(mode: BufferMapMode, offset: Int, size: Int, block: @escaping @Sendable (Result<UnsafeMutableRawPointer, Error>) -> Void)
}

/// The mode of the buffer mapping.
public struct BufferMapMode: OptionSet, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    /// The buffer is mapped for reading.
    public static let read = Self(rawValue: 1 << 0)
    /// The buffer is mapped for writing.
    public static let write = Self(rawValue: 1 << 1)
}

extension Buffer {
    // func map(mode: BufferMapMode = [.write, .read], offset: Int = 0, size: Int = Int.max, block: @escaping @Sendable (Result<UnsafeMutableRawPointer, Error>) -> Void) {
    //     unsafe self.map(mode: mode, offset: offset, size: size, block: block)
    // }

    /// Set data to the buffer's storage.
    /// - Parameter bytes: A pointer to the data which will be copied.
    /// - Parameter byteCount: Count of bytes which will be copied.
    public func setData(_ bytes: UnsafeMutableRawPointer, byteCount: Int) {
        unsafe self.setData(bytes, byteCount: byteCount, offset: 0)
    }

    /// Set data to the buffer's storage.
    /// - Parameter value: A value which will be copied.
    public func setData<T>(_ value: T) {
        let size = MemoryLayout<T>.stride

        unsafe withUnsafePointer(to: value) { ptr in
            unsafe self.setData(UnsafeMutableRawPointer(mutating: ptr), byteCount: size)
        }
    }

    /// Set elements to the buffer's storage.
    /// - Parameter value: A value which will be copied.
    public func setElements<T>(_ elements: inout [T]) {
        unsafe elements.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else {
                return
            }
            unsafe self.setData(baseAddress, byteCount: ptr.count)
        }
    }
}

/// Options for the memory location and access permissions for a resource.
public struct ResourceOptions: OptionSet, Sendable {
    public let rawValue: UInt

    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    /// The resource can be accessed only by the GPU.
    public static let storagePrivate = Self(rawValue: 1 << 0)

    /// The resource is stored in system memory and is accessible to both the CPU and the GPU.
    public static let storageShared = Self(rawValue: 1 << 1)

    /// The CPU and GPU may maintain separate copies of the resource, which you need to explicitly synchronize.
    public static let storageManaged = Self(rawValue: 1 << 2)
}
