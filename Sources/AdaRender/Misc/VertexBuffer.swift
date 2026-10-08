//
//  VertexBuffer.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/31/23.
//

/// This protocol describe vertex buffer created for GPU usage.
public protocol VertexBuffer: Buffer {
    /// Contains group binding for shader.
    var binding: Int { get }
}
