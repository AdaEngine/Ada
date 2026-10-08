//
//  OpenGLSampler.swift
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
    import Math

    final class OpenGLSampler: Sampler {
        var descriptor: SamplerDescriptor
        var sampler: GLuint = 0

        init(descriptor: SamplerDescriptor) {
            self.descriptor = descriptor

            func address(_ mode: SamplerAddressMode) -> GLint {
                switch mode {
                case .clampToEdge: return GLint(GL_CLAMP_TO_EDGE)
                case .repeat: return GLint(GL_REPEAT)
                case .mirroredRepeat: return GLint(GL_MIRRORED_REPEAT)
                }
            }
            glGenSamplers(1, &sampler)

            glSamplerParameteri(sampler, GLenum(GL_TEXTURE_WRAP_S), address(descriptor.addressModeU))
            glSamplerParameteri(sampler, GLenum(GL_TEXTURE_WRAP_T), address(descriptor.addressModeV))
            glSamplerParameteri(sampler, GLenum(GL_TEXTURE_WRAP_R), address(descriptor.addressModeW))
            let minification: GLenum
            switch (descriptor.minFilter, descriptor.mipFilter) {
            case (.nearest, .notMipmapped): minification = GLenum(GL_NEAREST)
            case (.linear, .notMipmapped): minification = GLenum(GL_LINEAR)
            case (.nearest, .nearest): minification = GLenum(GL_NEAREST_MIPMAP_NEAREST)
            case (.linear, .nearest): minification = GLenum(GL_LINEAR_MIPMAP_NEAREST)
            case (.nearest, .linear): minification = GLenum(GL_NEAREST_MIPMAP_LINEAR)
            case (.linear, .linear): minification = GLenum(GL_LINEAR_MIPMAP_LINEAR)
            }
            glSamplerParameteri(sampler, GLenum(GL_TEXTURE_MIN_FILTER), GLint(minification))
            glSamplerParameteri(sampler, GLenum(GL_TEXTURE_MAG_FILTER), GLint(descriptor.magFilter.glType))
            //        glSamplerParameteri(sampler, GLenum(GL_TEXTURE_COMPARE_MODE), GLint(descriptor.compareFunction.rawValue))
            //        glSamplerParameteri(sampler, GLenum(GL_TEXTURE_COMPARE_FUNC), GLint(descriptor.compareMode.rawValue))
            glSamplerParameterf(sampler, GLenum(GL_TEXTURE_MIN_LOD), descriptor.lodMinClamp)
            glSamplerParameterf(sampler, GLenum(GL_TEXTURE_MAX_LOD), descriptor.lodMaxClamp)
        }

        deinit {
            glDeleteSamplers(1, &sampler)
        }

        func bind() {
            glBindSampler(0, sampler)
        }
    }

#endif
