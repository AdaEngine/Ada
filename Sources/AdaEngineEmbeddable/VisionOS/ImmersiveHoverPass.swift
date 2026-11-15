#if os(visionOS)
    import AdaECS
    @_spi(Internal) import AdaRender
    import AdaScene
    import AdaSpatial
    import AdaTransform
    import CompositorServices
    import Math
    import Metal
    import simd

    /// Writes mesh silhouettes to the system-owned gaze buffer. Eye direction never enters the app.
    @available(visionOS 26.0, *)
    @MainActor
    final class ImmersiveHoverPass {
        private let pipeline: any MTLRenderPipelineState
        private let depthState: any MTLDepthStencilState

        init(device: any MTLDevice, format: MTLPixelFormat, depthFormat: MTLPixelFormat) throws {
            let library = try device.makeLibrary(source: Self.shader, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "hoverVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "hoverFragment")
            descriptor.colorAttachments[0].pixelFormat = format
            descriptor.depthAttachmentPixelFormat = depthFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            let depth = MTLDepthStencilDescriptor()
            depth.depthCompareFunction = .greaterEqual
            depth.isDepthWriteEnabled = false
            guard let state = device.makeDepthStencilState(descriptor: depth) else { throw ImmersiveRendererError.metalResourceUnavailable }
            depthState = state
        }

        struct Geometry {
            struct Part {
                let vertices: any VertexBuffer
                let indices: any IndexBuffer
                let addressing: SIMD2<UInt32>
                let indexCount: Int
                let indexType: MTLIndexType
            }

            struct Draw {
                let owner: Entity.ID
                let transform: Transform3D
                let parts: [Part]
            }

            var draws: [Draw] = []
            var buffers: [any Buffer] = []
        }

        func prepare(world: World) -> Geometry {
            var geometry = Geometry()
            var seenBuffers: Set<ObjectIdentifier> = []
            for entity in world.getEntities() where entity.isActive {
                guard let mesh = entity.components[Mesh3DComponent.self], entity.components[Visibility.self] != .hidden else { continue }
                var owner: Entity? = entity
                while let node = owner, node.components[SpatialGrabbable.self] == nil { owner = node.parent }
                guard let owner, owner.id >= 0 else { continue }
                var parts: [Geometry.Part] = []
                for model in mesh.mesh.models {
                    for part in model.parts where part.primitiveTopology == .triangleList {
                        guard let position = part.vertexDescriptor.attributes.first(where: { $0.name == "positions" }),
                              let layout = part.vertexDescriptor.layouts.first(where: { _ in true }) else { continue }
                        parts.append(Geometry.Part(
                            vertices: part.vertexBuffer,
                            indices: part.indexBuffer,
                            addressing: SIMD2(UInt32(layout.stride), UInt32(position.offset)),
                            indexCount: part.indexCount,
                            indexType: part.isUInt32 ? .uint32 : .uint16
                        ))
                        let buffers: [any Buffer] = [part.vertexBuffer, part.indexBuffer]
                        for buffer in buffers where seenBuffers.insert(ObjectIdentifier(buffer)).inserted {
                            geometry.buffers.append(buffer)
                        }
                    }
                }
                guard !parts.isEmpty else { continue }
                let transform = entity.components[GlobalTransform.self]?.matrix ?? entity.components[Transform.self]?.matrix ?? .identity
                geometry.draws.append(.init(owner: owner.id, transform: transform, parts: parts))
            }
            return geometry
        }

        func encode(commands: any MTLCommandBuffer, drawable: LayerRenderer.Drawable, geometry: Geometry,
                    eyes: [Entity], nativeBuffers: [ObjectIdentifier: any MTLBuffer]) {
            guard !drawable.trackingAreasTextures.isEmpty else {
                return
            }
            var values: [Entity.ID: UInt16] = [:]
            for (index, view) in drawable.views.enumerated() where index < eyes.count {
                guard let camera = eyes[index].components[Camera.self], let pose = eyes[index].components[Transform.self] else { continue }
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = drawable.trackingAreasTextures[view.textureMap.textureIndex]
                pass.colorAttachments[0].slice = view.textureMap.sliceIndex
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].storeAction = .store
                pass.depthAttachment.texture = drawable.depthTextures[view.textureMap.textureIndex]
                pass.depthAttachment.slice = view.textureMap.sliceIndex
                pass.depthAttachment.loadAction = .load
                pass.depthAttachment.storeAction = .store
                guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { continue }
                encoder.setRenderPipelineState(pipeline)
                encoder.setDepthStencilState(depthState)
                encoder.setViewport(view.textureMap.viewport)
                encoder.setCullMode(.none)
                let viewProjection = camera.projection.makeClipView() * pose.matrix.inverse
                for draw in geometry.draws {
                    let value: UInt16
                    if let cached = values[draw.owner] {
                        value = cached
                    } else {
                        let area = drawable.addTrackingArea(identifier: .init(UInt64(draw.owner) + 1))
                        area.addHoverEffect(.automatic)
                        value = UInt16(area.renderValue.rawValue)
                        values[draw.owner] = value
                    }
                    var columns = Self.columns(viewProjection * draw.transform)
                    encoder.setVertexBytes(&columns, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                    var trackingValue = value
                    encoder.setFragmentBytes(&trackingValue, length: MemoryLayout<UInt16>.stride, index: 0)
                    for part in draw.parts {
                        guard let vertices = nativeBuffers[ObjectIdentifier(part.vertices)],
                              let indices = nativeBuffers[ObjectIdentifier(part.indices)] else { continue }
                        var addressing = part.addressing
                        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
                        encoder.setVertexBytes(&addressing, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 2)
                        encoder.drawIndexedPrimitives(type: .triangle, indexCount: part.indexCount, indexType: part.indexType,
                                                      indexBuffer: indices, indexBufferOffset: 0)
                    }
                }
                encoder.endEncoding()
            }
        }

        private static func columns(_ matrix: Transform3D) -> simd_float4x4 {
            simd_float4x4(
                columns: (
                    SIMD4(matrix[0, 0], matrix[0, 1], matrix[0, 2], matrix[0, 3]),
                    SIMD4(matrix[1, 0], matrix[1, 1], matrix[1, 2], matrix[1, 3]),
                    SIMD4(matrix[2, 0], matrix[2, 1], matrix[2, 2], matrix[2, 3]),
                    SIMD4(matrix[3, 0], matrix[3, 1], matrix[3, 2], matrix[3, 3])
                )
            )
        }

        private static let shader = """
            #include <metal_stdlib>
            using namespace metal;
            vertex float4 hoverVertex(uint id [[vertex_id]], const device uchar *vertices [[buffer(0)]],
                constant float4x4 &mvp [[buffer(1)]], constant uint2 &addressing [[buffer(2)]]) {
                const device packed_float3 *p = reinterpret_cast<const device packed_float3 *>(vertices + id * addressing.x + addressing.y);
                float4 clip = mvp * float4(float3(*p), 1);
                clip.z = clip.w - clip.z + 0.00001 * clip.w;
                return clip;
            }
            fragment ushort hoverFragment(constant ushort &value [[buffer(0)]]) { return value; }
            """
    }
#endif
