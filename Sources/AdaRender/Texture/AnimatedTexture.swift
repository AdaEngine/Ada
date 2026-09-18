//
//  AnimatedTexture.swift
//  AdaEngine
//
//  Created by v.prusakov on 7/3/22.
//

import AdaAssets
import AdaUtils
import Foundation
import Math

// TODO: Make encoding/decoding for scene serialization

/// Animated texture is represents a frame-based animations, where multiple textures can be chained with a predifined delay for each frame.
/// This kind of textures can apply any 2D Textures to animate them.
public final class AnimatedTexture: Texture2D, @unchecked Sendable {
    struct Frame {
        var texture: Texture2D?
        var delay: AdaUtils.TimeInterval
    }

    /// Contains information about frames
    private var frames: [Frame]

    /// Contains ref to subscription of event
    private var mainLoopToken: Cancellable?

    public var framesCount: Int = 1

    private var _currentFrame: Int = 0

    /// Current played frame.
    public var currentFrame: Int {
        get {
            return self._currentFrame
        }

        set {
            assert(self.framesCount >= newValue || newValue < 0)
            self._currentFrame = newValue
        }
    }

    /// Indicates how much frames will animated per second.
    @InRange(1..<1000)
    public var framesPerSecond: Float = 4.0

    /// Indicates that animation on pause.
    public var isPaused: Bool = false

    /// Include options for texture. By default contains `repeat` animation.
    public var options: Options = [.repeat]

    /// Return RID of current frame
    @_spi(Internal) override public var gpuTexture: GPUTexture {
        currentTexture.gpuTexture
    }

    /// Return texture coordinates of current frame.
    override public var textureCoordinates: [Vector2] {
        get {
            return currentTexture.textureCoordinates
        }
        // swiftlint:disable:next unused_setter_value
        set {
            fatalError("You cannot set texture coordinates for animated texture.")
        }
    }

    /// Return width of the current frame.
    override public var width: Int {
        return currentTexture.width
    }

    /// Return height of the current frame.
    override public var height: Int {
        return currentTexture.height
    }

    override public var sampler: Sampler {
        return currentTexture.sampler
    }

    private var currentTexture: Texture2D {
        frames[currentFrame].texture.unwrap(message: "Animated texture frame \(currentFrame) has no texture.")
    }

    /// Create animated texture with 256 frames.
    public init() {
        self.frames = [Frame].init(repeating: Frame(texture: nil, delay: 0), count: 256)
        let sampler = unsafe RenderEngine.shared.renderDevice.createSampler(from: SamplerDescriptor())
        let texture = unsafe RenderEngine.shared.renderDevice.createTexture(
            from: TextureDescriptor(
                textureUsage: .read,
                textureType: .texture2D
            )
        )
        super.init(gpuTexture: texture, sampler: sampler, size: .zero)
        self.mainLoopToken = EventManager.default.subscribe(
            to: EngineEvents.MainLoopBegan.self,
            completion: update(_:)
        )
    }

    // MARK: - Resources

    struct AssetRepresentation: Codable {
        struct Frame: Codable {
            let texture: AssetHandle<Texture2D>  // FIXME: (Vlad) resource id/path
            let delay: AdaUtils.TimeInterval
        }

        let frames: [Frame]
        let fps: Float
        let framesCount: Int
        let options: Options
    }

    public required convenience init(from decoder: AssetDecoder) async throws {
        guard Self.extensions().contains(where: { decoder.assetMeta.filePath.pathExtension == $0 }) else {
            throw AssetDecodingError.invalidAssetExtension(decoder.assetMeta.filePath.pathExtension)
        }

        let asset = try decoder.decode(AssetRepresentation.self)

        self.init()

        self.framesCount = asset.framesCount
        self.framesPerSecond = asset.fps
        self.options = asset.options

        for (frameIndex, frame) in asset.frames.enumerated() {
            self.setTexture(frame.texture.asset, for: frameIndex)
            self.setDelay(frame.delay, for: frameIndex)
        }
    }

    override public func encodeContents(with encoder: any AssetEncoder) async throws {
        guard var container = encoder.encoder?.singleValueContainer() else {
            return
        }

        var frames: [AssetRepresentation.Frame] = []

        for index in 0..<self.framesCount {
            let frame = self.frames[index]
            guard let texture = frame.texture else {
                continue
            }

            let item = AssetRepresentation.Frame(
                texture: AssetHandle(texture),
                delay: frame.delay
            )

            frames.append(item)
        }

        let asset = AssetRepresentation(
            frames: frames,
            fps: self.framesPerSecond,
            framesCount: self.framesCount,
            options: self.options
        )

        try container.encode(asset)
    }

    public func update(_ newAnimatedTexture: AnimatedTexture) async throws {
        self.frames = newAnimatedTexture.frames
        self.framesCount = newAnimatedTexture.framesCount
        self.framesPerSecond = newAnimatedTexture.framesPerSecond
        self.options = newAnimatedTexture.options
    }

    // MARK: - Public methods

    public subscript(_ frame: Int) -> Texture2D? {
        get {
            return self.getTexture(for: frame)
        }

        set {
            self.setTexture(newValue, for: frame)
        }
    }

    public func setTexture(_ texture: Texture2D?, for frame: Int) {
        self.frames[frame].texture = texture
    }

    public func getTexture(for frame: Int) -> Texture2D? {
        return self.frames[frame].texture
    }

    public func setDelay(_ delay: AdaUtils.TimeInterval, for frame: Int) {
        self.frames[frame].delay = delay
    }

    public func getDelay(for frame: Int) -> AdaUtils.TimeInterval {
        return self.frames[frame].delay
    }

    // MARK: - Private

    // FIXME: After breakpoint can increase animation speed.
    private var time: AdaUtils.TimeInterval = 0

    /// Called each frame to update current frame.
    private func update(_ event: EngineEvents.MainLoopBegan) {
        if self.isPaused {
            return
        }

        // Avoid bug when we play animation very fast, because we need to fit to frames per second rate
        if event.deltaTime > 1 {
            return
        }

        self.time += event.deltaTime

        let limit: AdaUtils.TimeInterval = AdaUtils.TimeInterval(self.framesPerSecond != 0 ? 1 / self.framesPerSecond : 0)
        let frameTime = limit + self.frames[self.currentFrame].delay

        if self.time > frameTime {
            self.currentFrame += 1

            if self.currentFrame >= self.framesCount {
                if !self.options.contains(.repeat) {
                    self.currentFrame = self.framesCount - 1
                    self.isPaused = true
                } else {
                    self.currentFrame = 0
                }
            }

            self.time -= frameTime
        }
    }
}

extension AnimatedTexture {
    public struct Options: OptionSet, Codable, Sendable {
        public var rawValue: UInt8

        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }

        /// Repeats animation forever.
        public static let `repeat` = Self(rawValue: 1 << 0)
    }
}
