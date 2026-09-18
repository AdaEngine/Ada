//
//  OpenGLUniformBuffer.swift
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

    final class OpenGLUniformBuffer: OpenGLBuffer, UniformBuffer, @unchecked Sendable {
        let binding: Int
        init(size: Int, binding: Int, usage: ResourceOptions) {
            self.binding = binding
            super.init(size: size, usage: usage)
            self.target = GLenum(GL_UNIFORM_BUFFER)
        }

        override func initialize(data: UnsafeRawPointer? = nil) {
            super.initialize(data: data)
        }

        override func bind() {
            super.bind()
            glBindBufferBase(target, GLuint(binding), buffer)
        }
    }

#endif
