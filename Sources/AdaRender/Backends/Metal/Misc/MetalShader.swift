//
//  MetalShader.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/18/23.
//

#if METAL

    import MetalKit

    // TODO: Need store binaries using MTLBinaryArchive

    final class MetalShader: CompiledShader {
        let name: String

        let library: MTLLibrary
        let function: MTLFunction

        enum ShaderError: LocalizedError {
            case shaderSourceIsNotCode

            var errorDescription: String? {
                switch self {
                case .shaderSourceIsNotCode:
                    return "Shader source is not a code"
                }
            }
        }

        init(shader: Shader, device: MTLDevice) throws {
            guard case let .code(source) = shader.source else {
                throw ShaderError.shaderSourceIsNotCode
            }
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLFunctionDescriptor()
            descriptor.name = shader.entryPoint
            let function = try library.makeFunction(descriptor: descriptor)

            self.name = shader.entryPoint
            self.library = library
            self.function = function
        }
    }

#endif
