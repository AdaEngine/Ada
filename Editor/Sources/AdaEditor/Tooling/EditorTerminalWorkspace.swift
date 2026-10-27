import Foundation
import Observation

/// Retains independent shells while switching tabs or workbench tools.
@MainActor @Observable
final class EditorTerminalWorkspace {
    private(set) var sessions: [EditorTerminalSession]
    private(set) var activeSession: EditorTerminalSession
    @ObservationIgnored private var directory: URL?

    init() {
        let session = EditorTerminalSession()
        sessions = [session]
        activeSession = session
    }

    func start(in directory: URL) {
        guard self.directory == nil else { return }
        self.directory = directory
        for session in sessions { session.start(in: directory) }
    }

    func select(_ session: EditorTerminalSession) {
        guard sessions.contains(where: { $0 === session }) else { return }
        activeSession = session
    }

    func add() {
        let session = EditorTerminalSession()
        sessions.append(session)
        activeSession = session
        if let directory { session.start(in: directory) }
    }

    func close(_ session: EditorTerminalSession) {
        guard let index = sessions.firstIndex(where: { $0 === session }) else { return }
        session.stop()
        sessions.remove(at: index)
        if sessions.isEmpty {
            add()
        } else if activeSession === session {
            activeSession = sessions[min(index, sessions.count - 1)]
        }
    }

    func stop() {
        for session in sessions { session.stop() }
        directory = nil
    }
}
