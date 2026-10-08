//
//  MetalIndexBuffer.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/18/23.
//

#if METAL

    import Metal

    final class MetalIndexBuffer: MetalBuffer, IndexBuffer, @unchecked Sendable {
        let indexFormat: IndexBufferFormat

        init(buffer: MTLBuffer, indexFormat: IndexBufferFormat) {
            self.indexFormat = indexFormat

            super.init(buffer: buffer)
        }
    }

#endif
