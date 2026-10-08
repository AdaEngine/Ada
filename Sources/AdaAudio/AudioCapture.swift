//
//  AudioCapture.swift
//  AdaEngine
//
//  Created by OpenAI on 4/29/26.
//

import Foundation

#if os(macOS) || os(iOS) || os(visionOS)
    import AVFoundation
#endif

public enum AudioCaptureSampleFormat: Sendable {
    case float32

    internal var bytesPerSample: Int {
        switch self {
        case .float32:
            MemoryLayout<Float>.size
        }
    }
}

public struct AudioCaptureFormat: Sendable, Equatable {
    public var sampleRate: UInt32
    public var channels: UInt32
    public var sampleFormat: AudioCaptureSampleFormat

    public init(
        sampleRate: UInt32 = 48_000,
        channels: UInt32 = 1,
        sampleFormat: AudioCaptureSampleFormat = .float32
    ) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.sampleFormat = sampleFormat
    }
}

public struct AudioCaptureConfiguration: Sendable, Equatable {
    public static let `default` = Self()

    public var format: AudioCaptureFormat
    public var bufferDuration: TimeInterval
    public var framesPerChunk: Int

    public init(
        format: AudioCaptureFormat = AudioCaptureFormat(),
        bufferDuration: TimeInterval = 2.0,
        framesPerChunk: Int = 1024
    ) {
        self.format = format
        self.bufferDuration = bufferDuration
        self.framesPerChunk = framesPerChunk
    }
}

public struct AudioCaptureChunk: Sendable, Equatable {
    public let format: AudioCaptureFormat
    public let frameCount: Int
    public let data: Data

    public init(format: AudioCaptureFormat, frameCount: Int, data: Data) {
        self.format = format
        self.frameCount = frameCount
        self.data = data
    }

    public var floatSamples: [Float] {
        guard self.format.sampleFormat == .float32 else {
            return []
        }

        return unsafe self.data.withUnsafeBytes { rawBuffer in
            unsafe Array(rawBuffer.bindMemory(to: Float.self))
        }
    }
}

public enum AudioCaptureError: LocalizedError, Sendable, Equatable {
    case initializationFailed(Int32)
    case startFailed(Int32)
    case stopFailed(Int32)
    case invalidConfiguration(String)
    case permissionDenied
    case unsupported

    public var errorDescription: String? {
        switch self {
        case let .initializationFailed(code):
            "Failed to initialize microphone capture device. Code: \(code)"
        case let .startFailed(code):
            "Failed to start microphone capture device. Code: \(code)"
        case let .stopFailed(code):
            "Failed to stop microphone capture device. Code: \(code)"
        case let .invalidConfiguration(message):
            "Invalid microphone capture configuration: \(message)"
        case .permissionDenied:
            "Microphone capture permission was denied."
        case .unsupported:
            "Microphone capture is unsupported on this platform."
        }
    }
}

protocol AudioCaptureSessionBackend: AnyObject, Sendable {
    var format: AudioCaptureFormat { get }
    var availableFrameCount: Int { get }
    var droppedFrameCount: UInt64 { get }

    func start() throws
    func stop() throws
    func readChunk(maxFrames: Int) -> AudioCaptureChunk?
    func chunks(framesPerChunk: Int?) -> AsyncStream<AudioCaptureChunk>
}

public final class AudioCaptureSession: Sendable {
    private let backend: any AudioCaptureSessionBackend

    init(backend: any AudioCaptureSessionBackend) {
        self.backend = backend
    }

    public var format: AudioCaptureFormat {
        self.backend.format
    }

    public var availableFrameCount: Int {
        self.backend.availableFrameCount
    }

    public var droppedFrameCount: UInt64 {
        self.backend.droppedFrameCount
    }

    public func start() throws {
        try self.backend.start()
    }

    public func stop() throws {
        try self.backend.stop()
    }

    public func readChunk(maxFrames: Int) -> AudioCaptureChunk? {
        self.backend.readChunk(maxFrames: maxFrames)
    }

    public func chunks(framesPerChunk: Int? = nil) -> AsyncStream<AudioCaptureChunk> {
        self.backend.chunks(framesPerChunk: framesPerChunk)
    }
}

public enum AudioCaptureAuthorization: Sendable, Equatable {
    case authorized
    case denied
    case notDetermined
    case restricted
    case unsupported
}

public enum AudioCapturePermission {
    @MainActor
    public static func authorizationStatus() -> AudioCaptureAuthorization {
        #if os(macOS) || os(iOS) || os(visionOS)
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                return .authorized
            case .denied:
                return .denied
            case .notDetermined:
                return .notDetermined
            case .restricted:
                return .restricted
            @unknown default:
                return .unsupported
            }
        #else
            return .unsupported
        #endif
    }

    @MainActor
    public static func requestAccess() async -> AudioCaptureAuthorization {
        #if os(macOS) || os(iOS) || os(visionOS)
            let status = Self.authorizationStatus()
            guard status == .notDetermined else {
                return status
            }

            let granted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }

            return granted ? .authorized : .denied
        #else
            return .unsupported
        #endif
    }
}
