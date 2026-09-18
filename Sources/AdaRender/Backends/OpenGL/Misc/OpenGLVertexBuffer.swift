//
//  OpenGLVertexBuffer.swift
//  AdaEngine
//
//  Created by vladislav.prusakov on 13.03.2025.
//

#if OPENGL

    #if WASM
        import WebGL
    #endif
    #if DARWIN
        import OpenGL.GL3
    #else
        import OpenGL
    #endif

    final class OpenGLVertexBuffer: OpenGLBuffer, VertexBuffer, @unchecked Sendable {
        let binding: Int

        init(size: Int, binding: Int, usage: ResourceOptions) {
            self.binding = binding
            super.init(size: size, usage: usage)
        }

        override func bind() {
            super.bind()
            glBindBufferBase(target, GLuint(binding), buffer)
        }
    }

#endif
