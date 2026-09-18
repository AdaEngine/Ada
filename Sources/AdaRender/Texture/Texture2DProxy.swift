//
//  Texture2DProxy.swift
//  AdaEngine
//
//  Created by Codex on 25.08.2026.
//

import AdaAssets
import Math
import Synchronization

/// A stable texture identity whose backing texture can be replaced safely.
///
/// Retained render data can keep this object while producers rotate through a
/// pool of GPU textures. Every source texture is expected to use compatible
/// dimensions and sampling settings until the surrounding render data is
/// rebuilt.
@_spi(Internal)
public final class Texture2DProxy: Texture2D, @unchecked Sendable {
    private let source: Mutex<Texture2D>

    public init(source: Texture2D) {
        let source = Self.flattenedSource(source)
        self.source = Mutex(source)
        super
            .init(
                gpuTexture: source.gpuTexture,
                sampler: source.sampler,
                size: source.size
            )
    }

    public func replaceSource(with source: Texture2D) {
        let source = Self.flattenedSource(source)
        self.source.withLock { currentSource in
            currentSource = source
        }
    }

    /// Proxy instances always store a concrete texture. This keeps property
    /// forwarding to one lock acquisition and prevents proxy cycles.
    private static func flattenedSource(_ source: Texture2D) -> Texture2D {
        (source as? Texture2DProxy)?.backingSource() ?? source
    }

    private func backingSource() -> Texture2D {
        source.withLock { $0 }
    }

    override public var width: Int {
        source.withLock(\.width)
    }

    override public var height: Int {
        source.withLock(\.height)
    }

    override public var sampler: Sampler {
        source.withLock(\.sampler)
    }

    @_spi(Internal)
    override public var gpuTexture: GPUTexture {
        source.withLock(\.gpuTexture)
    }

    override public var textureCoordinates: [Vector2] {
        get {
            source.withLock(\.textureCoordinates)
        }
        set {
            source.withLock { source in
                source.textureCoordinates = newValue
            }
        }
    }

    public required init(from assetDecoder: any AssetDecoder) async throws {
        let source = try await Texture2D(from: assetDecoder)
        self.source = Mutex(source)
        super
            .init(
                gpuTexture: source.gpuTexture,
                sampler: source.sampler,
                size: source.size
            )
    }
}
