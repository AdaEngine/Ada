//
//  Clouds3DNoise.swift
//  AdaEngine
//

import AdaAssets
import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math

/// Layout of the procedural noise atlases. 3D noise is stored as a grid of 2D slices.
enum Clouds3DNoiseLayout {
    struct Atlas: Equatable, Sendable {
        var tile: Int
        var columns: Int
        var slices: Int

        var size: SizeInt {
            SizeInt(width: tile * columns, height: tile * ((slices + columns - 1) / columns))
        }
    }

    /// Shape noise: 64 slices of 64 by 64 texels in an 8 by 8 grid. Channels hold Perlin-Worley and three Worley octaves.
    static let shape = Atlas(tile: 64, columns: 8, slices: 64)
    /// Detail noise: 32 slices of 32 by 32 texels in an 8 by 4 grid. Channels hold three Worley octaves.
    static let detail = Atlas(tile: 32, columns: 8, slices: 32)
    /// Weather map: one 256 by 256 slice. Channels hold coverage, cloud type and a mid-frequency Worley pattern.
    static let weather = Atlas(tile: 256, columns: 1, slices: 1)

    /// The textures are `bgra8`: four bytes per texel.
    static let bytesPerTexel = 4

    static var memoryBytes: Int {
        [shape, detail, weather].reduce(0) { $0 + $1.size.width * $1.size.height * bytesPerTexel }
    }
}

/// Uniform block of the noise passes. Mirrors `CloudNoiseUniform` in `clouds_noise_common.wgsl`.
struct CloudNoiseUniform: Sendable {
    /// x and y: the low and high 16 bits of the mixed seed, each exactly representable as a `Float`.
    var seed: Vector4
    /// x: tile size in texels, y: tiles per row, z: slice count.
    var size: Vector4

    init(seed: UInt32, atlas: Clouds3DNoiseLayout.Atlas) {
        let mixed = Self.mix(seed)
        self.seed = Vector4(Float(mixed & 0xFFFF), Float(mixed >> 16), 0, 0)
        size = Vector4(Float(atlas.tile), Float(atlas.columns), Float(atlas.slices), 0)
    }

    /// A bijective integer mix, so neighbouring seeds give unrelated noise and seed 0 is as good as any other.
    static func mix(_ seed: UInt32) -> UInt32 {
        var value = seed &+ 0x9E37_79B9
        value = (value ^ (value >> 16)) &* 0x85EB_CA6B
        value = (value ^ (value >> 13)) &* 0xC2B2_AE35
        return value ^ (value >> 16)
    }
}

/// The three noise textures for one seed.
struct Clouds3DNoiseTextures {
    let shape: RenderTexture
    let detail: RenderTexture
    let weather: RenderTexture
}

/// Procedural noise textures, generated on first use for each seed and shared by every camera. At most a few seeds are
/// held; the least recently used one is dropped, and a camera that stops using clouds holds nothing.
struct Clouds3DNoiseCache {
    private struct Entry {
        var textures: Clouds3DNoiseTextures
        var built = false
        var lastUse: Int
    }

    static let capacity = 4

    private var entries: [UInt32: Entry] = [:]
    private var retired: [(texture: RenderTexture, age: Int)] = []
    private var clock = 0

    var seedCount: Int { entries.count }

    /// Bytes the held noise textures occupy on the GPU.
    var memoryBytes: Int { entries.count * Clouds3DNoiseLayout.memoryBytes }

    func textures(seed: UInt32) -> Clouds3DNoiseTextures? { entries[seed]?.textures }

