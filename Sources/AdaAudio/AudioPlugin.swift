//
//  AudioPlugin.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/6/23.
//

import AdaApp
import AdaECS
import AdaTransform
import AdaUtils
import Logging

/// A plugin that adds audio capabilities to the world.
public struct AudioPlugin: Plugin {
    private let logger = Logger(label: "org.adaengine.audioplugin")

    public init() {}

    public func setup(in app: borrowing AppWorlds) {
        do {
            try AudioServer.initialize()
            unsafe try AudioServer.shared.engine.start()
            AudioComponent.registerComponent()
            AudioReceiver.registerComponent()
            AudioPlaybacksControllers.registerComponent()

            let audioServer = unsafe AudioServer.shared.unwrap(message: "AudioServer did not initialize its shared instance.")
            app
                .insertResource(audioServer)
                .addSystem(AudioSystem.self)
        } catch {
            logger.error("Failed to setup AudioPlugin with error: \(error)")
        }
    }

    public func destroy(for _: borrowing AppWorlds) {
        do {
            unsafe try AudioServer.shared.stop()
        } catch {
            logger.error("Failed to destroy AudioServer with error: \(error)")
        }
    }
}

/// A component that holds an ``AudioPlaybackController`` for an audio resource.
///
/// Use this component to play audio on an entity.
///
/// - Note: Audio component will be automatically freed when entity is removed from memory and nobody own a reference to the playback controller.
///
/// When you create an audio playback controller engine will automatically update position for spatial audio.
@Component
public struct AudioComponent {
    /// The playback controller for the audio component.
    public let playbackController: AudioPlaybackController

    /// Creates a new audio component with the specified audio resource.
    ///
    /// - Parameter resource: The audio resource to play.
    public init(resource: AudioResource) {
        self.playbackController = unsafe AudioServer.shared.prepareAudio(resource)
    }
}

/// AudioReceiver should be used for spatial audio.
@Component
public struct AudioReceiver {
    internal var audioListener: AudioEngineListener?

    public init() {}

    /// A Boolean that indicates whether the audio receiver is enabled.
    ///
    /// Set this value to false to disable the audio receiver.
    public var isEnabled: Bool {
        get {
            audioListener?.isEnabled ?? false
        }

        set {
            audioListener?.isEnabled = newValue
        }
    }
}

/// A system that manages audio resources for spatial audio.
@PlainSystem
public struct AudioSystem {
    @Query<AudioPlaybacksControllers, Transform>
    private var audioPlaybacksControllersQuery

    @Query<Ref<AudioReceiver>, Transform>
    private var audioReceiverQuery

    @Res<AudioServer>
    private var audioServer

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        self.audioPlaybacksControllersQuery.forEach { audioComponent, transform in
            audioComponent.controllers.forEach { controller in
                controller.sound.position = transform.position
            }
        }

        self.audioReceiverQuery.forEach { audioReceiver, transform in
            if let listener = audioReceiver.audioListener, listener.position != transform.position {
                listener.position = transform.position
            } else {
                audioReceiver.audioListener = audioServer.engine.getAudioListener(at: 0)
            }
        }
    }
}

/// Holds ``AudioPlaybackController`` to control their lifetimes
@Component
public struct AudioPlaybacksControllers {
    /// The playback controllers for the audio playback controllers.
    public var controllers: [AudioPlaybackController] = []
}

extension Entity {
    /// Create a new ``AudioPlaybackController`` for audio resource or returns existings once if ``AudioResource`` being used earlier for this entity.
    ///
    /// - Note: Audio controller will be automatically freed when entity is removed from memory and nobody own a reference to the playback controller.
    ///
    /// When you create an audio playback controller engine will automatically update position for spatial audio.
    @MainActor
    public func prepareAudio(_ resource: AudioResource) -> AudioPlaybackController {
        var controllers = self.components[AudioPlaybacksControllers.self] ?? AudioPlaybacksControllers()
        if let controller = controllers.controllers.first(where: { $0.resource === resource }) {
            return controller
        }

        var playbackController = unsafe AudioServer.shared.prepareAudio(resource)
        playbackController.entity = self
        controllers.controllers.append(playbackController)
        self.components += controllers

        return playbackController
    }

    /// Plays sound from an audio resource on this entity.
    ///
    /// An ``AudioPlaybackController`` instance that you use to manage audio playback.
    /// Use the controller to set playback characteristics like volume and reverb, and then start or stop playback.
    ///
    /// This method first prepares the audio by calling ``Entity/prepareAudio(_:)``, and then immediately calls the ``AudioPlaybackController/play()`` method on the returned controller.
    @MainActor
    @discardableResult
    public func playAudio(_ resource: AudioResource) -> AudioPlaybackController {
        let controller = self.prepareAudio(resource)
        controller.play()
        return controller
    }

    /// Stops audio playback.
    ///
    /// You can stop a specific ``AudioPlaybackController`` instance from playing a particular resource
    /// by calling the controller’s ``AudioPlaybackController/stop()`` method.
    /// To stop all controllers associated with a particular Entity instance with a single call, use the ``Entity/stopAllAudio()`` method instead.
    @MainActor
    public func stopAllAudio() {
        self.components[AudioPlaybacksControllers.self]?.controllers.forEach { $0.stop() }
        self.components += AudioPlaybacksControllers()
    }
}
