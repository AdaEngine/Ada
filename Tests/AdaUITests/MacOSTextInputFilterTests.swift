//
//  MacOSTextInputFilterTests.swift
//  AdaEngine
//
//  Created by Codex on 19.02.2026.
//

#if os(macOS)
import Testing
@testable import AdaPlatform
import AdaInput

@MainActor
struct MacOSTextInputFilterTests {
    @Test
    func arrowKey_doesNotProduceTextPayload() {
        let arrowChar = String(UnicodeScalar(0xF702)!)
        let payload = MetalView.textInputPayload(
            keyCode: .arrowLeft,
            modifiers: [],
            characters: arrowChar
        )

        #expect(payload == nil)
    }

    @Test
    func printableKey_producesTextPayload() {
        let payload = MetalView.textInputPayload(
            keyCode: .a,
            modifiers: [],
            characters: "a"
        )

        #expect(payload == "a")
    }
}
#endif
