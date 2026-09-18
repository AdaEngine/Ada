//
//  AudioPlaybackController.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/6/23.
//

import AdaECS
import AdaUtils

/// A controller that manages audio playback of a resource.
///
/// You receive an audio playback controller by calling an entity’s ``Entity/prepareAudio(_:)`` method.
/// You typically pass an ``AudioResource`` instance to this call that tells the playback controller how to stream the contents of an audio file.
public struct AudioPlaybackController: @unchecked Sendable {
    /// The resource that provides the audio stream.
    public let resource: AudioResource

    let sound: Sound

    /// The entity from which the audio stream emanates.
    public internal(set) weak var entity: Entity?

    init(resource: AudioResource) throws {
        self.resource = resource
        self.sound = try resource.getSound()
    }

    /// A Boolean that indicates whether playback is currently active.
    public var isPlaying: Bool {
        return self.sound.state == .playing
    }

    /// The volume of the audio resource.
    ///
    /// The volume is a value between 0.0 and 1.0, where 0.0 is the lowest volume and 1.0 is the highest volume.
    /// The default volume is 1.0.
    public var volume: Float {
        get {
            self.sound.volume
        }

        nonmutating set {
            self.sound.volume = newValue
        }
    }

    /// A Boolean you set to indicate whether the resource loops during playback.
    ///
    /// Set this value to true to tell the associated ``AudioPlaybackController`` instance to loop playback indefinitely.
    /// This lets you create ambient sound that never ends, for example.
    @discardableResult
    public func setLoop(_ isLooping: Bool) -> Self {
        self.sound.isLooping = isLooping
        return self
    }

    /// Plays the audio resource.
    public func play() {
        self.sound.start()
    }

    /// Pauses playback of the audio resource while maintaining the position in the audio stream.
    public func pause() {
        self.sound.pause()
    }

    /// Stops playback of the audio resource and discards the location in the audio stream.
    public func stop() {
        self.sound.stop()
    }

    /// A closure that the playback controller executes when it comes to the end of the audio stream.
    @discardableResult
    public func onCompleteHandler(_ block: @escaping () -> Void) -> Self {
        self.sound.onCompleteHandler {
            EventManager.default.send(AudioEvents.PlaybackCompleted(playbackController: self))
            block()
        }
        return self
    }

    /// Set the volume for the sound.
    @discardableResult
    public func setVolume(_ volume: Float) -> Self {
        self.volume = volume
        return self
    }
}
