@testable import AdaEditor
import Testing

@Suite("Mobile agent context presentation")
struct MobileEditorAgentContextTests {
    @Test("Model instructions remain intact while the chat shows the exact Unicode request")
    func contextBoundary() {
        var settings = MobileAgentHarnessSettings()
        settings.instructions = "Use Russian.\n\n[User request]\nExample inside instructions."
        let request = "Давай исправлять 🎮\n\n[User request]\nKeep this literal marker.\n "
        let prompt = MobileEditorAgentContext.prompt(settings.prompt(request), visiblePrompt: request)
        #expect(prompt.contains(settings.instructions))
        for skill in settings.enabledSkills { #expect(prompt.contains(skill.content)) }
        #expect(MobileEditorAgentContext.visibleText(prompt) == request)
    }

    @Test("Existing sessions hide both nested instruction envelopes")
    func legacyContext() {
        var settings = MobileAgentHarnessSettings()
        settings.instructions = "Answer in Russian."
        let request = "выглядит всё ещё не очень, давай исправлять"
        #expect(MobileEditorAgentContext.visibleText(MobileEditorAgentContext.prompt(settings.prompt(request))) == request)
        settings.disabledSkillIDs = Set(MobileAgentHarnessSkill.builtIns.map(\.id))
        settings.instructions = ""
        #expect(MobileEditorAgentContext.visibleText(MobileEditorAgentContext.prompt(settings.prompt(request))) == request)
    }

    @Test("Automatic repair prompts remain in model context but have no user chat bubble")
    func repairContext() {
        let feedback = "[Automatic validation feedback]\nFix build errors."
        let settings = MobileAgentHarnessSettings()
        let prompt = MobileEditorAgentContext.prompt(settings.prompt(feedback), visiblePrompt: "")
        #expect(prompt.contains(feedback))
        #expect(MobileEditorAgentContext.visibleText(prompt) == nil)
        #expect(MobileEditorAgentContext.visibleText(MobileEditorAgentContext.prompt(settings.prompt(feedback))) == nil)
        #expect(MobileEditorAgentContext.visibleText(feedback) == feedback)
    }

    @Test("Ordinary messages and literal section markers are preserved")
    func ordinaryText() {
        for text in [
            "Hello", "[User request]\nMy example", "[Enabled skill: Game design]\nMy text",
            "[Mobile Studio requirements]\nMy example\n\n[User request]\nKeep this too."
        ] {
            #expect(MobileEditorAgentContext.visibleText(text) == text)
        }
    }
}