    /// The textures for `seed`, created on first use.
    mutating func textures(forSeed seed: UInt32) -> Clouds3DNoiseTextures {
        clock += 1
        if var existing = entries[seed] {
            existing.lastUse = clock
            entries[seed] = existing
            return existing.textures
        }
        func texture(_ atlas: Clouds3DNoiseLayout.Atlas, _ label: String) -> RenderTexture {
            RenderTexture(size: atlas.size, scaleFactor: 1, format: .bgra8, debugLabel: label)
        }
        let textures = Clouds3DNoiseTextures(
            shape: texture(Clouds3DNoiseLayout.shape, "Cloud Shape Noise"),
            detail: texture(Clouds3DNoiseLayout.detail, "Cloud Detail Noise"),
            weather: texture(Clouds3DNoiseLayout.weather, "Cloud Weather Map")
        )
        entries[seed] = Entry(textures: textures, lastUse: clock)
        // Keep the newest seeds; frames in flight may still read the dropped textures, so retire them for a while.
        while entries.count > Self.capacity, let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            retire(entries.removeValue(forKey: oldest))
        }
        return textures
    }

    private mutating func retire(_ entry: Entry?) {
        guard let entry else {
            return
        }
        retired.append(contentsOf: [entry.textures.shape, entry.textures.detail, entry.textures.weather].map { ($0, 0) })
    }

    /// Textures retired more than a frame-in-flight ago are released.
    mutating func advanceFrame() {
        let limit = max(1, unsafe RenderEngine.configurations.maxFramesInFlight) + 1
        retired = retired.map { ($0.texture, $0.age + 1) }.filter { $0.age <= limit }
    }

    var retiredCount: Int { retired.count }

    /// Whether the noise for `seed` still has to be generated, recording that it was. True once per seed.
    mutating func claimBuild(seed: UInt32) -> Bool {
        guard var entry = entries[seed], !entry.built else {
            return false
        }
        entry.built = true
        entries[seed] = entry
        return true
    }

    /// Drops every seed not in `seeds`.
    mutating func retain(seeds: Set<UInt32>) {
        for seed in entries.keys where !seeds.contains(seed) {
            retire(entries.removeValue(forKey: seed))
        }
    }
}

/// The pipelines that fill the noise textures.
struct Clouds3DNoisePipelines: Resource {
    let shape: RenderPipeline
    let detail: RenderPipeline
    let weather: RenderPipeline

    init(device: RenderDevice) {
        func pipeline(_ name: String) -> RenderPipeline {
            let shader = CorePipelineShaders.loadRequiredBuiltin("clouds_noise_\(name)_3d")
            var descriptor = RenderPipelineDescriptor(
                vertex: shader.asset.requiredShader(for: .vertex),
                fragment: shader.asset.getShader(for: .fragment),
                debugName: "Cloud noise \(name)",
                backfaceCulling: false,
                depthPixelFormat: .none
            )
            descriptor.colorAttachments = [.init(format: .bgra8)]
            return device.createRenderPipeline(from: descriptor)
        }
        shape = pipeline("shape")
        detail = pipeline("detail")
        weather = pipeline("weather")
    }

    /// Records the three noise passes for `seed` into `command`.
    func encode(seed: UInt32, into textures: Clouds3DNoiseTextures, command: CommandBuffer, device: RenderDevice) {
        let passes: [(RenderPipeline, RenderTexture, Clouds3DNoiseLayout.Atlas, String)] = [
            (shape, textures.shape, Clouds3DNoiseLayout.shape, "Cloud Shape Noise"),
            (detail, textures.detail, Clouds3DNoiseLayout.detail, "Cloud Detail Noise"),
            (weather, textures.weather, Clouds3DNoiseLayout.weather, "Cloud Weather Map"),
        ]
        for (pipeline, target, atlas, label) in passes {
            let uniform = device.createUniformBuffer(CloudNoiseUniform.self, binding: 4)
            uniform.setData(CloudNoiseUniform(seed: seed, atlas: atlas))
            let pass = command.beginRenderPass(RenderPassDescriptor(
                label: label,
                colorAttachments: [.init(texture: target, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .black)],
                depthStencilAttachment: nil
            ))
            pass.setViewport(Rect(x: 0, y: 0, width: Float(target.size.width), height: Float(target.size.height)))
            pass.setRenderPipelineState(pipeline)
            pass.setFragmentBuffer(uniform, offset: 0, slot: 4)
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            pass.endRenderPass()
        }
    }
}
