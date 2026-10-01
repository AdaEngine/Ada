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

    private let engine: MiniAudioStorage

    init(headless: Bool = false) throws {
        unsafe engine = try MiniAudioStorage(headless: headless)
    }

    // MARK: - AudioEngine

    func start() throws { unsafe try engine.start() }
    func stop() throws { unsafe try engine.stop() }
    func update(_: AdaUtils.TimeInterval) { unsafe engine.update() }

    func makeSound(from url: URL) throws -> Sound { unsafe try MiniSound(from: url, engine: engine) }
    func makeSound(from data: Data) throws -> Sound { unsafe try MiniSound(from: data, engine: engine) }

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

        return unsafe MiniAudioEngineListener(engine: engine, listenerIndex: UInt32(index))
    }
}

// MARK: - MiniAudioEngineListener -

@unsafe
final class MiniAudioEngineListener: AudioEngineListener, @unchecked Sendable {
    private let owner: MiniAudioStorage
    private let engine: UnsafeMutablePointer<ma_engine>
    let listenerIndex: UInt32

    init(engine: MiniAudioStorage, listenerIndex: UInt32) {
        unsafe self.owner = engine
        unsafe self.engine = engine.enginePtr
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

    private let sound: UnsafeMutablePointer<ma_sound>
    private let engineOwner: MiniAudioStorage
    private let memorySource: MiniAudioMemorySource?

    init(from fileURL: URL, engine: MiniAudioStorage) throws {
        let pointer = UnsafeMutablePointer<ma_sound>.allocate(capacity: 1)
        let flags = MA_SOUND_FLAG_DECODE.rawValue | MA_SOUND_FLAG_NO_SPATIALIZATION.rawValue
        let result = fileURL.path.withCString { path in
            ma_sound_init_from_file(engine.enginePtr, path, UInt32(flags), nil, nil, pointer)
        }
        guard result == MA_SUCCESS else {
            pointer.deallocate(); throw MAError.failed("Sound initialization failed", result)
        }
        sound = pointer; engineOwner = engine; memorySource = nil
    }

    init(from data: Data, engine: MiniAudioStorage) throws {
        let source = try MiniAudioMemorySource(data: data)
        let pointer = UnsafeMutablePointer<ma_sound>.allocate(capacity: 1)
        let result = ma_sound_init_from_data_source(engine.enginePtr, UnsafeMutableRawPointer(source.decoder),
            UInt32(MA_SOUND_FLAG_NO_SPATIALIZATION.rawValue), nil, pointer)
        guard result == MA_SUCCESS else {
            pointer.deallocate(); throw MAError.failed("Sound initialization failed", result)
        }
        sound = pointer; engineOwner = engine; memorySource = source
    }

    private init(prototype: MiniSound) throws {
        let pointer = UnsafeMutablePointer<ma_sound>.allocate(capacity: 1)
        let result = ma_sound_init_copy(prototype.engineOwner.enginePtr, prototype.sound, 0, nil, pointer)
        guard result == MA_SUCCESS else { pointer.deallocate(); throw MAError.failed("Sound copy failed", result) }
        sound = pointer; engineOwner = prototype.engineOwner; memorySource = nil
    }

    deinit { ma_sound_uninit(sound); sound.deallocate() }

    func copy() throws -> Sound {
        if let memorySource { return unsafe try MiniSound(from: memorySource.encodedData, engine: engineOwner) }
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
