//
//  AudioServer.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/3/23.
//

import AdaECS
import AdaUtils
import Foundation
import Math

enum AudioError: Error {
    case engineInitializationFailed
    case soundInitializationFailed
}

/// An instance that managed audio in the AdaEngine.
public final class AudioServer: Resource {
    nonisolated(unsafe) public internal(set) static var shared: AudioServer!

    let engine: AudioEngine

    init(engine: AudioEngine) {
        self.engine = engine
    }

    @_spi(AdaEngine)
    @MainActor
    public static func initialize() throws {
        let engine = try MiniAudioEngine()
        unsafe self.shared = AudioServer(engine: engine)
    }

    func update(_ deltaTime: AdaUtils.TimeInterval) {
        self.engine.update(deltaTime)
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
