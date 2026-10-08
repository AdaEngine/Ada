//
//  UniformBufferSet.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/31/23.
//

/// This component contains the set of ``UniformBuffer`` by specific binding and set.
public protocol UniformBufferSet: AnyObject, Sendable {
    /// The debug label for all created buffers.
    var label: String? { get set }

    /// Set buffer for specific frame index and set.
    func setBuffer(_ buffer: UniformBuffer, set: Int, frameIndex: Int)

    /// Get buffer for specific binding, set and frame index.
    func getBuffer(binding: Int, set: Int, frameIndex: Int) -> UniformBuffer

    /// Create set of buffers with specific length. Count of buffer depends on ``RenderEngine/Configuration/maxFramesInFlight`` value.
    func initBuffers(length: Int, binding: Int, set: Int)
}

extension UniformBufferSet {
    /// Create set of buffers with specific length. Count of buffer depends on ``RenderEngine/Configuration/maxFramesInFlight`` value.
    /// - Parameter for: The type of the buffer.
    /// - Parameter count: The count of the buffer.
    /// - Parameter binding: The binding of the buffer.
    /// - Parameter set: The set of the buffer.
    public func initBuffers<T>(for _: T.Type, count: Int = 1, binding: Int, set: Int) {
        assert(count >= 1, "Count can't be less then 1")
        self.initBuffers(length: MemoryLayout<T>.stride * count, binding: binding, set: set)
    }
}
