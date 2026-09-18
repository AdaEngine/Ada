//
//  MetalVertexBuffer.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/31/23.
//

#if METAL
    import MetalKit

    final class MetalVertexBuffer: MetalBuffer, VertexBuffer, @unchecked Sendable {
        var binding: Int
        let offset: Int

        init(buffer: MTLBuffer, binding: Int, offset: Int) {
            self.binding = binding
            self.offset = offset
            super.init(buffer: buffer)
        }
    }

#endif
