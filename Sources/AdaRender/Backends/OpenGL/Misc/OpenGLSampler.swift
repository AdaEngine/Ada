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

            glGenSamplers(1, &sampler)

            //        glSamplerParameteri(sampler, GLenum(GL_TEXTURE_WRAP_S), GLint(descriptor.addressModeU.rawValue))
            //        glSamplerParameteri(sampler, GLenum(GL_TEXTURE_WRAP_T), GLint(descriptor.addressModeV.rawValue))
            //        glSamplerParameteri(sampler, GLenum(GL_TEXTURE_WRAP_R), GLint(descriptor.addressModeW.rawValue))
            glSamplerParameteri(sampler, GLenum(GL_TEXTURE_MIN_FILTER), GLint(descriptor.minFilter.glType))
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
