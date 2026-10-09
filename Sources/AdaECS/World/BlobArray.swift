//
//  BlobArray.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 10.06.2025.
//

import AdaUtils
import Foundation

/// Type-erased storage whose copies share an allocation. The final allocation
/// owner destroys initialized slots with the supplied deinitializer before
/// freeing memory; clear and transfer operations update that ownership per slot.
@safe
public struct BlobArray: Sendable {
    @unsafe
    final class _Buffer: @unchecked Sendable {
        let count: Int
        let stride: Int
        let pointer: UnsafeMutableRawBufferPointer
        // Flags have the same per-slot, externally synchronized access contract as the raw
        // values. Structural operations are exclusive; query writes do not change these flags.
        let initialized: UnsafeMutableBufferPointer<Bool>
        var deinitializer: ((UnsafeMutableRawBufferPointer, Int) -> Void)?

        init(
            count: Int,
            stride: Int,
            pointer: UnsafeMutableRawBufferPointer,
            deinitializer: ((UnsafeMutableRawBufferPointer, Int) -> Void)? = nil
        ) {
            unsafe self.count = count
            unsafe self.stride = stride
            unsafe self.pointer = pointer
            unsafe self.initialized = .allocate(capacity: count)
            unsafe self.initialized.initialize(repeating: false)
            unsafe self.deinitializer = deinitializer
        }

        deinit {
            // Final allocation ownership includes every remaining initialized
            // value. Explicit clear/moves already unset flags, so they cannot
            // be destroyed again when the final shared buffer owner disappears.
            unsafe clear(count, stride: stride)
            unsafe initialized.deinitialize()
            unsafe initialized.deallocate()
            unsafe pointer.deallocate()
        }

        func clear(_ count: Int, stride: Int) {
            var index = 0
            while index < count {
                guard unsafe initialized[index] else {
                    index += 1
                    continue
                }
                let first = index
                while unsafe index < count && initialized[index] {
                    unsafe initialized[index] = false
                    index += 1
                }
                let element = unsafe UnsafeMutableRawBufferPointer(
                    start: pointer.baseAddress?.advanced(by: first * stride),
                    count: (index - first) * stride
                )
                unsafe deinitializer?(element, index - first)
            }
        }
    }

    public struct ElementLayout: Sendable {
        public let size: Int
        public let alignment: Int

        public init(size: Int, alignment: Int) {
            self.size = size
            self.alignment = alignment
        }
    }

    var buffer: _Buffer
    public let layout: ElementLayout
    public private(set) var count: Int
    let label: String?

    public init<T: ~Copyable>(
        count: Int,
        of _: T.Type,
        deinitializer: ((UnsafeMutableRawBufferPointer, Int) -> Void)? = nil
    ) {
        self.count = count
        self.layout = ElementLayout(size: MemoryLayout<T>.stride, alignment: MemoryLayout<T>.alignment)
        unsafe self.buffer = _Buffer(
            count: count,
            stride: MemoryLayout<T>.stride,
            pointer: .allocate(
                byteCount: count * MemoryLayout<T>.stride,
                alignment: MemoryLayout<T>.alignment
            ),
            deinitializer: deinitializer
        )
        // This label is only used when inspecting storage in a debugger. Type
        // reflection must not delay every resource allocation in release builds.
        #if DEBUG
            self.label = String(describing: T.self)
        #else
            self.label = nil
        #endif
    }
}

extension BlobArray {
    public mutating func realloc(_ count: Int) {
        let newBuffer = unsafe _Buffer(
            count: count,
            stride: self.layout.size,
            pointer: .allocate(
                byteCount: count * self.layout.size,
                alignment: self.layout.alignment
            ),
            deinitializer: buffer.deinitializer
        )
        let transferredCount = min(count, self.count)
        for index in transferredCount..<self.count {
            remove(at: index)
        }
        unsafe newBuffer.pointer.copyMemory(from: UnsafeRawBufferPointer(
            start: self.buffer.pointer.baseAddress,
            count: transferredCount * self.layout.size
        ))
        for index in 0..<transferredCount {
            unsafe newBuffer.initialized[index] = self.buffer.initialized[index]
            // Reallocation transfers ownership; views of the previous allocation are invalidated.
            forget(at: index)
        }
        unsafe self.buffer = newBuffer
        self.count = count
    }

    public func clear(_ count: Int) {
        unsafe self.buffer.clear(count, stride: self.layout.size)
    }

    func isInitialized(at index: Int) -> Bool {
        unsafe buffer.initialized[index]
    }

    /// Ends a slot's ownership after its value was transferred bitwise elsewhere.
    func forget(at index: Int) {
        unsafe buffer.initialized[index] = false
    }

    /// Initializes an empty slot or replaces an existing value, destroying it exactly once.
    public func insert<T: ~Copyable>(_ element: consuming T, at index: Int) {
        #if DEBUG
            precondition(
                MemoryLayout<T>.stride == self.layout.size && MemoryLayout<T>.alignment == self.layout.alignment,
                "Element has different layout"
            )
        #endif
        if isInitialized(at: index) {
            replace(consume element, at: index)
        } else {
            unsafe self.baseAddress()
                .advanced(by: index * self.layout.size)
                .assumingMemoryBound(to: T.self)
                .initialize(to: element)
            unsafe buffer.initialized[index] = true
        }
    }

