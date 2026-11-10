@_spi(Internal) import AdaAssets
@_spi(Internal) import AdaRender
import AdaUtils
import Foundation
import Math
import Synchronization

extension ModelAsset3D {
    private struct TextureKey: Hashable { let index: Int; let sRGB: Bool }

    private struct ImportedTextureKey: Hashable {
        let data: Data
        let sRGB: Bool
        let sampler: SamplerDescriptor
        let device: ObjectIdentifier

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.device == rhs.device && lhs.sRGB == rhs.sRGB && lhs.sampler == rhs.sampler && lhs.data == rhs.data
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(device)
            hasher.combine(sRGB)
            hasher.combine(sampler.minFilter)
            hasher.combine(sampler.magFilter)
            hasher.combine(sampler.mipFilter)
            hasher.combine(sampler.addressModeU)
            hasher.combine(sampler.addressModeV)
            // Hash a bounded sample: hashing every byte of 4K PNGs costs seconds per scene.
            // Equality still compares the complete encoded contents.
            hasher.combine(data.count)
            unsafe data.withUnsafeBytes { bytes in
                let sample = 4096
                if bytes.count <= sample * 3 {
                    unsafe hasher.combine(bytes: bytes)
                    return
                }
                unsafe hasher.combine(bytes: UnsafeRawBufferPointer(rebasing: bytes[0 ..< sample]))
                let middle = bytes.count / 2 - sample / 2
                unsafe hasher.combine(bytes: UnsafeRawBufferPointer(rebasing: bytes[middle ..< middle + sample]))
                unsafe hasher.combine(bytes: UnsafeRawBufferPointer(rebasing: bytes[(bytes.count - sample)...]))
            }
        }
    }

    // Materials own the textures. The index never keeps an unused GPU allocation alive.
    // Compare encoded contents, not just URLs, so hot reload also sees edited images.
    private static let importedTextures = Mutex<[ImportedTextureKey: WeakBox<Texture2D>]>([:])

    static func makeMaterials(_ result: GLTFImportResult, if enabled: Bool) throws -> [Material]? {
        enabled ? try makeMaterials(result) : nil
    }

    static func makeMaterials(_ result: GLTFImportResult) throws -> [Material] {
        var accounted = result
        return try makeMaterialsAccounting(&accounted)
    }

    /// Mandatory textures reserve their staging cost before optional derived geometry is admitted.
    static func makeMaterialsAccounting(_ result: inout GLTFImportResult) throws -> [Material] {
        var textures: [TextureKey: Texture2D] = [:]
        var chargedTextures: Set<ImportedTextureKey> = []
        var remaining: Int?
        if let limits = ModelImportContext.limits {
            let geometryBytes = result.importFootprint?.decodedBytes ?? 0
            guard geometryBytes >= 0, geometryBytes <= limits.maximumDecodedBytes else { throw ModelImportLimitError.decodedBudgetExceeded }
            remaining = limits.maximumDecodedBytes - geometryBytes
        } else {
            remaining = nil
        }
        // Unbounded imports decode and mip all distinct textures in parallel up front. Bounded imports keep the
        // serial path so each texture is admitted by the decoded-byte budget before its pixels are decoded.
        let jobs = remaining == nil ? parallelTextureJobs(result) : []
        let prefetcher = jobs.isEmpty ? nil : TexturePrefetcher(jobs: jobs, lookahead: parallelTextureWindow)
        defer { prefetcher?.cancel() }
        func texture(_ index: Int?, sRGB: Bool) throws -> Texture2D? {
            guard let index else {
                return nil
            }
            let key = TextureKey(index: index, sRGB: sRGB)
            if let value = textures[key] {
                return value
            }
            guard result.textures.indices.contains(index) else { throw AssetError.message("Invalid texture index") }
            let source = result.textures[index]
            guard result.images.indices.contains(source.source), let data = result.images[source.source].data else {
                throw AssetError.message("Texture \(index) has no image data")
            }
            let input = source.sampler.flatMap { result.samplers.indices.contains($0) ? result.samplers[$0] : nil } ?? .init()
            let sampler = samplerDescriptor(input)
            let sharedKey = ImportedTextureKey(
                data: data,
                sRGB: sRGB,
                sampler: sampler,
                device: ObjectIdentifier(unsafe RenderEngine.shared.renderDevice)
            )
            if let available = remaining, chargedTextures.insert(sharedKey).inserted {
                let baseBytes = try Image.decodedImportByteCount(from: data)
                // Include decoded pixels, ImageMipmaps conversion arrays/Data, GPU pixels
                // and the alpha mask. Thin mip chains approach twice the base pixels;
                // six times the base covers their staging peak as well as retained resources.
                let factor = sampler.mipFilter == .notMipmapped ? 4 : 6
                guard baseBytes > 0, baseBytes <= available / factor else { throw ModelImportLimitError.decodedBudgetExceeded }
                remaining = available - baseBytes * factor
            }
            // Always consume a prefetched result so the bounded prefetcher can advance.
            let prefetched = try prefetcher?.take(key)
            if let value = importedTextures.withLock({ $0[sharedKey]?.value }) {
                textures[key] = value
                return value
            }
            let levels = try prefetched ?? decodeLevels(data, sRGB: sRGB, sampler: sampler)
            let image = levels[0]
            let uploadStall = PerformanceStallProbe.begin()
            defer { PerformanceStallProbe.end("Model.TextureUpload", since: uploadStall, bytes: levels.reduce(0) { $0 + $1.data.count }) }
            let value = Texture2D(
                descriptor: TextureDescriptor(
                    width: image.width,
                    height: image.height,
                    pixelFormat: .rgba8,
                    textureUsage: [.read],
                    textureType: .texture2D,
                    mipmapLevel: levels.count,
                    image: levels[0],
                    debugLabel: "glTF Texture \(index)",
                    samplerDescription: sampler
                )
            )
            for (level, mip) in levels.enumerated() where level > 0 {
                unsafe mip.data.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else {
                        return
                    }
                    unsafe value.replaceRegion(RectInt(x: 0, y: 0, width: mip.width, height: mip.height), mipmapLevel: level, withBytes: base, bytesPerRow: mip.width * 4)
                }
            }
            let shared = importedTextures.withLock { cache in
                if let existing = cache[sharedKey]?.value {
                    return existing
                }
                cache = cache.filter { $0.value.value != nil }
                cache[sharedKey] = WeakBox(value)
                return value
            }
            textures[key] = shared
            return shared
        }
        let materials: [Material] = try result.materials.map { source in
            let material = PBRMaterial()
            material.baseColorFactor = source.baseColorFactor
            material.metallicFactor = source.metallicFactor
            material.roughnessFactor = source.roughnessFactor
            material.normalScale = source.normalScale
            material.occlusionStrength = source.occlusionStrength
            material.emissiveFactor = source.emissiveFactor
            material.emissiveStrength = source.emissiveStrength
            material.alphaCutoff = source.alphaCutoff
            material.doubleSided = source.doubleSided
            material.textureCoordinates = source.textureCoordinates
            material.textureTransforms = source.textureTransforms.map {
                PBRTextureTransform(offset: $0.offset, rotation: $0.rotation, scale: $0.scale)
            }
            material.ior = source.ior
            material.specularFactor = source.specularFactor
            material.specularColorFactor = source.specularColorFactor
            material.clearcoatFactor = source.clearcoatFactor
            material.clearcoatRoughnessFactor = source.clearcoatRoughnessFactor
            material.sheenColorFactor = source.sheenColorFactor
            material.sheenRoughnessFactor = source.sheenRoughnessFactor
            material.anisotropyStrength = source.anisotropyStrength
            material.anisotropyRotation = source.anisotropyRotation
            switch source.alphaMode {
            case .opaque: material.alphaMode = .opaque
            case .mask: material.alphaMode = .mask
            case .blend: material.alphaMode = .blend
            }
            material.baseColorTexture = try texture(source.baseColorTextureIndex, sRGB: true)
            material.metallicRoughnessTexture = try texture(source.metallicRoughnessTextureIndex, sRGB: false)
            material.normalTexture = try texture(source.normalTextureIndex, sRGB: false)
            material.occlusionTexture = try texture(source.occlusionTextureIndex, sRGB: false)
            material.emissiveTexture = try texture(source.emissiveTextureIndex, sRGB: true)
            let layers = source.layerTextures
            let layerSources: [(PBRLayerTexture, GLTFImportResult.TextureReference?, Bool)] = [
                (.clearcoat, layers.clearcoat, false),
                (.clearcoatRoughness, layers.clearcoatRoughness, false),
                (.clearcoatNormal, layers.clearcoatNormal, false),
                (.sheenColor, layers.sheenColor, true),
                (.sheenRoughness, layers.sheenRoughness, false),
                (.anisotropy, layers.anisotropy, false),
                (.specular, layers.specular, false),
                (.specularColor, layers.specularColor, true),
            ]
            for (kind, reference, isSRGB) in layerSources {
                guard let reference, let value = try texture(reference.index, sRGB: isSRGB) else { continue }
                material.layerTextures[kind] = PBRTextureBinding(
                    texture: value,
                    texCoord: reference.texCoord,
                    transform: PBRTextureTransform(offset: reference.transform.offset, rotation: reference.transform.rotation, scale: reference.transform.scale),
                    scale: reference.scale
                )
            }
            return material
        }
        if let remaining, let limits = ModelImportContext.limits, let previous = result.importFootprint {
            result.importFootprint = .init(encodedBytes: previous.encodedBytes, decodedBytes: limits.maximumDecodedBytes - remaining)
        }
        return materials.isEmpty ? [PBRMaterial()] : materials
    }

    fileprivate static func decodeLevels(_ data: Data, sRGB: Bool, sampler: SamplerDescriptor) throws -> [Image] {
        let image = try Image.decode(from: data)
        return try ImageMipmaps.make(from: image, colorSpace: sRGB ? .sRGB : .linear, includeMipmaps: sampler.mipFilter != .notMipmapped)
    }

    private struct TextureJob: Sendable {
        let key: TextureKey
        let data: Data
        let sampler: SamplerDescriptor
    }

    /// Bounds transient memory: each 4K job holds a few hundred MiB of pixels until its texture is created.
    private static var parallelTextureWindow: Int { max(1, min(ProcessInfo.processInfo.activeProcessorCount - 2, 12)) }

    /// Bounds concurrent decodes across simultaneous imports (each import also bounds its own lookahead).
    private static let decodeSlots = DispatchSemaphore(value: parallelTextureWindow)

    /// Distinct material textures, in first-use order, that are not already shared by a live import.
    private static func parallelTextureJobs(_ result: GLTFImportResult) -> [TextureJob] {
        var keys: [TextureKey] = []
        var seen: Set<TextureKey> = []
        for source in result.materials {
            let layers = source.layerTextures
            let references: [(Int?, Bool)] = [
                (source.baseColorTextureIndex, true), (source.metallicRoughnessTextureIndex, false),
                (source.normalTextureIndex, false), (source.occlusionTextureIndex, false), (source.emissiveTextureIndex, true),
                (layers.clearcoat?.index, false), (layers.clearcoatRoughness?.index, false), (layers.clearcoatNormal?.index, false),
                (layers.sheenColor?.index, true), (layers.sheenRoughness?.index, false), (layers.anisotropy?.index, false),
                (layers.specular?.index, false), (layers.specularColor?.index, true),
            ]
            for case let (index?, sRGB) in references {
                let key = TextureKey(index: index, sRGB: sRGB)
                if seen.insert(key).inserted { keys.append(key) }
            }
        }
        // Texture-free imports must not touch the render engine; headless imports may have none.
        guard keys.count > 1 else { return [] }
        let device = ObjectIdentifier(unsafe RenderEngine.shared.renderDevice)
        let jobs: [TextureJob] = keys.compactMap { key in
            guard result.textures.indices.contains(key.index) else { return nil }
            let source = result.textures[key.index]
            guard result.images.indices.contains(source.source), let data = result.images[source.source].data else { return nil }
            let input = source.sampler.flatMap { result.samplers.indices.contains($0) ? result.samplers[$0] : nil } ?? .init()
            let sampler = samplerDescriptor(input)
            let shared = ImportedTextureKey(data: data, sRGB: key.sRGB, sampler: sampler, device: device)
            guard importedTextures.withLock({ $0[shared]?.value }) == nil else { return nil }
            return TextureJob(key: key, data: data, sampler: sampler)
        }
        return jobs.count > 1 ? jobs : []
    }

    /// Decodes and mips textures on background threads in first-use order, at most `lookahead` results ahead of
    /// the consumer, so CPU decoding overlaps the serial GPU uploads while transient memory stays bounded.
    /// Errors are kept per texture and rethrown where the serial material pass would have thrown them.
    private final class TexturePrefetcher: @unchecked Sendable {
        // `condition` guards `results` and `cancelled`; `slots` bounds decoded-but-unconsumed results.
        private let jobs: [TextureJob]
        private let positions: [TextureKey: Int]
        private let condition = NSCondition()
        private let slots: DispatchSemaphore
        private var results: [Int: Result<[Image], any Error>] = [:]
        private var cancelled = false

        init(jobs: [TextureJob], lookahead: Int) {
            self.jobs = jobs
            self.positions = Dictionary(jobs.enumerated().map { ($1.key, $0) }, uniquingKeysWith: { first, _ in first })
            self.slots = DispatchSemaphore(value: lookahead)
            let workers = DispatchQueue(label: "org.adaengine.model-texture-decode", attributes: .concurrent)
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                for position in jobs.indices {
                    slots.wait()
                    if isCancelled { return }
                    workers.async { [self] in
                        let job = jobs[position]
                        ModelAsset3D.decodeSlots.wait()
                        let decoded = isCancelled ? .failure(CancellationError())
                            : Result { try ModelAsset3D.decodeLevels(job.data, sRGB: job.key.sRGB, sampler: job.sampler) }
                        ModelAsset3D.decodeSlots.signal()
                        condition.lock()
                        results[position] = decoded
                        condition.broadcast()
                        condition.unlock()
                    }
                }
            }
        }

        private var isCancelled: Bool {
            condition.lock()
            defer { condition.unlock() }
            return cancelled
        }

        /// Blocks until the texture is decoded. Returns nil for textures that are not prefetched.
        func take(_ key: TextureKey) throws -> [Image]? {
            guard let position = positions[key] else { return nil }
            condition.lock()
            while results[position] == nil { condition.wait() }
            let result = results.removeValue(forKey: position)
            condition.unlock()
            slots.signal()
            return try result?.get()
        }

        /// Stops scheduling further work and releases pending results; in-flight decodes finish and are dropped.
        func cancel() {
            condition.lock()
            cancelled = true
            results.removeAll()
            condition.unlock()
            for _ in jobs.indices { slots.signal() }
        }
    }

    private static func samplerDescriptor(_ source: GLTFImportResult.Sampler) -> SamplerDescriptor {
        func address(_ value: Int) -> SamplerAddressMode {
            switch value {
            case 10497: return .repeat
            case 33648: return .mirroredRepeat
            default: return .clampToEdge
            }
        }
        let minFilter: SamplerMinMagFilter = [9728, 9984, 9986].contains(source.minFilter) ? .nearest : .linear
        let mip: SamplerMipFilter =
            switch source.minFilter {
            case 9728, 9729: .notMipmapped
            case 9984, 9985: .nearest
            default: .linear
            }
        return SamplerDescriptor(
            minFilter: minFilter,
            magFilter: source.magFilter == 9728 ? .nearest : .linear,
            mipFilter: mip,
            addressModeU: address(source.wrapS),
            addressModeV: address(source.wrapT)
        )
    }
}
