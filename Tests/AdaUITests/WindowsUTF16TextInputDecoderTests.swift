//
//  WindowsUTF16TextInputDecoderTests.swift
//  AdaEngine
//
//  Created by Codex on 21.02.2026.
//

#if os(Windows)
import Testing
@testable import AdaPlatform

struct WindowsUTF16TextInputDecoderTests {
    @Test
    func decoder_combinesSurrogatePairIntoSingleScalar() {
        var state = WindowsUTF16TextInputDecoder.State()

        let highSurrogate: UInt16 = 0xD83D
        let lowSurrogate: UInt16 = 0xDE03 // U+1F603

        let highResult = WindowsUTF16TextInputDecoder.decode(codeUnit: highSurrogate, state: &state)
        #expect(highResult == nil)

        let scalar = WindowsUTF16TextInputDecoder.decode(codeUnit: lowSurrogate, state: &state)
        #expect(scalar?.value == 0x1F603)
        #expect(state.pendingHighSurrogate == nil)
    }

    @Test
    func decoder_dropsUnmatchedHighSurrogateAndKeepsNextBmpCharacter() {
        var state = WindowsUTF16TextInputDecoder.State()

        let highResult = WindowsUTF16TextInputDecoder.decode(codeUnit: 0xD83D, state: &state)
        #expect(highResult == nil)
        #expect(state.pendingHighSurrogate == 0xD83D)

        let scalar = WindowsUTF16TextInputDecoder.decode(codeUnit: 0x0061, state: &state)
        #expect(scalar == UnicodeScalar(0x61))
        #expect(state.pendingHighSurrogate == nil)
    }

    @Test
    func decoder_ignoresLoneLowSurrogate() {
        var state = WindowsUTF16TextInputDecoder.State()

        let scalar = WindowsUTF16TextInputDecoder.decode(codeUnit: 0xDE03, state: &state)
        #expect(scalar == nil)
        #expect(state.pendingHighSurrogate == nil)
    }
}
#endif
