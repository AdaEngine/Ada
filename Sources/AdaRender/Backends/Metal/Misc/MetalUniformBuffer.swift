//
//  MetalUniformBuffer.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/31/23.
//

#if METAL
    import MetalKit

    // TODO: (Vlad) think about inheretence and how it affect type casting and vtables
    final class MetalUniformBuffer: MetalBuffer, UniformBuffer, @unchecked Sendable {
        let binding: Int

        init(buffer: MTLBuffer, binding: Int) {
            self.binding = binding
            super.init(buffer: buffer)
        }
    }

#endif
