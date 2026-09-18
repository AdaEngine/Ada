import Foundation

actor EditorAgentSessionStore {
    private let rootURL: URL
    private let indexURL: URL
    private let sessionsDirectoryURL: URL
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(projectURL: URL) {
        self.rootURL =
            projectURL
            .appendingPathComponent(ProjectSystem.metadataDirectoryName, isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
        self.indexURL = rootURL.appendingPathComponent("sessions.json", isDirectory: false)
        self.sessionsDirectoryURL = rootURL.appendingPathComponent("sessions", isDirectory: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func loadIndex() throws -> EditorAgentSessionIndex {
        guard fileManager.fileExists(atPath: indexURL.path) else {
            return EditorAgentSessionIndex()
        }
        let data = try Data(contentsOf: indexURL)
        return try decoder.decode(EditorAgentSessionIndex.self, from: data)
    }

    func listSessions() throws -> [EditorAgentSessionSummary] {
        try loadIndex().sessions.sorted { $0.updatedAt > $1.updatedAt }
    }

    func activeSessionID() throws -> String? {
        try loadIndex().activeSessionID
    }

    func loadSession(id: String) throws -> EditorAgentSession {
        let data = try Data(contentsOf: sessionURL(id: id))
        return try decoder.decode(EditorAgentSession.self, from: data)
    }

    @discardableResult
    func createSession(title: String = "New session") throws -> EditorAgentSession {
        var session = EditorAgentSession(title: title)
        if title == "New session" {
            session.title = "Session \(session.id.prefix(6))"
        }
        try saveSession(session, makeActive: true)
        return session
    }

    func saveSession(_ session: EditorAgentSession, makeActive: Bool) throws {
        try ensureDirectories()
        try encoder.encode(session).write(to: sessionURL(id: session.id), options: [.atomic])

        var index = try loadIndex()
        let summary = EditorAgentSessionSummary(session: session)
        if let existingIndex = index.sessions.firstIndex(where: { $0.id == session.id }) {
            index.sessions[existingIndex] = summary
        } else {
            index.sessions.append(summary)
        }
        index.sessions.sort { $0.updatedAt > $1.updatedAt }
        if makeActive {
            index.activeSessionID = session.id
        }
        try saveIndex(index)
    }

    func deleteSession(id: String) throws {
        var index = try loadIndex()
        index.sessions.removeAll { $0.id == id }
        if index.activeSessionID == id {
            index.activeSessionID = index.sessions.first?.id
        }
        if fileManager.fileExists(atPath: sessionURL(id: id).path) {
            try fileManager.removeItem(at: sessionURL(id: id))
        }
        try saveIndex(index)
    }

    func setActiveSession(id: String?) throws {
        var index = try loadIndex()
        index.activeSessionID = id
        try saveIndex(index)
    }

    private func saveIndex(_ index: EditorAgentSessionIndex) throws {
        try ensureDirectories()
        try encoder.encode(index).write(to: indexURL, options: [.atomic])
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sessionsDirectoryURL, withIntermediateDirectories: true)
    }

    private func sessionURL(id: String) -> URL {
        sessionsDirectoryURL.appendingPathComponent("\(id).json", isDirectory: false)
    }
}
