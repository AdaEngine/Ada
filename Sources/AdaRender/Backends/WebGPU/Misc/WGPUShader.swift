//
//  WGPUShader.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/18/23.
//

#if WEBGPU_ENABLED && canImport(WebGPU)
    import AdaUtils
    import Foundation
    import Synchronization
    @unsafe @preconcurrency import WebGPU

    @_spi(Internal)
    public final class WGPUShader: CompiledShader {
        public let shader: WebGPU.GPUShaderModule
        public let entryPoint: String

        init(shader: Shader, device: WebGPU.GPUDevice) {
            #if WASM
                let code: String
                let entryPoint: String

                switch shader.source {
                case let .code(source):
                    code = source
                    entryPoint = shader.entryPoint
                case .spirv:
                    fatalError("SPIR-V shader modules are not supported by browser WebGPU.")
                }

                let module = webGPUDeviceLock.withLock { _ in
                    device.createShaderModule(
                        descriptor: WebGPU.GPUShaderModuleDescriptor(
                            label: shader.entryPoint,
                            code: code
                        )
                    )
                }
            #else
                let shaderData: any WebGPU.GPUChainedStruct
                let entryPoint: String

                switch shader.source {
                case let .code(code):
                    shaderData = WebGPU.GPUShaderSourceWGSL(code: code)
                    entryPoint = shader.entryPoint
                case let .spirv(data):
                    let code = data.withUnsafeBytes { buffer in
                        Array(buffer.bindMemory(to: UInt32.self))
                    }
                    shaderData = WebGPU.GPUShaderSourceSPIRV(code: code)
                    entryPoint = "main"
                }

                let module = webGPUDeviceLock.withLock { _ in
                    device.createShaderModule(
                        descriptor: WebGPU.GPUShaderModuleDescriptor(
                            label: shader.entryPoint,
                            nextInChain: shaderData
                        )
                    )
                }
            #endif

            self.shader = module
            self.entryPoint = entryPoint
        }
    }
#endif
