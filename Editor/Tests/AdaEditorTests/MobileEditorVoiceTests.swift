@_spi(Internal) @testable import AdaRender
import Testing

@testable import AdaEditor

@Suite("Mobile editor voice")
struct MobileEditorVoiceTests {
    @Test("Companion Bubble shader compiles with the AdaUI ABI")
    func shaderCompilation() throws {
        let source = try MobileVoiceOrbMaterial.fragmentShader()
        let result = try ShaderCompiler(shaderSource: source.asset).compileSpirvBin(for: .fragment, ignoreCache: true)
        #expect(!result.data.isEmpty)
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
