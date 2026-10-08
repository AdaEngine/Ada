//
//  AudioCaptureTests.swift
//  AdaEngine
//
//  Created by OpenAI on 4/29/26.
//

@testable import AdaAudio
import Foundation
import Testing

@Suite("Audio Capture Tests")
struct AudioCaptureTests {

    @Test("chunk decodes Float32 samples")
    func chunkDecodesFloatSamples() {
        let samples: [Float] = [0.0, 0.25, -0.5, 1.0]
        let chunk = AudioCaptureChunk(
            format: AudioCaptureFormat(),
            frameCount: samples.count,
            data: Self.data(from: samples)
        )

        #expect(chunk.floatSamples == samples)
    }

    @Test("ring buffer returns nil when empty")
    func ringBufferReturnsNilWhenEmpty() throws {
        let buffer = try AudioCaptureRingBuffer(format: AudioCaptureFormat(), frameCapacity: 8)

        #expect(buffer.read(maxFrames: 4) == nil)
    }

    @Test("ring buffer writes and reads all frames")
    func ringBufferWritesAndReadsAllFrames() throws {
        let buffer = try AudioCaptureRingBuffer(format: AudioCaptureFormat(), frameCapacity: 8)
        let samples: [Float] = [1, 2, 3, 4]

        Self.write(samples, to: buffer)
        let chunk = try #require(buffer.read(maxFrames: 8))

        #expect(chunk.frameCount == 4)
        #expect(chunk.floatSamples == samples)
        #expect(buffer.availableFrameCount == 0)
    }

    @Test("ring buffer supports partial reads")
    func ringBufferSupportsPartialReads() throws {
        let buffer = try AudioCaptureRingBuffer(format: AudioCaptureFormat(), frameCapacity: 8)
        let samples: [Float] = [1, 2, 3, 4]

        Self.write(samples, to: buffer)
        let first = try #require(buffer.read(maxFrames: 2))
        let second = try #require(buffer.read(maxFrames: 8))

        #expect(first.frameCount == 2)
        #expect(first.floatSamples == [1, 2])
        #expect(second.frameCount == 2)
        #expect(second.floatSamples == [3, 4])
    }

    @Test("ring buffer handles wraparound")
    func ringBufferHandlesWraparound() throws {
        let buffer = try AudioCaptureRingBuffer(format: AudioCaptureFormat(), frameCapacity: 5)

        Self.write([1, 2, 3, 4], to: buffer)
        let first = try #require(buffer.read(maxFrames: 3))
        Self.write([5, 6, 7], to: buffer)
        let second = try #require(buffer.read(maxFrames: 5))

        #expect(first.floatSamples == [1, 2, 3])
        #expect(second.floatSamples == [4, 5, 6, 7])
    }

    @Test("ring buffer tracks dropped frames on overflow")
    func ringBufferTracksDroppedFramesOnOverflow() throws {
        let buffer = try AudioCaptureRingBuffer(format: AudioCaptureFormat(), frameCapacity: 4)

        Self.write([1, 2, 3, 4, 5, 6], to: buffer)
        let chunk = try #require(buffer.read(maxFrames: 8))

        #expect(chunk.floatSamples == [1, 2, 3, 4])
        #expect(buffer.droppedFrameCount == 2)
    }

    private static func write(_ samples: [Float], to buffer: AudioCaptureRingBuffer) {
        samples.withUnsafeBytes { rawBuffer in
            buffer.write(frames: rawBuffer.baseAddress!, frameCount: samples.count)
        }
    }

    private static func data(from samples: [Float]) -> Data {
        samples.withUnsafeBytes { rawBuffer in
            Data(rawBuffer)
        }
    }
}

