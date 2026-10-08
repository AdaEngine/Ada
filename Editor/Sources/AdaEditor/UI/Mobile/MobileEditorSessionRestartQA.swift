#if os(iOS) && DEBUG && targetEnvironment(simulator)
import Foundation
import Protocols
import SloppyRuntime

@MainActor
enum MobileEditorSessionRestartQA {
    static func prepare() throws -> MobileEditorProject {
        let project = MobileEditorProject(
            id: UUID(uuid: (0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x47, 0x98, 0x89, 0x9A, 0x9B, 0x9C, 0x9D, 0x9E, 0x9F, 0x90)),
            title: "Session Restart QA",
            prompt: "Forest adventure"
        )
        let workspace = try MobileAdaScriptProjectService.prepare(project)
        let agentsRoot = workspace.appendingPathComponent(".ada/workspace/agents")
        try FileManager.default.createDirectory(at: agentsRoot.appendingPathComponent("mobile"), withIntermediateDirectories: true)
        let store = AgentSessionFileStore(agentsRootURL: agentsRoot)
        let session = try store.createSession(
            agentID: "mobile", request: .init(title: "Forest adventure"), importedSessionID: "session-restart-qa-history"
        )
        if session.messageCount == 0 {
            try store.appendEvents(agentID: "mobile", sessionID: session.id, events: [
                .init(
                    agentId: "mobile",
                    sessionId: session.id,
                    type: .message,
                    message: .init(role: .user, segments: [.init(kind: .text, text: "Forest adventure")])
                ),
                .init(
                    agentId: "mobile",
                    sessionId: session.id,
                    type: .message,
                    message: .init(role: .assistant, segments: [.init(kind: .text, text: "Your previous session is preserved.")])
                )
            ])
        }
        return project
    }
}
#endif
