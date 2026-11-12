//
//  SAGARenderPipeline.swift
//  AdaEngine
//

#if SAGA_RENDER && canImport(SAGACompiler)
    import Foundation
    import SAGA
    import SAGACompiler
    import SAGACore
    import SAGAShaderIR
    import SAGATypes

    enum SAGAShaderError: Error {
        case spirvUnsupported
        case notASAGAShader
    }

    /// A shader stage translated by SAGA's compiler for the device's shader format.
    @_spi(Internal)
    public final class SAGAShader: CompiledShader, @unchecked Sendable {
        let artifact: RenderStageArtifact

        init(shader: Shader, output: ShaderOutputFormat) throws {
            let compiler = IndependentShaderCompiler()
            switch shader.source {
            case .code(let source):
                artifact = try compiler.compileRenderStage(.wgsl(source), entryPoint: shader.entryPoint, to: output)
            case .spirv(let data):
                let words = unsafe data.withUnsafeBytes { raw in
                    unsafe Array(raw.bindMemory(to: UInt32.self))
                }
                artifact = try compiler.compileRenderStage(.spirv(words), entryPoint: "main", to: output)
            }
        }
    }

    final class SAGARenderPipeline: RenderPipeline, @unchecked Sendable {
        let descriptor: RenderPipelineDescriptor
        let slot = ResourceSlot<SAGATypes.RenderPipeline>()
        /// Maps AdaRender vertex buffer indices to the dense slots of the SAGA pipeline.
        let vertexBufferSlots: [Int: UInt32]
        let context: SAGAContext
        /// Debug aid: whether unbound declared resources were already reported.
        var reportedMissingBindings = false
        let vertexInputLocations: [UInt32]
        /// Resources the shader stages declare; the encoder binds only these.
        let uniformSlots: Set<ComputeBindingSlot>
        let storageSlots: Set<ComputeBindingSlot>
        let textureSlots: Set<ComputeBindingSlot>
        let samplerSlots: Set<ComputeBindingSlot>

        init(context: SAGAContext, descriptor: RenderPipelineDescriptor) throws {
            guard let vertex = descriptor.vertex.compiledShader as? SAGAShader else {
                throw SAGAShaderError.notASAGAShader
            }
            var fragment: SAGAShader?
            if let fragmentShader = descriptor.fragment {
                guard let compiled = fragmentShader.compiledShader as? SAGAShader else {
                    throw SAGAShaderError.notASAGAShader
                }
                fragment = compiled
            }

            self.context = context
            self.descriptor = descriptor
            let active = descriptor.vertexDescriptor.activeBufferIndices
            self.vertexBufferSlots = Dictionary(uniqueKeysWithValues: active.enumerated().map { ($0.element, UInt32($0.offset)) })

            let vertexStage = vertex.artifact
            let fragmentStage = fragment?.artifact
            let stages = [vertexStage] + (fragmentStage.map { [$0] } ?? [])
            func slot(_ binding: IRResourceBinding) -> ComputeBindingSlot {
                ComputeBindingSlot(group: binding.group, binding: binding.binding)
            }
            self.uniformSlots = Set(stages.flatMap { $0.uniformBindings.map { slot($0.binding) } })
            self.storageSlots = Set(stages.flatMap { $0.storageBindings.map { slot($0.binding) } })
            self.textureSlots = Set(stages.flatMap { $0.sampledTextures.map { slot($0.binding) } })
            self.samplerSlots = Set(stages.flatMap { $0.samplerBindings.map { slot($0.binding) } })
            self.vertexInputLocations = vertexStage.vertexInputs.map(\.location)
            let layouts = Self.vertexLayouts(for: descriptor)
            let colorTargets = descriptor.colorAttachments.compactMap { attachment -> RenderColorTarget? in
                guard let format = attachment.format.sagaFormat else { return nil }
                return RenderColorTarget(format: format, colorState: attachment.sagaColorState)
            }
            let primitive = RenderPrimitiveState(
                topology: descriptor.primitive.saga,
                stripIndexFormat: nil,
                // Matches the other backends: an unset winding means clockwise front faces.
                frontFace: descriptor.frontFaceWinding == .counterClockwise ? .counterClockwise : .clockwise,
                cullMode: descriptor.backfaceCulling ? .back : .none
            )
            let depth = descriptor.depthStencilDescriptor.flatMap { depth -> RenderDepthState? in
                guard let format = descriptor.depthPixelFormat.sagaFormat else { return nil }
                let stencil = depth.stencilOperationDescriptor.map { op in
                    let face = RenderStencilFaceState(
                        compare: op.compare.saga, fail: op.fail.saga, depthFail: op.depthFail.saga, pass: op.pass.saga
                    )
                    return RenderStencilState(front: face, back: face)
                }
                return RenderDepthState(
                    format: format,
                    compare: depth.isDepthTestEnabled ? depth.depthCompareOperator.saga : .always,
                    writeEnabled: depth.isDepthWriteEnabled,
                    stencil: stencil
                )
            }

            let slot = self.slot
            context.queue.enqueue { device in
                let pipeline = try await device.createRenderPipeline(
                    vertex: vertexStage,
                    fragment: fragmentStage,
                    colorFormat: colorTargets.first?.format,
                    vertexBuffers: layouts,
                    depthState: depth,
                    primitive: primitive,
                    colorState: colorTargets.first?.colorState ?? .init(),
                    additionalColorTargets: Dictionary(
                        uniqueKeysWithValues: colorTargets.enumerated().dropFirst().map { (UInt32($0.offset), $0.element) }
                    )
                )
                slot.fulfill(pipeline)
            }
        }

        private static func vertexLayouts(for descriptor: RenderPipelineDescriptor) -> [VertexBufferLayout] {
            let vertexDescriptor = descriptor.vertexDescriptor
            return vertexDescriptor.activeBufferIndices.map { bufferIndex in
                let attributes = vertexDescriptor.attributes.buffer.enumerated().compactMap { location, attribute -> VertexAttribute? in
                    guard attribute.format != .invalid, attribute.bufferIndex == bufferIndex else { return nil }
                    return VertexAttribute(location: UInt32(location), offset: UInt32(attribute.offset), format: attribute.format.saga)
                }
                // A fallback attribute buffer holds one constant record shared by every vertex.
                let isConstantFallback = vertexDescriptor.attributes.buffer
                    .filter { $0.format != .invalid && $0.bufferIndex == bufferIndex }
                    .allSatisfy { $0.name.hasPrefix("default") }
                let layout = vertexDescriptor.layouts.buffer[bufferIndex]
                return VertexBufferLayout(
                    stride: isConstantFallback ? 0 : UInt32(layout.stride),
                    stepMode: layout.stepFunction == .perInstance ? .instance : .vertex,
                    attributes: attributes
                )
            }
        }
    }

    extension RenderPipelineColorAttachmentDescriptor {
        var sagaColorState: RenderColorState {
            guard isBlendingEnabled else { return RenderColorState() }
            return RenderColorState(
                blend: RenderBlendState(
                    color: RenderBlendComponent(
                        operation: rgbBlendOperation.saga,
                        sourceFactor: sourceRGBBlendFactor.saga,
                        destinationFactor: destinationRGBBlendFactor.saga
                    ),
                    alpha: RenderBlendComponent(
                        operation: alphaBlendOperation.saga,
                        sourceFactor: sourceAlphaBlendFactor.saga,
                        destinationFactor: destinationAlphaBlendFactor.saga
                    )
                )
            )
        }
    }

    extension IndexPrimitive {
        fileprivate var saga: RenderPrimitiveState.Topology {
            switch self {
            case .triangle: .triangleList
            case .triangleStrip: .triangleStrip
            case .line: .lineList
            case .lineStrip: .lineStrip
            case .points: .pointList
            }
        }
    }

    extension VertexFormat {
        fileprivate var saga: SAGATypes.VertexFormat {
            switch self {
            case .invalid, .float: .float32
            case .vector2: .float32x2
            case .vector3: .float32x3
            case .vector4: .float32x4
            case .uint, .char, .short: .uint32
            case .int: .sint32
            }
        }
    }

    extension BlendFactor {
        fileprivate var saga: RenderBlendFactor {
            switch self {
            case .zero: .zero
            case .one: .one
            case .sourceColor: .sourceColor
            case .oneMinusSourceColor: .oneMinusSourceColor
            case .sourceAlpha: .sourceAlpha
            case .oneMinusSourceAlpha: .oneMinusSourceAlpha
            case .destinationColor: .destinationColor
            case .oneMinusDestinationColor: .oneMinusDestinationColor
            case .destinationAlpha: .destinationAlpha
            case .oneMinusDestinationAlpha: .oneMinusDestinationAlpha
            case .sourceAlphaSaturated: .sourceAlphaSaturated
            case .blendColor, .blendAlpha: .constant
            case .oneMinusBlendColor, .oneMinusBlendAlpha: .oneMinusConstant
            }
        }
    }

    extension BlendOperation {
        fileprivate var saga: RenderBlendOperation {
            switch self {
            case .add: .add
            case .subtract: .subtract
            case .reverseSubtract: .reverseSubtract
            case .min: .min
            case .max: .max
            }
        }
    }

    extension CompareOperation {
        fileprivate var saga: CompareFunction {
            switch self {
            case .never: .never
            case .less: .less
            case .equal: .equal
            case .lessOrEqual: .lessEqual
            case .greater: .greater
            case .notEqual: .notEqual
            case .greaterOrEqual: .greaterEqual
            case .always: .always
            }
        }
    }

    extension StencilOperation {
        fileprivate var saga: RenderStencilOperation {
            switch self {
            case .keep: .keep
            case .zero: .zero
            case .replace: .replace
            case .incrementAndClamp: .incrementClamp
            case .decrementAndClamp: .decrementClamp
            case .invert: .invert
            case .incrementAndWrap: .incrementWrap
            case .decrementAndWrap: .decrementWrap
            }
        }
    }
#endif
