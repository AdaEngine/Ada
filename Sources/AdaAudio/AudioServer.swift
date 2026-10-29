//
//  AudioServer.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/3/23.
//

import AdaECS
import AdaRender
import AdaUtils
import Foundation
import Math

enum AudioError: Error {
    case engineInitializationFailed
    case soundInitializationFailed
}

/// An instance that managed audio in the AdaEngine.
public final class AudioServer: Resource {
    nonisolated(unsafe) private static var defaultServer: AudioServer?

    /// The server belonging to the current offline recording, or the application server.
    public internal(set) static var shared: AudioServer! {
        get { unsafe offlineServer ?? defaultServer }
        set { unsafe defaultServer = newValue }
    }

    @TaskLocal package static var offlineServer: AudioServer?

    let engine: AudioEngine

    init(engine: AudioEngine) {
        self.engine = engine
    }

    /// Initializes audio without a playback device when the active or configured renderer is headless.
    @_spi(AdaEngine)
    @MainActor
    public static func initialize() throws {
        if offlineServer != nil { return }
        unsafe self.shared = AudioServer(engine: try makeEngine())
    }

    /// Prepares an independently owned preview with its own master gain and output lifetime.
    /// Headless rendering keeps preview output disabled, just like the shared server.
    @MainActor
    public static func preparePreview(from data: Data) throws -> AudioPlaybackController {
        let engine = try makeEngine()
        try engine.start()
        let resource = AudioResource(sound: try engine.makeSound(from: data))
        return try AudioPlaybackController(resource: resource)
    }

    @MainActor
    private static func makeEngine() throws -> MiniAudioEngine {
        // Keep decoding and playback APIs available without opening an output device.
        // The active backend takes precedence over configuration changed after startup.
        let backend = unsafe RenderEngine.shared?.type ?? RenderEngine.configurations.preferredBackend
        return try MiniAudioEngine(headless: backend == .headless)
    }

    func update(_ deltaTime: AdaUtils.TimeInterval) {
        self.engine.update(deltaTime)
    }

    /// Linear master gain applied to all audio. Negative values are clamped to zero.
    public var masterVolume: Float {
        get { engine.masterVolume }
        set { engine.masterVolume = max(0, newValue) }
    }

    public func start() throws {
        try self.engine.start()
    }

    public func stop() throws {
        try self.engine.stop()
    }

    // MARK: - Public

    /// Create an ``AudioPlaybackController`` instance which can be play in any time.
    /// - Note: You managed audio playback controller by yourself and be careful about memory leaks.
    public func prepareAudio(_ resource: AudioResource) -> AudioPlaybackController {
        do {
            return try AudioPlaybackController(resource: resource)
        } catch {
            fatalError("[AudioServer] Can't create sound from resource \(error)")
        }
    }

    /// Create a microphone capture session that records raw PCM audio.
    public func makeMicrophoneCapture(
        configuration: AudioCaptureConfiguration = .default
    ) throws -> AudioCaptureSession {
        try self.engine.makeMicrophoneCapture(configuration: configuration)
    }
}

/// Interface describes audio listener entity in spatial audio scene.
protocol AudioEngineListener: AnyObject, Sendable {
    var position: Vector3 { get set }
    var direction: Vector3 { get set }
    var velocity: Vector3 { get set }
    var worldUp: Vector3 { get set }

    var isEnabled: Bool { get set }

    func setCone(innerAngle: Angle, outerAngle: Angle, outerGain: Float)

    var innerAngle: Angle { get }
    var outerAngle: Angle { get }
    var outerGain: Float { get }
}

/// Events associated with audio playback.
public enum AudioEvents {
    /// Audio playback completed.
    public struct PlaybackCompleted: Event {
        /// The audio playback controller that triggered the event.
        public let playbackController: AudioPlaybackController
    }
}
