//
//  OpenGLRenderDevice.swift
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

    final class OpenGLRenderDevice: RenderDevice {
        unowned let context: OpenGLBackend.Context?

        init(context: OpenGLBackend.Context? = nil) {
            self.context = context
        }

        func createUniformBuffer(length: Int, binding: Int) -> any UniformBuffer {
            let buffer = OpenGLUniformBuffer(size: length, binding: binding, usage: .storageShared)
            buffer.initialize()
            return buffer
        }

        func createBuffer(length: Int, options: ResourceOptions) -> any Buffer {
            let buffer = OpenGLBuffer(size: length, usage: options)
            buffer.initialize()
            return buffer
        }

        func createBuffer(bytes: UnsafeRawPointer, length: Int, options: ResourceOptions) -> any Buffer {
            let buffer = OpenGLBuffer(size: length, usage: options)
            buffer.initialize(data: bytes)
            return buffer
        }

        func createIndexBuffer(format: IndexBufferFormat, bytes: UnsafeRawPointer, length: Int) -> any IndexBuffer {
            let buffer = OpenGLIndexBuffer(size: length, format: format, usage: .storagePrivate)
            buffer.initialize(data: bytes)
            return buffer
        }

        func createVertexBuffer(length: Int, binding: Int) -> any VertexBuffer {
            let buffer = OpenGLVertexBuffer(size: length, binding: binding, usage: .storagePrivate)
            buffer.initialize()
            return buffer
        }

        func compileShader(from shader: Shader) throws -> any CompiledShader {
            OpenGLBackend.currentContext?.makeCurrent()
            return try OpenGLShader(shader: shader)
        }

        func createRenderPipeline(from descriptor: RenderPipelineDescriptor) -> any RenderPipeline {
            OpenGLRenderPipeline(descriptor: descriptor)
        }

        func createSampler(from descriptor: SamplerDescriptor) -> any Sampler {
            OpenGLSampler(descriptor: descriptor)
        }

        func createUniformBufferSet() -> any UniformBufferSet {
            GenericUniformBufferSet(frames: RenderEngine.configurations.maxFramesInFlight, device: self)
        }

        func createTexture(from descriptor: TextureDescriptor) -> GPUTexture {
            do {
                OpenGLBackend.currentContext?.makeCurrent()
                return try OpenGLTexture(descriptor: descriptor)
            } catch {
                fatalError("\(error)")
            }
        }

        func getImage(from texture: Texture) -> Image? {
            (texture.gpuTexture as? OpenGLTexture)?.getImage()
        }
    }

    final class OpenGLDrawCommandBuffer: DrawCommandBuffer, Sendable {
        let framebuffer: OpenGLFramebuffer

        init(framebuffer: OpenGLFramebuffer) {
            self.framebuffer = framebuffer
        }
    }

    extension TriangleFillMode {
        var glType: GLenum {
            switch self {
            case .fill:
                GLenum(GL_TRIANGLES)
            case .lines:
                GLenum(GL_LINES)
            }
        }
    }

#endif
