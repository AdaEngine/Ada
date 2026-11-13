import AdaAssets
import AdaCorePipelines
import AdaECS
import AdaRender
import AdaSpineRuntime
import AdaTransform
import AdaUtils
import Foundation
import Math

struct ExtractedSpineDraws: Resource {
    struct Character: Sendable {
        let entity: Entity.ID
        let transform: Transform3D
        let draws: [SpineDraw]
        let textures: [Texture2D?]
        let bones: [SpineBone]
        let boneDisplay: SpineDebugBones?
    }
    var characters: [Character] = []
}

@PlainSystem
struct ExtractSpineSystem {
    @Extract<Query<Entity, SpineAnimation, GlobalTransform, Visibility>> private var animations
    @ResMut<ExtractedSpineDraws> private var extracted

    init(world _: World) {}

    func update(context _: UpdateContext) {
        var characters: [ExtractedSpineDraws.Character] = []
        animations.wrappedValue.forEach { entity, animation, transform, visibility in
            guard visibility != .hidden else { return }
            characters.append(.init(entity: entity.id, transform: transform.matrix, draws: animation.player.snapshot(),
                                    textures: animation.skeleton.textures.map { $0.asset },
                                    bones: entity.components[SpineDebugBones.self] == nil ? [] : animation.player.boneSnapshot(),
                                    boneDisplay: entity.components[SpineDebugBones.self]))
        }
        extracted.characters = characters
    }
}

struct SpineRenderVertex: Sendable {
    let position: Vector4
    let light: Color
    let uv: Vector2
    let dark: Color
}

struct SpineRenderData: Resource {
    struct Batch: Sendable {
        let owner: Entity.ID
        let texture: Texture2D
        let indexRange: Range<Int>
    }
    struct PipelineKey: Hashable {
        let blend: Int
        let premultiplied: Bool
    }
    var vertices = BufferData<SpineRenderVertex>(label: "Spine vertices", elements: [])
    var indices = BufferData<UInt32>(label: "Spine indices", elements: [])
    var batches: [Entity.ID: Batch] = [:]
    var pipelines: [PipelineKey: RenderPipeline] = [:]
    var shaderModule: AssetHandle<ShaderModule>?

    mutating func pipeline(for draw: SpineDraw, device: RenderDevice) -> RenderPipeline {
        pipeline(blend: draw.blendMode, premultiplied: draw.premultipliedAlpha, device: device)
    }

    mutating func pipeline(blend: SpineDraw.BlendMode, premultiplied: Bool, device: RenderDevice) -> RenderPipeline {
        let key = PipelineKey(blend: blend.rawValue, premultiplied: premultiplied)
        if let pipeline = pipelines[key] { return pipeline }
        let shader = shaderModule ?? ShaderModule.loadRequiredBuiltin(at: "Assets/spine", from: .module)
        shaderModule = shader
        var descriptor = RenderPipelineDescriptor(vertex: shader.asset.requiredShader(for: .vertex))
        descriptor.fragment = shader.asset.getShader(for: .fragment)
        descriptor.backfaceCulling = false
        descriptor.vertexDescriptor.attributes.append([
            .attribute(.vector4, name: "a_Position"),
            .attribute(.vector4, name: "a_Color"),
            .attribute(.vector2, name: "a_TexCoordinate"),
            .attribute(.vector4, name: "a_DarkColor"),
        ])
        descriptor.vertexDescriptor.layouts[0].stride = MemoryLayout<SpineRenderVertex>.stride
        var attachment = RenderPipelineColorAttachmentDescriptor(format: .bgra8, isBlendingEnabled: true,
            sourceRGBBlendFactor: premultiplied ? .one : .sourceAlpha)
        switch blend {
        case .normal: break
        case .additive:
            attachment.destinationRGBBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one
        case .multiply:
            attachment.sourceRGBBlendFactor = .destinationColor
        case .screen:
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceColor
        }
        descriptor.colorAttachments = [attachment]
        descriptor.debugName = "Spine \(blend)"
        let pipeline = device.createRenderPipeline(from: descriptor)
        pipelines[key] = pipeline
        return pipeline
    }
}

@PlainSystem
struct PrepareSpineSystem {
    @Query<Camera, VisibleEntities> private var cameras
    @Res<ExtractedSpineDraws> private var extracted
    @Res<RenderDeviceHandler> private var device
    @ResMut<SpineRenderData> private var renderData
    @ResMut<RenderItems<Transparent2DRenderItem>> private var renderItems

    init(world _: World) {}

