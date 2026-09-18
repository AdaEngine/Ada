//
//  GenericUniformBufferSet.swift
//  AdaEngine
//
//  Created by v.prusakov on 3/18/24.
//

import Foundation

final class GenericUniformBufferSet: UniformBufferSet, @unchecked Sendable {
    /// Max frames in flight.
    let frames: Int
    let device: RenderDevice

    public var label: String?

    typealias FrameIndex = Int
    typealias Set = Int
    typealias Binding = Int

    private var uniformBuffers: [FrameIndex: [Set: [Binding: UniformBuffer]]] = [:]

    init(frames: Int, device: RenderDevice) {
        self.frames = frames
        self.device = device
    }

    func initBuffers(length: Int, binding: Int, set: Int) {
        for frame in 0..<frames {
            let buffer = self.device.createUniformBuffer(length: length, binding: binding)
            buffer.label = self.label
            self.setBuffer(buffer, set: set, frameIndex: frame)
        }
    }

    func setBuffer(_ buffer: UniformBuffer, set: Int, frameIndex: Int) {
        // frame -> set -> binding -> buffer
        self.uniformBuffers[frameIndex, default: [:]][set, default: [:]][buffer.binding] = buffer
    }

    func getBuffer(binding: Int, set: Int, frameIndex: Int) -> UniformBuffer {
        guard let buffer = self.uniformBuffers[frameIndex]?[set]?[binding] else {
            preconditionFailure("Uniform buffer \(binding) is missing from set \(set), frame \(frameIndex).")
        }
        return buffer
    }
}