    /// Replaces an initialized element, destroying the previous value exactly once.
    func replace<T: ~Copyable>(_ element: consuming T, at index: Int) {
        assert(isInitialized(at: index), "Replacement requires an initialized element")
        #if DEBUG
            precondition(
                MemoryLayout<T>.stride == self.layout.size && MemoryLayout<T>.alignment == self.layout.alignment,
                "Element has different layout"
            )
        #endif
        unsafe self.baseAddress()
            .advanced(by: index * self.layout.size)
            .assumingMemoryBound(to: T.self)
            .pointee = consume element
    }

    /// Returns a borrowed pointer. Keep the allocation owner alive through every
    /// access; clear, removal and reallocation can invalidate the pointed-to value.
    public func getMutablePointer<T: ~Copyable>(at index: Int, as type: T.Type) -> UnsafeMutablePointer<T> {
        #if DEBUG
            precondition(
                MemoryLayout<T>.stride == self.layout.size && MemoryLayout<T>.alignment == self.layout.alignment,
                "Element has different layout"
            )
        #endif

        return unsafe self.baseAddress()
            .advanced(by: index * self.layout.size)
            .bindMemory(to: type, capacity: self.layout.size)
    }

    public func get<T>(at index: Int, as type: T.Type) -> T {
        #if DEBUG
            precondition(
                MemoryLayout<T>.stride == self.layout.size && MemoryLayout<T>.alignment == self.layout.alignment,
                "Element has different layout"
            )
        #endif
        return unsafe self.baseAddress()
            .advanced(by: index * self.layout.size)
            .bindMemory(to: type, capacity: self.layout.size)
            .pointee
    }

    public func swapAndDrop(
        from fromIndex: Int,
        to toIndex: Int
    ) {
        swapAndDrop(from: fromIndex, to: toIndex, shouldDeinitialize: true)
    }

    public func swapAndDrop(
        from fromIndex: Int,
        to toIndex: Int,
        shouldDeinitialize: Bool
    ) {
        precondition(fromIndex >= 0 && toIndex >= 0)
        precondition(layout.size >= 0)

        if fromIndex == toIndex || layout.size == 0 {
            return
        }
        let sourceIsInitialized = isInitialized(at: fromIndex)
        let base = unsafe baseAddress()
        let fromPointer = unsafe base.advanced(by: fromIndex * layout.size)
        let toPointer = unsafe base.advanced(by: toIndex * layout.size)

        if shouldDeinitialize && isInitialized(at: toIndex) {
            unsafe self.buffer.deinitializer?(UnsafeMutableRawBufferPointer(start: toPointer, count: layout.size), 1)
        }
        unsafe withUnsafeTemporaryAllocation(of: UInt8.self, capacity: layout.size) { tmp in
            guard let temporaryAddress = tmp.baseAddress else {
                preconditionFailure("Temporary BlobArray storage was not allocated.")
            }
            let tempPointer = UnsafeMutableRawPointer(temporaryAddress)
            unsafe tempPointer.copyMemory(from: fromPointer, byteCount: layout.size)
            unsafe fromPointer.copyMemory(from: toPointer, byteCount: layout.size)
            unsafe toPointer.copyMemory(from: tempPointer, byteCount: layout.size)
        }
        unsafe buffer.initialized[toIndex] = sourceIsInitialized
        forget(at: fromIndex)
    }

    public func remove(at index: Int) {
        guard isInitialized(at: index) else {
            return
        }
        forget(at: index)
        // Create a buffer pointer starting at the element to remove
        let basePointer = unsafe self.baseAddress()
        let elementPointer = unsafe basePointer.advanced(by: index * self.layout.size)
        let elementBuffer = unsafe UnsafeMutableRawBufferPointer(
            start: elementPointer,
            count: self.layout.size
        )
        // Call deinitializer for 1 element at this position
        unsafe self.buffer.deinitializer?(elementBuffer, 1)
    }

    public func copyElement(
        to blobArray: inout BlobArray,
        from fromIndex: Int,
        to toIndex: Int
    ) {
        guard isInitialized(at: fromIndex) else {
            return
        }
        #if DEBUG
            precondition(
                self.layout.size == blobArray.layout.size && self.layout.alignment == blobArray.layout.alignment,
                "BlobArray has different layout"
            )
        #endif
        let sourcePointer = unsafe self.baseAddress().advanced(by: fromIndex * self.layout.size)
        let destinationPointer = unsafe blobArray.baseAddress().advanced(by: toIndex * self.layout.size)
        unsafe destinationPointer.copyMemory(from: sourcePointer, byteCount: self.layout.size)
        unsafe blobArray.buffer.initialized[toIndex] = true
    }

    @inline(__always)
    private func baseAddress() -> UnsafeMutableRawPointer {
        guard let address = unsafe buffer.pointer.baseAddress else {
            preconditionFailure("BlobArray storage is empty.")
        }
        return unsafe address
    }
}
