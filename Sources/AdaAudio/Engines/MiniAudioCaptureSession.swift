//
//  MiniAudioCaptureSession.swift
//  AdaEngine
//
//  Created by OpenAI on 4/29/26.
//

import Atomics
import Foundation
import miniaudio

#if !WASM

    @safe
    final class AudioCaptureRingBuffer: @unchecked Sendable {
        let format: AudioCaptureFormat
        private let bytesPerFrame: Int
        private let droppedFrames = ManagedAtomic<UInt64>(0)
        private var ringBuffer: UnsafeMutablePointer<ma_pcm_rb>

        init(format: AudioCaptureFormat, frameCapacity: Int) throws {
            guard frameCapacity > 0 else {
                throw AudioCaptureError.invalidConfiguration("frameCapacity must be greater than zero")
            }

            self.format = format
            self.bytesPerFrame = Int(format.channels) * format.sampleFormat.bytesPerSample
            unsafe self.ringBuffer = .allocate(capacity: 1)

            let result = unsafe ma_pcm_rb_init(
                ma_format_f32,
                format.channels,
                ma_uint32(frameCapacity),
                nil,
                nil,
                self.ringBuffer
            )

            if result != MA_SUCCESS {
                unsafe self.ringBuffer.deallocate()
                throw MiniAudioCaptureSession.initializationError(for: result)
            }
        }

        deinit {
            unsafe ma_pcm_rb_uninit(self.ringBuffer)
            unsafe self.ringBuffer.deallocate()
        }

        var availableFrameCount: Int {
            unsafe Int(ma_pcm_rb_available_read(self.ringBuffer))
        }

        var availableWriteFrameCount: Int {
            unsafe Int(ma_pcm_rb_available_write(self.ringBuffer))
        }

        var droppedFrameCount: UInt64 {
            self.droppedFrames.load(ordering: .relaxed)
        }

        func write(frames: UnsafeRawPointer, frameCount: Int) {
            guard frameCount > 0 else {
                return
            }

            var framesRemaining = frameCount
            var source = unsafe frames

            while framesRemaining > 0 {
                let writableFrames = min(framesRemaining, self.availableWriteFrameCount)
                guard writableFrames > 0 else {
                    self.droppedFrames.wrappingIncrement(by: UInt64(framesRemaining), ordering: .relaxed)
                    return
                }

                var framesToWrite = ma_uint32(writableFrames)
                var output: UnsafeMutableRawPointer?
                let acquireResult = unsafe ma_pcm_rb_acquire_write(self.ringBuffer, &framesToWrite, &output)

                guard acquireResult == MA_SUCCESS, let output = unsafe output, framesToWrite > 0 else {
                    self.droppedFrames.wrappingIncrement(by: UInt64(framesRemaining), ordering: .relaxed)
                    return
                }

                let bytesToCopy = Int(framesToWrite) * self.bytesPerFrame
                unsafe output.copyMemory(from: source, byteCount: bytesToCopy)
                _ = unsafe ma_pcm_rb_commit_write(self.ringBuffer, framesToWrite)

                framesRemaining -= Int(framesToWrite)
                unsafe source = source.advanced(by: bytesToCopy)
            }
        }

        func read(maxFrames: Int) -> AudioCaptureChunk? {
            guard maxFrames > 0 else {
                return nil
            }

            let framesToRead = min(maxFrames, self.availableFrameCount)
            guard framesToRead > 0 else {
                return nil
            }

            var data = Data()
            data.reserveCapacity(framesToRead * self.bytesPerFrame)

            var framesRemaining = framesToRead

            while framesRemaining > 0 {
                var acquiredFrames = ma_uint32(framesRemaining)
                var input: UnsafeMutableRawPointer?
                let acquireResult = unsafe ma_pcm_rb_acquire_read(self.ringBuffer, &acquiredFrames, &input)

                guard acquireResult == MA_SUCCESS, let input = unsafe input, acquiredFrames > 0 else {
                    break
                }

                let bytesToCopy = Int(acquiredFrames) * self.bytesPerFrame
                unsafe data.append(input.assumingMemoryBound(to: UInt8.self), count: bytesToCopy)
                _ = unsafe ma_pcm_rb_commit_read(self.ringBuffer, acquiredFrames)
                framesRemaining -= Int(acquiredFrames)
            }

            guard !data.isEmpty else {
                return nil
            }

            return AudioCaptureChunk(
                format: self.format,
                frameCount: data.count / self.bytesPerFrame,
                data: data
            )
        }
    }

    @safe
    final class MiniAudioCaptureSession: AudioCaptureSessionBackend, @unchecked Sendable {
        let format: AudioCaptureFormat

        private let configuration: AudioCaptureConfiguration
        private let ringBuffer: AudioCaptureRingBuffer
        private let device: UnsafeMutablePointer<ma_device>

        init(configuration: AudioCaptureConfiguration) throws {
            try Self.validate(configuration)

            self.configuration = configuration
            self.format = configuration.format

            let frameCapacity = max(
                configuration.framesPerChunk,
                Int(Double(configuration.format.sampleRate) * configuration.bufferDuration)
            )

            self.ringBuffer = try AudioCaptureRingBuffer(format: configuration.format, frameCapacity: frameCapacity)
            unsafe self.device = .allocate(capacity: 1)

            var deviceConfig = unsafe ma_device_config_init(ma_device_type_capture)
            unsafe deviceConfig.capture.format = ma_format_f32
            unsafe deviceConfig.capture.channels = configuration.format.channels
            unsafe deviceConfig.sampleRate = configuration.format.sampleRate
            unsafe deviceConfig.dataCallback = Self.captureDataCallback
            unsafe deviceConfig.pUserData = Unmanaged.passUnretained(self).toOpaque()

            let result = unsafe ma_device_init(nil, &deviceConfig, self.device)
            if result != MA_SUCCESS {
                unsafe self.device.deallocate()
                throw Self.initializationError(for: result)
            }
        }

        deinit {
            unsafe ma_device_uninit(self.device)
            unsafe self.device.deallocate()
        }

        var availableFrameCount: Int {
            self.ringBuffer.availableFrameCount
        }

        var droppedFrameCount: UInt64 {
            self.ringBuffer.droppedFrameCount
        }

        func start() throws {
            let result = unsafe ma_device_start(self.device)
            if result != MA_SUCCESS {
                throw AudioCaptureError.startFailed(result.rawValue)
            }
        }

        func stop() throws {
            let result = unsafe ma_device_stop(self.device)
            if result != MA_SUCCESS {
                throw AudioCaptureError.stopFailed(result.rawValue)
            }
        }

        func readChunk(maxFrames: Int) -> AudioCaptureChunk? {
            self.ringBuffer.read(maxFrames: maxFrames)
        }

        func chunks(framesPerChunk: Int?) -> AsyncStream<AudioCaptureChunk> {
            let frameCount = framesPerChunk ?? self.configuration.framesPerChunk
            let frameDuration = Double(frameCount) / Double(max(self.format.sampleRate, 1))

            return AsyncStream { continuation in
                let task = Task { [weak self] in
                    while !Task.isCancelled {
                        if let chunk = self?.readChunk(maxFrames: frameCount) {
                            continuation.yield(chunk)
                        } else {
                            try? await Task.sleep(for: .seconds(frameDuration / 2.0))
                        }
                    }

                    continuation.finish()
                }

                continuation.onTermination = { _ in
                    task.cancel()
                }
            }
        }

        private static func validate(_ configuration: AudioCaptureConfiguration) throws {
            guard configuration.format.sampleFormat == .float32 else {
                throw AudioCaptureError.invalidConfiguration("only Float32 capture is supported")
            }

            guard configuration.format.channels == 1 else {
                throw AudioCaptureError.invalidConfiguration("only mono capture is supported")
            }

            guard configuration.format.sampleRate == 48_000 else {
                throw AudioCaptureError.invalidConfiguration("only 48 kHz capture is supported")
            }

            guard configuration.bufferDuration > 0 else {
                throw AudioCaptureError.invalidConfiguration("bufferDuration must be greater than zero")
            }

            guard configuration.framesPerChunk > 0 else {
                throw AudioCaptureError.invalidConfiguration("framesPerChunk must be greater than zero")
            }
        }

        static func initializationError(for result: ma_result) -> AudioCaptureError {
            if result == MA_ACCESS_DENIED {
                return .permissionDenied
            }

            return .initializationFailed(result.rawValue)
        }

        private static let captureDataCallback: ma_device_data_proc = { device, _, input, frameCount in
            guard let device = unsafe device, let input = unsafe input else {
                return
            }

            guard let userData = unsafe device.pointee.pUserData else {
                return
            }

            let session = unsafe Unmanaged<MiniAudioCaptureSession>.fromOpaque(userData).takeUnretainedValue()
            unsafe session.ringBuffer.write(frames: input, frameCount: Int(frameCount))
        }
    }

#endif
