@_spi(Internal) @testable import AdaRender
import AdaWGSLCompiler
import Foundation
import Testing

@testable import AdaEditor

@Suite("Mobile editor voice")
struct MobileEditorVoiceTests {
    @Test("Companion Bubble shader compiles with the AdaUI ABI")
    func shaderCompilation() throws {
        let file = try #require(Bundle.editor.url(forResource: "mobile_voice_orb", withExtension: "wesl", subdirectory: "Assets/Shaders"))
        let artifact = try ShaderModule.linkWESL(from: file)
        #expect(artifact.entryPoints.contains { $0.stage == "vertex" })
        let fragment = try #require(artifact.entryPoints.first { $0.stage == "fragment" })
        let reflection = try ShaderModule.weslStageReflection(artifact: artifact, entry: fragment, stage: .fragment)
        #expect(reflection.shaderBuffers["MobileVoiceOrbMaterial"]?.size == MemoryLayout<MobileVoiceOrbParameters>.stride)
    }

    @Test("Bubble responds to input and settles after recording")
    func audioReaction() {
        var animation = MobileVoiceOrbAnimation(activity: .listening, audioLevel: 1)
        animation.advance(0.05, reduceMotion: false)
        #expect(animation.level > 0.4)
        let loudLevel = animation.level
        animation.activity = .idle
        animation.advance(0.05, reduceMotion: false)
        #expect(animation.level < loudLevel)
        animation.audioLevel = .nan
        animation.activity = .listening
        animation.advance(.infinity, reduceMotion: false)
        #expect(animation.level.isFinite)
        animation.advance(0.05, reduceMotion: true)
        #expect(animation.time == 8)
        #expect(animation.level == 0)
        let advanced = animation.advance(0.05, reduceMotion: true)
        #expect(!advanced)
    }

    @Test("Voice replies exclude previous turns and private thinking")
    func currentReply() {
        let oldAnswer = message(.assistant, "Old answer")
        let user = message(.user, "Make a game")
        #expect(MobileEditorVoiceContent.reply(in: [oldAnswer, user]) == nil)
        let answer = EditorAgentEvent(kind: .message, message: EditorAgentMessage(role: .assistant, segments: [
            .init(kind: .thinking, text: "Private reasoning"),
            .init(kind: .text, text: "Built the game")
        ]))
        #expect(MobileEditorVoiceContent.reply(in: [oldAnswer, user, answer]) == "Built the game")
        #expect(MobileEditorVoiceContent.reply(in: [user, answer, message(.user, "Next change")]) == nil)
        #expect(MobileEditorVoiceContent.reply(in: [oldAnswer]) == nil)
    }

    private func message(_ role: EditorAgentRole, _ text: String) -> EditorAgentEvent {
        EditorAgentEvent(kind: .message, message: EditorAgentMessage(role: role, segments: [.init(kind: .text, text: text)]))
    }
}

@Suite("Mobile editor transcript accumulator")
struct MobileEditorTranscriptAccumulatorTests {
    @Test("Volatile hypotheses are replaced and finals accumulate")
    func accumulation() {
        var accumulator = MobileEditorTranscriptAccumulator()
        #expect(accumulator.apply("hel", isFinal: false) == "hel")
        #expect(accumulator.apply("hello wor", isFinal: false) == "hello wor")
        #expect(accumulator.apply("hello world", isFinal: true) == "hello world")
        #expect(accumulator.apply("how are", isFinal: false) == "hello world how are")
        #expect(accumulator.apply("how are you", isFinal: true) == "hello world how are you")
    }

    @Test("Existing whitespace is not doubled")
    func whitespace() {
        var accumulator = MobileEditorTranscriptAccumulator()
        _ = accumulator.apply("Привет. ", isFinal: true)
        #expect(accumulator.apply("Как дела", isFinal: false) == "Привет. Как дела")
    }
}
