//
//  OpenGLTexture.swift
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

    final class OpenGLTexture: GPUTexture {
        let descriptor: TextureDescriptor
        var texture: GLuint = 0
        let target: GLenum

        init(
            texture: GLuint,
            target: GLenum,
            descriptor: TextureDescriptor
        ) {
            self.texture = texture
            self.target = target
            self.descriptor = descriptor
        }

        init(descriptor: TextureDescriptor) throws {
            self.descriptor = descriptor

            // Validate texture dimensions
            guard descriptor.width > 0 && descriptor.height > 0 else {
                throw TextureError.invalidDimensions(
                    width: descriptor.width,
                    height: descriptor.height
                )
            }

            let glType = descriptor.textureType.glType
            self.target = glType
            let internalFormat = descriptor.pixelFormat.glType
            let format = descriptor.pixelFormat.glFormat
            let minFilter = descriptor.samplerDescription.minFilter.glType
            let magFilter = descriptor.samplerDescription.magFilter.glType

            try checkOpenGLError()

            glGenTextures(1, &texture)
            glActiveTexture(GLenum(GL_TEXTURE0))
            glBindTexture(glType, texture)

            glTexParameteri(glType, GLenum(GL_TEXTURE_MIN_FILTER), minFilter)
            glTexParameteri(glType, GLenum(GL_TEXTURE_MAG_FILTER), magFilter)
            glTexParameteri(glType, GLenum(GL_TEXTURE_WRAP_S), GL_REPEAT)
            glTexParameteri(glType, GLenum(GL_TEXTURE_WRAP_T), GL_REPEAT)
            glTexParameteri(glType, GLenum(GL_TEXTURE_WRAP_R), GL_REPEAT)

            try checkOpenGLError()

            let pointer: UnsafeMutableBufferPointer<UInt8>? = descriptor.image.flatMap {
                let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: $0.data.count)
                _ = $0.data.copyBytes(to: buffer)
                return buffer
            }

            defer {
                pointer?.deallocate()
            }

            switch descriptor.textureType {
            case .texture1D,
                .texture1DArray:
                glTexImage1D(
                    glType,
                    GLint(descriptor.mipmapLevel),
                    internalFormat,
                    GLsizei(descriptor.width),
                    0,
                    GLenum(format),
                    GLenum(GL_UNSIGNED_BYTE),
                    pointer?.baseAddress
                )
            case .texture2D,
                .texture2DArray:
                // Determine the appropriate data type based on pixel format
                let dataType: GLenum
                switch descriptor.pixelFormat {
                case .rgba_16f:
                    dataType = GLenum(GL_HALF_FLOAT)
                case .rgba_32f,
                    .depth_32f,
                    .depth_32f_stencil8:
                    dataType = GLenum(GL_FLOAT)
                default:
                    dataType = GLenum(GL_UNSIGNED_BYTE)
                }

                glTexImage2D(
                    glType,
                    GLint(descriptor.mipmapLevel),
                    internalFormat,
                    GLsizei(descriptor.width),
                    GLsizei(descriptor.height),
                    0,
                    GLenum(format),
                    dataType,
                    pointer?.baseAddress
                )
            case .texture2DMultisample,
                .texture2DMultisampleArray:
                glTexImage2DMultisample(
                    glType,
                    GLsizei(0),
                    internalFormat,
                    GLsizei(descriptor.width),
                    GLsizei(descriptor.height),
                    GLboolean(GL_TRUE)
                )
            default:
                fatalErrorMethodNotImplemented()
            }

            // Check for errors after texture creation
            let error = glGetError()
            if error != GL_NO_ERROR {
                print("Texture creation debug info:")
                print("- Type: \(descriptor.textureType)")
                print("- Width: \(descriptor.width)")
                print("- Height: \(descriptor.height)")
                print("- Internal Format: \(internalFormat)")
                print("- Format: \(format)")

                if let image = descriptor.image {
                    print("- Image Data Size: \(image.data.count) bytes")
                    print("- Expected Data Size: \(descriptor.width * descriptor.height * 4) bytes")
                    if !image.data.isEmpty {
                        print("- First few bytes: \(Array(image.data.prefix(16)))")
                    }
                } else {
                    print("- No image data provided")
                }

                fatalError("Failed to create texture: OpenGL error \(error)")
            }
        }

        deinit {
            glDeleteTextures(1, &texture)
        }

        func bind() {
            glBindTexture(target, texture)
        }

        func unbind() {
            glBindTexture(target, 0)
        }

        func getImage() -> Image? {
            return nil
        }
    }

    extension Texture.TextureType {
        var glType: GLenum {
            switch self {
            case .texture1D:
                return GLenum(GL_TEXTURE_1D)
            case .texture1DArray:
                return GLenum(GL_TEXTURE_1D_ARRAY)
            case .texture2D:
                return GLenum(GL_TEXTURE_2D)
            case .texture2DArray:
                return GLenum(GL_TEXTURE_2D_ARRAY)
            case .texture2DMultisample:
                return GLenum(GL_TEXTURE_2D_MULTISAMPLE)
            case .texture2DMultisampleArray:
                return GLenum(GL_TEXTURE_2D_MULTISAMPLE_ARRAY)
            case .textureCube:
                return GLenum(GL_TEXTURE_CUBE_MAP)
            case .texture3D:
                return GLenum(GL_TEXTURE_3D)
            case .textureBuffer:
                return GLenum(GL_TEXTURE_BUFFER)
            }
        }
    }

    extension SamplerMinMagFilter {
        var glType: GLint {
            switch self {
            case .nearest:
                return GL_NEAREST
            case .linear:
                return GL_LINEAR
            }
        }
    }

    extension SamplerMipFilter {
        var glType: GLint {
            switch self {
            case .nearest:
                return GL_LINEAR_MIPMAP_NEAREST
            case .linear:
                return GL_LINEAR_MIPMAP_LINEAR
            case .notMipmapped:
                return 0
            }
        }
    }

    extension PixelFormat {
        var glType: GLint {
            switch self {
            case .none:
                return GL_NONE
            case .bgra8:
                return GL_RGBA8  // OpenGL doesn't have native BGRA internal format, use RGBA8
            case .bgra8_srgb:
                return GL_SRGB8_ALPHA8
            case .rgba8:
                return GL_RGBA8
            case .rgba_16f:
                return GL_RGBA16F
            case .rgba_32f:
                return GL_RGBA32F
            case .depth_32f_stencil8:
                return GL_DEPTH32F_STENCIL8
            case .depth_32f:
                return GL_DEPTH_COMPONENT32F
            case .depth24_stencil8:
                return GL_DEPTH24_STENCIL8
            }
        }

        var glFormat: GLint {
            switch self {
            case .rgba8,
                .rgba_16f,
                .rgba_32f:
                return GL_RGBA
            case .bgra8,
                .bgra8_srgb:
                return GL_BGRA  // Use BGRA as the format (not internal format)
            case .depth_32f:
                return GL_DEPTH_COMPONENT
            case .depth24_stencil8,
                .depth_32f_stencil8:
                return GL_DEPTH_STENCIL
            case .none:
                return GL_NONE
            }
        }
    }

    enum TextureError: Error {
        case invalidDimensions(width: Int, height: Int)
    }

    func checkOpenGLError() throws {
        let error = glGetError()
        if error != GL_NO_ERROR {
            assertionFailure("OpenGL error \(error)")
            throw OpenGLError(error)
        }
    }

    func reportOpenGLError() {
        do {
            try checkOpenGLError()
        } catch {
            // `checkOpenGLError` already records the diagnostic through assertionFailure.
        }
    }

    struct OpenGLError: LocalizedError {
        let error: GLenum

        init(_ error: GLenum) {
            self.error = error
        }

        var errorDescription: String? {
            return "OpenGL error \(error)"
        }
    }

#endif