    func update(context _: UpdateContext) {
        var data = SpineRenderData()
        swap(&data, &renderData)
        data.vertices.elements.removeAll(keepingCapacity: true)
        data.indices.elements.removeAll(keepingCapacity: true)
        data.batches.removeAll(keepingCapacity: true)
        // Separate from sprites, particles and tilemaps. IDs only identify frame-local draw data.
        var renderID = Int.min / 4
        for character in extracted.characters {
            var isVisible = false
            cameras.forEach { _, visible in
                if visible.entityIds.contains(character.entity) { isVisible = true }
            }
            guard isVisible else { continue }
            for draw in character.draws {
                guard character.textures.indices.contains(draw.pageIndex), let texture = character.textures[draw.pageIndex],
                    !draw.indices.isEmpty, data.vertices.count <= Int(UInt32.max) - draw.vertices.count else { continue }
                let base = UInt32(data.vertices.count)
                for vertex in draw.vertices {
                    data.vertices.elements.append(SpineRenderVertex(
                        position: character.transform * Vector4(vertex.x, vertex.y, 0, 1),
                        light: Color(red: vertex.red, green: vertex.green, blue: vertex.blue, alpha: vertex.alpha),
                        uv: Vector2(vertex.u, vertex.v),
                        dark: Color(red: vertex.darkRed, green: vertex.darkGreen, blue: vertex.darkBlue, alpha: vertex.darkAlpha)
                    ))
                }
                let start = data.indices.count
                data.indices.elements.append(contentsOf: draw.indices.map { $0 + base })
                data.batches[renderID] = .init(owner: character.entity, texture: texture, indexRange: start..<data.indices.count)
                let pipeline = data.pipeline(for: draw, device: device.renderDevice)
                let item = Transparent2DRenderItem(entity: renderID, drawPass: SpineDrawPass(), renderPipeline: pipeline,
                                                   sortKey: character.transform.w.z)
                renderItems.items.append(item)
                renderID += 1
            }
            if let display = character.boneDisplay, display.width.isFinite, display.width > 0 {
                let start = data.indices.count
                for bone in character.bones where bone.isActive {
                    let a = Vector2(bone.x, bone.y)
                    let b = Vector2(bone.endX, bone.endY)
                    let delta = b - a
                    let length = Math.sqrt(delta.x * delta.x + delta.y * delta.y)
                    let normal = length > 0.001 ? Vector2(-delta.y, delta.x) * (display.width / (2 * length)) : Vector2(display.width / 2, 0)
                    let end = length > 0.001 ? b : a + Vector2(0, display.width)
                    let base = UInt32(data.vertices.count)
                    for point in [a - normal, a + normal, end + normal, end - normal] {
                        data.vertices.elements.append(SpineRenderVertex(
                            position: character.transform * Vector4(point.x, point.y, 0, 1), light: display.color,
                            uv: .zero, dark: Color(0, 0, 0, 0)))
                    }
                    data.indices.elements.append(contentsOf: [base, base + 1, base + 2, base, base + 2, base + 3])
                }
                if data.indices.count > start {
                    data.batches[renderID] = .init(owner: character.entity, texture: Texture2D.whiteTexture, indexRange: start..<data.indices.count)
                    let pipeline = data.pipeline(blend: .normal, premultiplied: false, device: device.renderDevice)
                    renderItems.items.append(Transparent2DRenderItem(entity: renderID, drawPass: SpineDrawPass(), renderPipeline: pipeline,
                                                                    sortKey: character.transform.w.z))
                    renderID += 1
                }
            }
        }
        if !data.vertices.isEmpty {
            data.vertices.write(to: device.renderDevice)
            data.indices.write(to: device.renderDevice)
        }
        swap(&data, &renderData)
    }
}

struct SpineDrawPass: DrawPass {
    func render(with encoder: RenderCommandEncoder, world: World, view: Entity, item: Transparent2DRenderItem) throws {
        guard let data = world.getResource(SpineRenderData.self), let batch = data.batches[item.entity],
              view.components[VisibleEntities.self]?.entityIds.contains(batch.owner) == true else { return }
        encoder.setRenderPipelineState(item.renderPipeline)
        encoder.setResourceSet(RenderResourceSet(bindings: [
            .init(binding: 0, shaderStages: .fragment, resource: .texture(batch.texture)),
            .init(binding: 1, shaderStages: .fragment, resource: .sampler(batch.texture.sampler)),
        ]), index: 0)
        encoder.setVertexBuffer(data.vertices, offset: 0, slot: 0)
        encoder.setIndexBuffer(data.indices, indexFormat: .uInt32)
        encoder.drawIndexed(indexCount: batch.indexRange.count,
                            indexBufferOffset: batch.indexRange.lowerBound * MemoryLayout<UInt32>.stride, instanceCount: 1)
    }
}
