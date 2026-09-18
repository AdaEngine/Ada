import Foundation
import Yams

#if os(macOS)
    import CryptoKit
#endif

enum EditorAgentRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    case system
    case tool
}

enum EditorAgentMessageSegmentKind: String, Codable, Equatable, Sendable {
    case text
    case thinking
    case attachment
    case skill
}

struct EditorAgentAttachment: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var mimeType: String
    var sizeBytes: Int?
    var relativePath: String?
    var absolutePath: String

    init(
        id: String = UUID().uuidString,
        name: String,
        mimeType: String,
        sizeBytes: Int? = nil,
        relativePath: String? = nil,
        absolutePath: String
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.relativePath = relativePath
        self.absolutePath = absolutePath
    }
}

struct EditorAgentSceneContext: Codable, Equatable, Sendable {
    var sceneTitle: String
    var sceneRelativePath: String
    var selectedEntityID: String
    var selectedEntityName: String
    var parentID: String?
    var componentNames: [String]
    var entityYAML: String

    init(
        sceneTitle: String,
        sceneRelativePath: String,
        selectedEntityID: String,
        selectedEntityName: String,
        parentID: String?,
        componentNames: [String],
        entityYAML: String
    ) {
        self.sceneTitle = sceneTitle
        self.sceneRelativePath = sceneRelativePath
        self.selectedEntityID = selectedEntityID
        self.selectedEntityName = selectedEntityName
        self.parentID = parentID
        self.componentNames = componentNames
        self.entityYAML = entityYAML
    }

    init?(document: EditorSceneDocument) {
        guard
            let model = document.sceneModel ?? EditorSceneFileLoader.model(from: document.content),
            let selectedEntityID = model.editor?.selectedEntity,
            let entity = model.entities.first(where: { $0.id == selectedEntityID })
        else {
            return nil
        }

        self.init(
            sceneTitle: document.title,
            sceneRelativePath: document.relativePath,
            selectedEntityID: selectedEntityID,
            selectedEntityName: entity.name,
            parentID: entity.parent,
            componentNames: entity.components.keys.map(Self.shortComponentName).sorted(),
            entityYAML: Self.entityYAML(for: entity)
        )
    }

    private static func entityYAML(for entity: EditorSceneEntity) -> String {
        let payload = EditorAgentSceneEntityPayload(entity: entity)
        if let yaml = try? YAMLEncoder().encode(payload) {
            return yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return """
            entity:
              id: \(entity.id)
              name: \(entity.name)
            """
    }

    private static func shortComponentName(_ componentName: String) -> String {
        componentName.components(separatedBy: ".").last ?? componentName
    }
}

struct EditorAgentCodeSelectionContext: Equatable, Sendable {
    var documentTitle: String
    var documentRelativePath: String
    var language: String
    var range: EditorSourceRange
    var text: String

    var lineDescription: String {
        let start = range.start.line + 1
        let end = range.end.line + 1
        return start == end ? "line \(start)" : "lines \(start)-\(end)"
    }
}

private struct EditorAgentSceneEntityPayload: Codable {
    var entity: EditorSceneEntity
}

struct EditorAgentSkill: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var description: String?
    var localPath: String
    var userInvocable: Bool
    var allowedTools: [String]
    var instructions: String
}

struct EditorAgentMessageSegment: Codable, Equatable, Sendable {
    var kind: EditorAgentMessageSegmentKind
    var text: String?
    var attachment: EditorAgentAttachment?
    var skill: EditorAgentSkill?

    init(kind: EditorAgentMessageSegmentKind, text: String? = nil, attachment: EditorAgentAttachment? = nil, skill: EditorAgentSkill? = nil) {
        self.kind = kind
        self.text = text
        self.attachment = attachment
        self.skill = skill
    }
}

struct EditorAgentMessage: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var role: EditorAgentRole
    var segments: [EditorAgentMessageSegment]
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        role: EditorAgentRole,
        segments: [EditorAgentMessageSegment],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.segments = segments
        self.createdAt = createdAt
    }
}

enum EditorAgentEventKind: String, Codable, Equatable, Sendable {
    case message
    case runStatus
    case toolCall
    case toolResult
    case permission
    case error
}

enum EditorAgentToolStatus: String, Codable, Equatable, Sendable {
    case pending
    case inProgress
    case completed
    case failed
}

enum EditorAgentToolContentKind: String, Codable, Equatable, Sendable {
    case text
    case diff
    case terminal
    case image
    case resource
}

struct EditorAgentToolContent: Codable, Equatable, Sendable {
    var kind: EditorAgentToolContentKind
    var text: String?
    var path: String?
    var oldText: String?
    var newText: String?
    var terminalID: String?
    var imageData: String?
    var mimeType: String?
    var uri: String?
}

struct EditorAgentToolLocation: Codable, Equatable, Sendable {
    var path: String?
    var line: Int?
}

struct EditorAgentToolCall: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var kind: String
    var status: EditorAgentToolStatus?
    var content: [EditorAgentToolContent]
    var locations: [EditorAgentToolLocation]
}

enum EditorAgentPermissionState: String, Codable, Equatable, Sendable {
    case pending
    case selected
    case cancelled
}

