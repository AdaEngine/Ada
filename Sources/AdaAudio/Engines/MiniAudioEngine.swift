//
//  MiniAudioEngine.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/6/23.
//

import AdaECS
import AdaUtils
import Foundation
import Math
import miniaudio

enum MAError: LocalizedError {
    case failed(String, ma_result)

    var errorDescription: String? {
        switch self {
        case let .failed(string, result):
            "[MiniAudioEngine] Code: \(result) Error: \(string)"
        }
    }
}

@safe
struct MiniAudioEngine: AudioEngine, @unchecked Sendable {
    static func getFromWorld(_ world: borrowing AdaECS.World) -> Self? {
        world.getResource(Self.self)
    }

    @unsafe
    private final class Engine {
        var enginePtr: UnsafeMutablePointer<ma_engine> = unsafe .allocate(
            capacity: MemoryLayout.size(ofValue: ma_engine.self)
        )

        init() throws {
            var config = unsafe ma_engine_config_init()
            unsafe config.channels = 2
            #if WASM
                unsafe config.noDevice = ma_bool32(MA_TRUE)
                unsafe config.sampleRate = 48_000
            #endif
            let result = unsafe ma_engine_init(&config, enginePtr)
            if result != MA_SUCCESS {
                throw AudioError.engineInitializationFailed
            }
        }

        deinit {
            unsafe ma_engine_uninit(enginePtr)
        }
    }

    private let engine: Engine

    init() throws {
        unsafe self.engine = try Engine()
    }

    // MARK: - AudioEngine

    func start() throws {
        #if WASM
            return
        #else
            let result = unsafe ma_engine_start(engine.enginePtr)
            if result != MA_SUCCESS {
                throw MAError.failed("Failed to start", result)
            }
        #endif
    }

    func stop() throws {
        #if WASM
            return
        #else
            let result = unsafe ma_engine_stop(engine.enginePtr)
            if result != MA_SUCCESS {
                throw MAError.failed("Failed to stop", result)
            }
        #endif
    }

    func update(_: AdaUtils.TimeInterval) {}

    func makeSound(from url: URL) throws -> Sound {
        unsafe try MiniSound(from: url, engine: engine.enginePtr)
    }

    func makeSound(from data: Data) throws -> Sound {
        unsafe try MiniSound(from: data, engine: engine.enginePtr)
    }

    func makeMicrophoneCapture(configuration: AudioCaptureConfiguration) throws -> AudioCaptureSession {
        #if WASM
            throw AudioCaptureError.unsupported
        #else
            try AudioCaptureSession(backend: MiniAudioCaptureSession(configuration: configuration))
        #endif
    }

    func getAudioListener(at index: Int) -> AudioEngineListener {
        if unsafe index > ma_engine_get_listener_count(engine.enginePtr) - 1 {
            fatalError("[MiniAudioEngine] Listener not found")
        }

        return unsafe MiniAudioEngineListener(engine: engine.enginePtr, listenerIndex: UInt32(index))
    }
}

// MARK: - MiniAudioEngineListener -

@unsafe
final class MiniAudioEngineListener: AudioEngineListener, @unchecked Sendable {
    private let engine: UnsafeMutablePointer<ma_engine>
    let listenerIndex: UInt32

    init(engine: UnsafeMutablePointer<ma_engine>, listenerIndex: UInt32) {
        unsafe self.engine = engine
        unsafe self.listenerIndex = listenerIndex
    }

    var position: Vector3 {
        get {
            let position = unsafe ma_engine_listener_get_position(engine, self.listenerIndex)
            return [position.x, position.y, position.z]
        }

        set {
            unsafe ma_engine_listener_set_position(engine, listenerIndex, newValue.x, newValue.y, newValue.z)
        }
    }

    var direction: Vector3 {
        get {
            let position = unsafe ma_engine_listener_get_direction(engine, listenerIndex)
            return [position.x, position.y, position.z]
        }

        set {
            unsafe ma_engine_listener_set_direction(engine, listenerIndex, newValue.x, newValue.y, newValue.z)
        }
    }

    var velocity: Vector3 {
        get {
            let position = unsafe ma_engine_listener_get_velocity(engine, listenerIndex)
            return [position.x, position.y, position.z]
        }

        set {
            unsafe ma_engine_listener_set_velocity(engine, listenerIndex, newValue.x, newValue.y, newValue.z)
        }
    }

    var isEnabled: Bool {
        get {
            return unsafe ma_engine_listener_is_enabled(engine, listenerIndex) == 1
        }

        set {
            unsafe ma_engine_listener_set_enabled(engine, listenerIndex, newValue ? 1 : 0)
        }
    }

    var worldUp: Vector3 {
        get {
            let position = unsafe ma_engine_listener_get_world_up(engine, listenerIndex)
            return [position.x, position.y, position.z]
        }

        set {
            unsafe ma_engine_listener_set_world_up(engine, listenerIndex, newValue.x, newValue.y, newValue.z)
        }
    }

