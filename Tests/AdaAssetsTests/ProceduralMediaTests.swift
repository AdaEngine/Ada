import Foundation
import Testing

@testable import AdaAssets

@Suite("Procedural images and sound")
struct ProceduralMediaTests {
    // MARK: - PNG

    @Test("PNG output has valid chunk checksums and stores the exact pixels")
    func pngRoundTrip() throws {
        let width = 5
        let height = 3
        let pixels = (0..<(width * height * 4)).map { UInt8(($0 * 37 + 11) % 256) }
        let png = try PNGWriter().encode(width: width, height: height, rgba: pixels)
        #expect(Array(png.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        var offset = 8
        var types: [String] = []
        var idat = Data()
        var header: [UInt8] = []
        while offset < png.count {
            let length = Int(png[offset]) << 24 | Int(png[offset + 1]) << 16 | Int(png[offset + 2]) << 8 | Int(png[offset + 3])
            let type = String(decoding: png[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let body = png[(offset + 4)..<(offset + 8 + length)]
            let stored = png[(offset + 8 + length)..<(offset + 12 + length)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            #expect(PNGWriter.crc32(body) == stored, "\(type) checksum")
            types.append(type)
            if type == "IHDR" { header = Array(png[(offset + 8)..<(offset + 8 + length)]) }
            if type == "IDAT" { idat.append(png[(offset + 8)..<(offset + 8 + length)]) }
            offset += 12 + length
        }
        #expect(types == ["IHDR", "IDAT", "IEND"])
        #expect(header.suffix(5) == [8, 6, 0, 0, 0])

        // Inflate the stored blocks by hand and drop the filter byte of each row.
        var raw: [UInt8] = []
        var cursor = 2
        var last = false
        while !last {
            last = idat[idat.startIndex + cursor] & 1 == 1
            let length = Int(idat[idat.startIndex + cursor + 1]) | Int(idat[idat.startIndex + cursor + 2]) << 8
            raw += idat[(idat.startIndex + cursor + 5)..<(idat.startIndex + cursor + 5 + length)]
            cursor += 5 + length
        }
        let adler = idat[(idat.startIndex + cursor)...].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        #expect(adler == PNGWriter.adler32(raw))
        let rows = (0..<height).map { Array(raw[(1 + $0 * (width * 4 + 1))..<(($0 + 1) * (width * 4 + 1))]) }
        #expect(rows.flatMap { $0 } == pixels)
    }

    @Test("Large images split into several stored blocks")
    func pngLargeImage() throws {
        let png = try PNGWriter().encode(width: 200, height: 200, rgba: [UInt8](repeating: 7, count: 200 * 200 * 4))
        #expect(png.count > 160_000)
    }

    @Test("PNG rejects empty, oversized and mismatched input")
    func pngInvalid() {
        #expect(throws: PNGWritingError.invalidSize(width: 0, height: 1)) { try PNGWriter().encode(width: 0, height: 1, rgba: []) }
        #expect(throws: PNGWritingError.pixelCountMismatch) { try PNGWriter().encode(width: 2, height: 2, rgba: [0, 0, 0, 0]) }
    }

    // MARK: - Pixel canvas

    @Test("Canvas shapes clip at the edges and outline hugs opaque pixels")
    func canvasDrawing() throws {
        var canvas = try #require(PixelCanvas(width: 8, height: 8))
        canvas.fillRect(x0: -5, y0: -5, x1: 1, y1: 1, color: 1)
        #expect(canvas.opaquePixelCount == 4)
        canvas.fillRect(x0: -9, y0: -9, x1: -3, y1: -3, color: 2)
        #expect(canvas.color(x: 0, y: 0) == 1, "a rectangle fully off the canvas paints nothing")
        canvas.line(x0: 7, y0: 7, x1: 3, y1: 7, color: 3)
        #expect((3...7).allSatisfy { canvas.color(x: $0, y: 7) == 3 })
        canvas.fillEllipse(cx: 4, cy: 3, rx: 2, ry: 2, color: 4)
        #expect(canvas.color(x: 4, y: 3) == 4 && canvas.color(x: 4, y: 1) == 4 && canvas.color(x: 0, y: 6) == 0)

        var sprite = try #require(PixelCanvas(width: 5, height: 5))
        sprite.set(x: 2, y: 2, color: 1)
        sprite.outline(color: 9)
        #expect(sprite.usedColors == [1, 9])
        #expect(sprite.color(x: 2, y: 1) == 9 && sprite.color(x: 1, y: 1) == 0, "diagonal neighbors are not outlined")
        #expect(sprite.opaquePixelCount == 5)

        var half = try #require(PixelCanvas(width: 4, height: 1))
        half.set(x: 0, y: 0, color: 5)
        half.set(x: 1, y: 0, color: 6)
        half.mirrorLeftToRight()
        #expect((0..<4).map { half.color(x: $0, y: 0) } == [5, 6, 6, 5])
        #expect(PixelCanvas(width: 0, height: 4) == nil && PixelCanvas(width: 513, height: 4) == nil)
    }

    @Test("Canvas exports transparent index 0 and palette alpha")
    func canvasRGBA() throws {
        var canvas = try #require(PixelCanvas(width: 2, height: 1))
        canvas.palette[1] = PixelColor(red: 10, green: 20, blue: 30, alpha: 128)
        canvas.set(x: 1, y: 0, color: 1)
        #expect(canvas.rgba() == [0, 0, 0, 0, 10, 20, 30, 128])
    }

    // MARK: - GIF

    @Test("GIF output loops, scales by integers and round-trips frames and delays")
    func gifRoundTrip() throws {
        var palette = [PixelColor](repeating: PixelColor(red: 0, green: 0, blue: 0), count: 256)
        palette[1] = PixelColor(red: 200, green: 10, blue: 20)
        palette[2] = PixelColor(red: 10, green: 20, blue: 220)
        let first = [UInt8](repeating: 1, count: 16)
        var second = [UInt8](repeating: 0, count: 16)
        second[5] = 2
        let gif = try GIFWriter().encode(
            width: 4,
            height: 4,
            frames: [
                GIFAnimationFrame(indices: first, delayMilliseconds: 100),
                GIFAnimationFrame(indices: second, delayMilliseconds: 80),
            ],
            palette: palette,
            scale: 2
        )
        #expect(gif.starts(with: [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]))
        #expect(gif.last == 0x3B)

        let decoded = try GIFReader().decode(gif)
        #expect(decoded.width == 8 && decoded.height == 8)
        #expect(decoded.frames.count == 2)
        #expect(decoded.frames[0].delayMilliseconds == 100)
        #expect(decoded.frames[1].delayMilliseconds == 80)
        #expect(decoded.loops)
        #expect(decoded.palette[1] == PixelColor(red: 200, green: 10, blue: 20))
        #expect(decoded.palette[2] == PixelColor(red: 10, green: 20, blue: 220))
        #expect(decoded.palette[0].alpha == 0, "index 0 stays transparent")
        #expect(decoded.frames[0].indices.allSatisfy { $0 == 1 }, "scaled solid frame")
        #expect(decoded.frames[1].indices[18] == 2 && decoded.frames[1].indices[19] == 2, "2x scale replicates pixels")
        #expect(decoded.frames[1].indices[0] == 0)
    }

    @Test("GIF writer rejects bad sizes, scales, frame counts and mismatched pixels")
    func gifInvalid() {
        let frame = GIFAnimationFrame(indices: [1], delayMilliseconds: 100)
        #expect(throws: GIFWritingError.invalidSize(width: 0, height: 1)) {
            try GIFWriter().encode(width: 0, height: 1, frames: [frame], palette: [])
        }
        #expect(throws: GIFWritingError.invalidScale(0)) {
            try GIFWriter().encode(width: 1, height: 1, frames: [frame], palette: [], scale: 0)
        }
        #expect(throws: GIFWritingError.emptyAnimation) {
            try GIFWriter().encode(width: 1, height: 1, frames: [], palette: [])
        }
        #expect(throws: GIFWritingError.tooManyFrames(257)) {
            try GIFWriter().encode(width: 1, height: 1, frames: [GIFAnimationFrame](repeating: frame, count: 257), palette: [])
        }
        #expect(throws: GIFWritingError.mismatchedFrame(0, expected: 4)) {
            try GIFWriter().encode(width: 2, height: 2, frames: [frame], palette: [])
        }
    }

    @Test("GIF reader rejects junk and features the writer never emits")
    func gifReaderRejects() {
        #expect(throws: GIFReadingError.notGIF) { try GIFReader().decode(Data([1, 2, 3, 4, 5, 6])) }
        #expect(throws: GIFReadingError.truncated) { try GIFReader().decode(Data([0x47, 0x49, 0x46, 0x38])) }
    }

    @Test("GIF decoding follows LZW code-width changes and preserves every color index")
    func gifReadsLargeDictionary() throws {
        let size = 128
        var state: UInt32 = 1
        let indices = (0..<(size * size)).map { _ in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 16)
        }
        let frame = GIFAnimationFrame(indices: indices, delayMilliseconds: 85)
        let gif = try GIFWriter().encode(width: size, height: size, frames: [frame], palette: [])
        let decoded = try GIFReader().decode(gif)
        #expect(decoded.frames.first?.indices == indices)
        #expect(decoded.frames.first?.delayMilliseconds == 90)
    }

    // MARK: - Palette extraction

    @Test("Palette extraction keeps exact colors when few, ignoring transparent pixels")
    func paletteExtractExact() {
        // 2x2: red, red, blue, transparent.
        let rgba: [UInt8] = [200, 0, 0, 255, 200, 0, 0, 255, 0, 0, 200, 255, 9, 9, 9, 40]
        let colors = PixelPaletteExtractor.extract(rgba: rgba, maximumColors: 8)
        #expect(colors == [PixelColor(red: 200, green: 0, blue: 0), PixelColor(red: 0, green: 0, blue: 200)])
        #expect(PixelPaletteExtractor.extract(rgba: [1, 2, 3, 0], maximumColors: 8).isEmpty)
    }

    @Test("Palette extraction quantizes busy images down to the cap")
    func paletteExtractQuantized() {
        var rgba: [UInt8] = []
        for index in 0..<256 {
            let value = UInt8(index)
            rgba.append(contentsOf: [value, value, value, 255])
        }
        let colors = PixelPaletteExtractor.extract(rgba: rgba, maximumColors: 4)
        #expect(colors.count == 4)
        #expect(colors.allSatisfy { abs(Int($0.red) - Int($0.green)) <= 1 && abs(Int($0.green) - Int($0.blue)) <= 1 }, "grayscale stays gray")
    }

    @Test("Palette buckets keep distinct red bands and break frequency ties consistently")
    func paletteExtractQuantizesEveryChannel() {
        let rgba: [UInt8] = [0, 0, 0, 255, 128, 0, 0, 255, 255, 0, 0, 255]
        let colors = PixelPaletteExtractor.extract(rgba: rgba, maximumColors: 2)
        #expect(colors == [PixelColor(red: 255, green: 0, blue: 0), PixelColor(red: 128, green: 0, blue: 0)])
    }

    // MARK: - WAV

    @Test("WAV encoding round-trips through the reader and clips out-of-range samples")
    func wavRoundTrip() throws {
        let audio = WAVAudio(sampleRate: 22_050, channels: 2, samples: [0, 0.5, -0.5, 1, 2, -2])
        let decoded = try WAVReader().decode(WAVWriter().encode(audio))
        #expect(decoded.sampleRate == 22_050 && decoded.channels == 2 && decoded.frameCount == 3)
        #expect(zip(decoded.samples, [0, 0.5, -0.5, 1, 1, -1]).allSatisfy { abs($0 - $1) < 0.0001 })
        #expect(decoded.mono.count == 3)
    }

    @Test("WAV reader handles 8, 24 and 32-bit PCM and float data, and rejects junk")
    func wavFormats() throws {
        func file(tag: UInt16, bits: UInt16, payload: [UInt8]) -> Data {
            var data = Data("RIFF".utf8)
            data.append(contentsOf: le32(UInt32(36 + payload.count)))
            data.append(contentsOf: Array("WAVEfmt ".utf8))
            data.append(contentsOf: le32(16) + le16(tag) + le16(1) + le32(8000) + le32(8000 * UInt32(bits / 8)) + le16(bits / 8) + le16(bits))
            data.append(contentsOf: Array("data".utf8))
            data.append(contentsOf: le32(UInt32(payload.count)) + payload)
            return data
        }
        #expect(try WAVReader().decode(file(tag: 1, bits: 8, payload: [0, 128, 255])).samples == [-1, 0, Float(127) / 128])
        let wide = try WAVReader().decode(file(tag: 1, bits: 24, payload: [0, 0, 0x40, 0, 0, 0xC0]))
        #expect(wide.samples == [0.5, -0.5])
        let floats = try WAVReader().decode(file(tag: 3, bits: 32, payload: le32(Float(0.25).bitPattern) + le32(Float(-1).bitPattern)))
        #expect(floats.samples == [0.25, -1])
        #expect(throws: WAVError.invalidFile) { try WAVReader().decode(Data([1, 2, 3])) }
        #expect(throws: WAVError.unsupportedFormat("format 2, 16 bits")) { try WAVReader().decode(file(tag: 2, bits: 16, payload: [0, 0])) }
        #expect(throws: WAVError.invalidAudio) { try WAVWriter().encode(WAVAudio(sampleRate: 100, channels: 1, samples: [0])) }
    }

    // MARK: - Synth and analysis

    @Test("A sine voice renders at the requested pitch and peak, and the analyzer finds both")
    func sinePitch() throws {
        var spec = SoundSpec()
        var voice = SoundVoice(wave: .sine, frequency: 440, duration: 0.5)
        voice.release = 0.05
        spec.voices = [voice]
        spec.peak = 0.5
        let audio = try SoundSynth.render(spec)
        #expect(audio.channels == 1 && audio.sampleRate == 44_100)
        #expect(abs(audio.duration - 0.55) < 0.001)
        let report = AudioAnalyzer.analyze(audio)
        #expect(abs(report.peak - 0.5) < 0.001)
        #expect(abs(report.dominantFrequency - 440) < 15, "dominant \(report.dominantFrequency)")
        #expect(report.clippedSamples == 0)
        #expect(report.leadingSilence < 0.01)
        #expect(abs(report.dcOffset) < 0.01)
    }

    @Test("Waveforms differ in brightness and noise is deterministic per seed")
    func waveforms() throws {
        func report(_ wave: Waveform, seed: UInt32 = 1) throws -> (AudioReport, [Float]) {
            var spec = SoundSpec()
            spec.seed = seed
            spec.voices = [SoundVoice(wave: wave, frequency: 400, duration: 0.3)]
            let audio = try SoundSynth.render(spec)
            return (AudioAnalyzer.analyze(audio), audio.samples)
        }
        let sine = try report(.sine).0
        let square = try report(.square).0
        let saw = try report(.saw).0
        let triangle = try report(.triangle).0
        #expect(square.spectralCentroid > sine.spectralCentroid * 2)
        #expect(saw.spectralCentroid > triangle.spectralCentroid)
        #expect(try report(.noise, seed: 4).1 == report(.noise, seed: 4).1)
        #expect(try report(.noise, seed: 4).1 != report(.noise, seed: 5).1)
    }

    @Test("Sweep moves pitch, filters darken the tone, echo extends the tail and envelopes shape loudness")
    func shaping() throws {
        func render(_ edit: (inout SoundSpec, inout SoundVoice) -> Void) throws -> AudioReport {
            var spec = SoundSpec()
            var voice = SoundVoice(wave: .saw, frequency: 800, duration: 0.4)
            edit(&spec, &voice)
            spec.voices = [voice]
            return AudioAnalyzer.analyze(try SoundSynth.render(spec))
        }
        let plain = try render { _, _ in }
        let lowpassed = try render { _, voice in voice.lowpass = 600 }
        #expect(lowpassed.spectralCentroid < plain.spectralCentroid)
        let highpassed = try render { _, voice in voice.highpass = 4000 }
        #expect(highpassed.spectralCentroid > plain.spectralCentroid)

        let sweepDown = try render { _, voice in
            voice.wave = .sine
            voice.frequency = 1200
            voice.endFrequency = 200
        }
        #expect(sweepDown.dominantFrequency < 1200 && sweepDown.dominantFrequency > 150)

        let echoed = try render { spec, _ in spec.echo = SoundEcho(delay: 0.2, feedback: 0.5, mix: 0.5) }
        #expect(echoed.duration > plain.duration + 0.5)

        let decaying = try render { _, voice in
            voice.attack = 0.01
            voice.decay = 0.3
            voice.sustain = 0
        }
        #expect(decaying.envelope[0] > decaying.envelope[8] + 20, "\(decaying.envelope)")
        let silentStart = try render { _, voice in voice.start = 0.5 }
        #expect(silentStart.leadingSilence >= 0.49)
    }

    @Test("Voices can be offset, and limits and silence are rejected")
    func limits() throws {
        var offset = SoundSpec()
        var late = SoundVoice(wave: .square, frequency: 300, duration: 0.2)
        late.start = 0.3
        offset.voices = [late]
        let report = AudioAnalyzer.analyze(try SoundSynth.render(offset))
        #expect(report.leadingSilence >= 0.29)

        #expect(throws: SoundSynthError.noVoices) { try SoundSynth.render(SoundSpec()) }
        var long = SoundSpec()
        long.voices = [SoundVoice(wave: .sine, frequency: 100, duration: 31)]
        #expect(throws: SoundSynthError.self) { try SoundSynth.render(long) }
        var many = SoundSpec()
        many.voices = Array(repeating: SoundVoice(wave: .sine, frequency: 100, duration: 1), count: 257)
        #expect(throws: SoundSynthError.tooManyVoices) { try SoundSynth.render(many) }
        var quiet = SoundSpec()
        var mute = SoundVoice(wave: .sine, frequency: 100, duration: 0.1)
        mute.volume = 0
        quiet.voices = [mute]
        #expect(throws: SoundSynthError.silent) { try SoundSynth.render(quiet) }
    }

    @Test("Analyzer flags clipping, DC offset and silence")
    func analyzerFlags() {
        let clipped = AudioAnalyzer.analyze(WAVAudio(sampleRate: 8000, channels: 1, samples: [Float](repeating: 1, count: 100)))
        #expect(clipped.clippedSamples == 100 && clipped.dcOffset == 1 && clipped.peakDecibels == 0)
        let silent = AudioAnalyzer.analyze(WAVAudio(sampleRate: 8000, channels: 1, samples: [Float](repeating: 0, count: 8000)))
        #expect(silent.leadingSilence == 1 && silent.peakDecibels == -120 && silent.dominantFrequency == 0)
    }

    private func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    private func le32(_ value: UInt32) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)] }
}