struct EditorAgentPermissionOption: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var kind: String
}

struct EditorAgentPermissionRequest: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var summary: String
    var toolCallID: String?
    var options: [EditorAgentPermissionOption]
    var state: EditorAgentPermissionState
    var selectedOptionID: String?
}

struct EditorAgentEvent: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var kind: EditorAgentEventKind
    var createdAt: Date
    var message: EditorAgentMessage?
    var title: String?
    var details: String?
    var isSuccessful: Bool?
    var isDelta: Bool?
    var configuration: EditorAgentSessionConfiguration?
    var toolCall: EditorAgentToolCall?
    var permission: EditorAgentPermissionRequest?

    init(
        id: String = UUID().uuidString,
        kind: EditorAgentEventKind,
        createdAt: Date = Date(),
        message: EditorAgentMessage? = nil,
        title: String? = nil,
        details: String? = nil,
        isSuccessful: Bool? = nil,
        isDelta: Bool? = nil,
        configuration: EditorAgentSessionConfiguration? = nil,
        toolCall: EditorAgentToolCall? = nil,
        permission: EditorAgentPermissionRequest? = nil
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.message = message
        self.title = title
        self.details = details
        self.isSuccessful = isSuccessful
        self.isDelta = isDelta
        self.configuration = configuration
        self.toolCall = toolCall
        self.permission = permission
    }
}

struct EditorAgentSession: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var upstreamSessionID: String?
    var agentTargetIdentity: String?
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var events: [EditorAgentEvent]
    var selectedSkillIDs: [String]
    var attachments: [EditorAgentAttachment]

    init(
        id: String = UUID().uuidString,
        upstreamSessionID: String? = nil,
        title: String = "New session",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        events: [EditorAgentEvent] = [],
        selectedSkillIDs: [String] = [],
        attachments: [EditorAgentAttachment] = []
    ) {
        self.id = id
        self.upstreamSessionID = upstreamSessionID
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.events = events
        self.selectedSkillIDs = selectedSkillIDs
        self.attachments = attachments
    }
}

extension AdaProjectAgentTarget {
    /// Persist a fingerprint so session history never copies connection environment secrets.
    var sessionIdentity: String? {
        #if os(macOS)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            guard let data = try? encoder.encode(self) else {
                return nil
            }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
            return nil
        #endif
    }
}

struct EditorAgentSessionIndex: Codable, Equatable, Sendable {
    var activeSessionID: String?
    var sessions: [EditorAgentSessionSummary]

    init(activeSessionID: String? = nil, sessions: [EditorAgentSessionSummary] = []) {
        self.activeSessionID = activeSessionID
        self.sessions = sessions
    }
}

struct EditorAgentSessionSummary: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var upstreamSessionID: String?

    init(session: EditorAgentSession) {
        self.id = session.id
        self.title = session.title
        self.createdAt = session.createdAt
        self.updatedAt = session.updatedAt
        self.upstreamSessionID = session.upstreamSessionID
    }
}

enum EditorAgentChatMode: String, Codable, CaseIterable, Equatable, Sendable {
    case ask
    case build
    case plan
    case debug

    var title: String {
        switch self {
        case .ask:
            "Ask"
        case .build:
            "Build"
        case .plan:
            "Plan"
        case .debug:
            "Debug"
        }
    }
}

enum EditorAgentConfigurationCategory: String, Codable, Equatable, Sendable {
    case mode
    case model
    case reasoning
    case other
}

struct EditorAgentConfigurationChoice: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var description: String?
}

struct EditorAgentConfigurationSelector: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var category: EditorAgentConfigurationCategory
    var currentValueID: String
    var choices: [EditorAgentConfigurationChoice]
    var usesLegacyMethod: Bool

    var currentChoice: EditorAgentConfigurationChoice? {
        choices.first { $0.id == currentValueID }
    }
}

struct EditorAgentSessionConfiguration: Codable, Equatable, Sendable {
    var agentName: String?
    var selectors: [EditorAgentConfigurationSelector]
    var commands: [EditorAgentCommand]

    init(agentName: String?, selectors: [EditorAgentConfigurationSelector], commands: [EditorAgentCommand] = []) {
        self.agentName = agentName
        self.selectors = selectors
        self.commands = commands
    }

    private enum CodingKeys: String, CodingKey { case agentName, selectors, commands }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        agentName = try values.decodeIfPresent(String.self, forKey: .agentName)
        selectors = try values.decode([EditorAgentConfigurationSelector].self, forKey: .selectors)
        commands = try values.decodeIfPresent([EditorAgentCommand].self, forKey: .commands) ?? []
    }

    static let empty = Self(agentName: nil, selectors: [])

    func selector(category: EditorAgentConfigurationCategory) -> EditorAgentConfigurationSelector? {
        selectors.first { $0.category == category }
    }
}

enum EditorAgentConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case ready(String?)
    case running
    case failed(String)

    var title: String {
        switch self {
        case .disconnected:
            "Disconnected"
        case .connecting:
            "Connecting"
        case let .ready(agentName):
            agentName.map { "Ready · \($0)" } ?? "Ready"
        case .running:
            "Running"
        case let .failed(message):
            "Failed: \(message)"
        }
    }
}
