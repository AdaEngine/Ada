//
//  UniformBuffer.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/31/23.
//

/// This protocol describe uniform buffer created for GPU usage.
public protocol UniformBuffer: Buffer {
    /// Contains binding slot for shader.
    var binding: Int { get }
}
