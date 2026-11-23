//
//  SAGAComputePass.swift
//  AdaEngine
//
//  Compute pipelines and the compute encoder, recorded as SAGA dispatch commands.
//

#if (SAGA_NATIVE || SAGA_METAL) && canImport(SAGACompiler)
    import Foundation
    import SAGA
    import SAGACore
    import SAGATypes

    enum SAGAComputeError: Error {
        case wrongStage
        case notASAGAShader
    }

    final class SAGAComputePipeline: ComputePipelineState, @unchecked Sendable {
        let descriptor: ComputePipelineDescriptor
        let slot = ResourceSlot<SAGATypes.ComputePipeline>()
        let context: SAGAContext

        var isReady: Bool { (try? slot.get()) != nil }

        init(context: SAGAContext, descriptor: ComputePipelineDescriptor) throws {
            guard descriptor.shader.stage == .compute else { throw SAGAComputeError.wrongStage }
            guard let compiled = descriptor.shader.compiledShader as? SAGAComputeShader else { throw SAGAComputeError.notASAGAShader }
            self.context = context
            self.descriptor = descriptor
            let artifact = compiled.artifact
            let slot = self.slot
            context.queue.enqueue { device in
                slot.fulfill(try await device.createComputePipeline(artifact))
            }
        }
    }

    final class SAGAComputeCommandEncoder: ComputeCommandEncoder, @unchecked Sendable {
        private let buffer: SAGACommandBuffer
        private var pipeline: SAGAComputePipeline?
        private var buffers: [ComputeBindingSlot: SAGABuffer] = [:]
        private var textures: [ComputeBindingSlot: ResourceSlot<ResourceID>] = [:]
        private var samplers: [ComputeBindingSlot: SAGASampler] = [:]
        /// Keeps bound textures alive until the commands are built.
        private var owners: [SAGAGPUTexture] = []

        init(buffer: SAGACommandBuffer) {
            self.buffer = buffer
        }

        func setComputePipelineState(_ pipeline: any ComputePipelineState) {
            self.pipeline = pipeline as? SAGAComputePipeline
        }

        func setResourceSet(_ resourceSet: ComputeResourceSet, index set: Int) {
            for entry in resourceSet.bindings {
                let slot = ComputeBindingSlot(group: UInt32(set), binding: UInt32(entry.binding))
                switch entry.resource {
                case .uniformBuffer(let uniform):
                    buffers[slot] = uniform as? SAGABuffer
                case let .sampledTexture(texture, mipLevel):
                    guard let gpu = texture.gpuTexture as? SAGAGPUTexture else { continue }
                    owners.append(gpu)
                    textures[slot] = mipLevel.map { gpu.mipView($0) } ?? gpu.sampledSlot
                case let .storageTexture(texture, mipLevel):
                    guard let gpu = texture.gpuTexture as? SAGAGPUTexture else { continue }
                    owners.append(gpu)
                    textures[slot] = gpu.mipView(mipLevel)
                case .sampler(let sampler):
                    samplers[slot] = sampler as? SAGASampler
                }
            }
        }

        func dispatch(threadgroups: SIMD3<Int>) {
            guard let pipeline, threadgroups.x > 0, threadgroups.y > 0, threadgroups.z > 0 else {
                return
            }
            let buffers = self.buffers, textures = self.textures, samplers = self.samplers, owners = self.owners
            let groups = DispatchWorkgroups(x: UInt32(threadgroups.x), y: UInt32(threadgroups.y), z: UInt32(threadgroups.z))
            buffer.append {
                withExtendedLifetime(owners) {}
                return .dispatchCompute(
                    pipeline: try pipeline.slot.get(),
                    bindings: try buffers.mapValues { try $0.slot.get() },
                    workgroups: groups,
                    textures: try textures.mapValues { try $0.get() },
                    samplers: try samplers.mapValues { try $0.slot.get() }
                )
            }
        }

        func endComputePass() {}
    }
#endif
