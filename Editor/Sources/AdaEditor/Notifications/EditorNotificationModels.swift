import Foundation

enum EditorNotificationSource: String, Codable, CaseIterable, Sendable {
    case agent = "Agent"
    case build = "Build"
    case test = "Tests"
    case project = "Project"
    case sourceControl = "Git"
    case catalog = "Agent Catalog"
}

enum EditorNotificationImportance: String, Codable, Sendable {
    case information, success, warning, error, attention
    var isPersistent: Bool { self == .warning || self == .error || self == .attention }
}

struct EditorNotificationAction: Codable, Equatable, Sendable {
    enum Destination: String, Codable, Sendable { case chat, build, tests, projectSettings, agentSettings, sourceControl, activity }
    var title: String
    var destination: Destination
    var projectID: String?
    var sessionID: String?
    var settingsPage: String?
}

struct EditorNotification: Codable, Equatable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var source: EditorNotificationSource
    var importance: EditorNotificationImportance
    var title: String
    var detail: String = ""
    var projectName: String?
    var operationID: String?
    var createdAt: Date = Date()
    var isRead = false
    var actions: [EditorNotificationAction] = []
    var requestsSystemDelivery = true
}

struct EditorNotificationPreferences: Codable, Equatable, Sendable {
    var systemEnabled = false
    var soundEnabled = true
    var enabledSources = Set(EditorNotificationSource.allCases)

    func shouldDeliver(_ notification: EditorNotification, applicationIsActive: Bool) -> Bool {
        systemEnabled && !applicationIsActive && notification.requestsSystemDelivery && enabledSources.contains(notification.source)
    }
}

struct EditorOperationActivity: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case running, needsAttention, completed, failed, cancelled, interrupted
        var isTerminal: Bool { self != .running && self != .needsAttention }
    }
    var id: String = UUID().uuidString
    var source: EditorNotificationSource
    var title: String
    var projectName: String?
    var action: EditorNotificationAction?
    var state: State = .running
    var detail: String = ""
    var completedUnits: Int64?
    var totalUnits: Int64?
    var startedAt: Date = Date()
    var backgroundStatus: String?

    var fractionCompleted: Double? {
        guard let completedUnits, let totalUnits, totalUnits > 0 else {
            return nil
        }
        return min(1, max(0, Double(completedUnits) / Double(totalUnits)))
    }
}

struct EditorNotificationSnapshot: Codable, Sendable {
    var notifications: [EditorNotification] = []
    var activities: [EditorOperationActivity] = []
    var preferences = EditorNotificationPreferences()
}

actor EditorNotificationStore {
    let url: URL
    private var revision = -1

    init(url: URL) { self.url = url }

    func load() throws -> EditorNotificationSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .init()
        }
        return try JSONDecoder().decode(EditorNotificationSnapshot.self, from: Data(contentsOf: url))
    }

    func save(_ snapshot: EditorNotificationSnapshot, revision: Int) throws {
        guard revision > self.revision else {
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        self.revision = revision
    }
}