    func setCone(innerAngle: Angle, outerAngle: Angle, outerGain: Float) {
        unsafe ma_engine_listener_set_cone(engine, listenerIndex, innerAngle.radians, outerAngle.radians, outerGain)
    }

    var innerAngle: Angle {
        var radians: Float = 0
        unsafe ma_engine_listener_get_cone(engine, listenerIndex, &radians, nil, nil)

        return .radians(radians)
    }

    var outerAngle: Angle {
        var radians: Float = 0
        unsafe ma_engine_listener_get_cone(engine, listenerIndex, nil, &radians, nil)

        return .radians(radians)
    }

    var outerGain: Float {
        var gain: Float = 0
        unsafe ma_engine_listener_get_cone(engine, listenerIndex, nil, nil, &gain)
        return gain
    }
}

// MARK: - Sound -

@unsafe
final class MiniSound: Sound {
    private(set) var state: SoundState = .ready

    private var completionHandler: (() -> Void)?

    private var sound: UnsafeMutablePointer<ma_sound>? = unsafe .allocate(capacity: MemoryLayout.size(ofValue: ma_sound.self))

    init(from fileURL: URL, engine: UnsafeMutablePointer<ma_engine>!) throws {
        let flags = MA_SOUND_FLAG_DECODE.rawValue | MA_SOUND_FLAG_NO_SPATIALIZATION.rawValue
        let result = unsafe fileURL.path.withCString { pFilePath in
            unsafe ma_sound_init_from_file(engine, pFilePath, UInt32(flags), nil, nil, sound)
        }
        if result != MA_SUCCESS {
            throw AudioError.soundInitializationFailed
        }
    }

    init(from data: Data, engine: UnsafeMutablePointer<ma_engine>!) throws {
        var data = data
        let flags = MA_SOUND_FLAG_DECODE.rawValue | MA_SOUND_FLAG_NO_SPATIALIZATION.rawValue
        let result = unsafe data.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else {
                return MA_INVALID_ARGS
            }
            return unsafe ma_sound_init_from_data_source(engine, baseAddress, UInt32(flags), nil, sound)
        }

        if result != MA_SUCCESS {
            throw AudioError.soundInitializationFailed
        }
    }

    private init(prototype: MiniSound) throws {
        let engine = unsafe ma_sound_get_engine(prototype.sound)
        let result = unsafe ma_sound_init_copy(engine, prototype.sound, 0, nil, sound)

        if result != MA_SUCCESS {
            throw AudioError.soundInitializationFailed
        }
    }

    deinit {
        unsafe ma_sound_uninit(sound)
    }

    func copy() throws -> Sound {
        return unsafe try MiniSound(prototype: self)
    }

    func update(_: AdaUtils.TimeInterval) {
    }

    var volume: Float {
        get {
            unsafe ma_sound_get_volume(sound)
        }

        set {
            unsafe ma_sound_set_volume(sound, newValue)
        }
    }

    var pitch: Float {
        get {
            unsafe ma_sound_get_pitch(sound)
        }

        set {
            unsafe ma_sound_set_pitch(sound, newValue)
        }
    }

    var position: Vector3 {
        get {
            let position = unsafe ma_sound_get_position(sound)
            return [position.x, position.y, position.z]
        }
        set {
            unsafe ma_sound_set_position(sound, newValue.x, newValue.y, newValue.z)
        }
    }

    var isLooping: Bool {
        get {
            return unsafe ma_sound_is_looping(sound) == 1
        }

        set {
            unsafe ma_sound_set_looping(sound, newValue ? 1 : 0)
        }
    }

    func start() {
        unsafe self.state = .playing
        unsafe ma_sound_start(sound)
    }

    func stop() {
        unsafe self.state = .stopped
        unsafe self.stop(resetPlaybackPosition: true, notifyCallback: false)
    }

    func pause() {
        unsafe self.state = .paused
        unsafe self.stop(resetPlaybackPosition: false, notifyCallback: false)
    }

    func onCompleteHandler(_ block: @escaping () -> Void) {
        let pointer = unsafe Unmanaged<MiniSound>.passUnretained(self).toOpaque()

        unsafe ma_sound_set_end_callback(
            sound,
            { userData, _ in
                guard let userData else {
                    return
                }
                let soundObj = unsafe Unmanaged<MiniSound>.fromOpaque(userData).takeUnretainedValue()
                unsafe soundObj.state = .finished
                unsafe soundObj.completionHandler?()
            },
            pointer
        )

        unsafe self.completionHandler = block
    }

    // MARK: - Private

    private func stop(resetPlaybackPosition: Bool, notifyCallback: Bool) {
        unsafe ma_sound_stop(sound)

        if resetPlaybackPosition {
            unsafe ma_sound_seek_to_pcm_frame(sound, 0)
        }

        if notifyCallback {
            unsafe self.completionHandler?()
        }
    }
}
