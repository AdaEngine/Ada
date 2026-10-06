import Foundation
import Observation

struct MobileAgentHarnessSettings: Codable, Equatable, Sendable {
    var instructions = ""
    var maxToolRounds = 80
    var repairAttempts = 2
    var opensPreview = false
    var disabledSkillIDs: Set<String> = []
    var installedSkills: [MobileAgentHarnessSkill] = []

    var enabledSkills: [MobileAgentHarnessSkill] {
        (MobileAgentHarnessSkill.builtIns + installedSkills).filter { !disabledSkillIDs.contains($0.id) }
    }

    func prompt(_ userPrompt: String) -> String {
        var sections: [String] = []
        if !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append("[User agent instructions]\n\(instructions)")
        }
        for skill in enabledSkills {
            sections.append("[Enabled skill: \(skill.name)]\n\(skill.content)")
        }
        let catalog = EditorAgentSkillStore.bundledSkills().map { "- \($0.id): \($0.description ?? $0.name)" }
        sections.append((["[Bundled Ada Studio workflows]", "Load matching instructions with editor.skills.read; use editor.skills.list to search."] + catalog).joined(separator: "\n"))
        sections.append("[User request]\n\(userPrompt)")
        return sections.joined(separator: "\n\n")
    }
}

struct MobileAgentHarnessSkill: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let summary: String
    let content: String

    static let builtIns: [Self] = [
        Self(
            id: "mobile-touch-controls",
            name: "Touch controls",
            summary: "Accessible touch and desktop input for games.",
            content: """
            Provide a visible virtual joystick and buttons for game actions. Share gameplay actions with keyboard bindings.
            Support simultaneous movement and actions, release/cancel, safe areas and readable touch targets.
            """
        ),
        Self(
            id: "mobile-game-design",
            name: "Game design",
            summary: "A focused playable loop with clear feedback.",
            content: """
            Build a small complete playable loop. Make the goal, player actions and win/loss feedback clear.
            Add a restart path and readable HUD. Prefer existing project assets and supported APIs.
            """
        )
    ]
}

@Observable
@MainActor
final class MobileAgentHarnessStore {
    private(set) var settings = MobileAgentHarnessSettings()
    private(set) var errorMessage: String?
    private let fileURL: URL
    private let fileManager: FileManager

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let directory = directoryURL ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AdaEditor/MobileAgent", isDirectory: true)
        fileURL = directory.appendingPathComponent("settings.json")
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        do {
            let loaded = try JSONDecoder().decode(MobileAgentHarnessSettings.self, from: Data(contentsOf: fileURL))
            try validate(loaded)
            settings = loaded
        } catch {
            errorMessage = "Could not load agent settings: \(error.localizedDescription)"
        }
    }

    func save(_ value: MobileAgentHarnessSettings) throws {
        try validate(value)
        let data = try JSONEncoder().encode(value)
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        settings = value
        errorMessage = nil
    }

    func setEnabled(_ enabled: Bool, skillID: String) throws {
        var value = settings
        if enabled { value.disabledSkillIDs.remove(skillID) } else { value.disabledSkillIDs.insert(skillID) }
        try save(value)
    }

    @discardableResult
    func install(from url: URL) throws -> MobileAgentHarnessSkill {
        guard url.pathExtension.lowercased() == "md" else {
            throw HarnessError.invalidSkill("Choose a Markdown skill file, such as SKILL.md.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 64 * 1024 + 1) ?? Data()
        guard data.count <= 64 * 1024, let content = String(data: data, encoding: .utf8),
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HarnessError.invalidSkill("A skill must contain UTF-8 instructions and be at most 64 KB.")
        }
        let metadata = EditorAgentSkillStore.parseSkill(content: content, skillFileURL: url)
        let name = content.hasPrefix("---") || url.lastPathComponent == "SKILL.md"
            ? metadata.name : url.deletingPathExtension().lastPathComponent
        let skill = MobileAgentHarnessSkill(
            id: UUID().uuidString, name: name, summary: metadata.description ?? "Imported instructions", content: content
        )
        var value = settings
        guard !value.installedSkills.contains(where: { $0.content == content }) else {
            throw HarnessError.invalidSkill("This skill is already installed.")
        }
        value.installedSkills.append(skill)
        try save(value)
        return skill
    }

    func remove(skillID: String) throws {
        var value = settings
        value.installedSkills.removeAll { $0.id == skillID }
        value.disabledSkillIDs.remove(skillID)
        try save(value)
    }

    private func validate(_ value: MobileAgentHarnessSettings) throws {
        guard (1...200).contains(value.maxToolRounds), (0...2).contains(value.repairAttempts),
              value.instructions.utf8.count <= 16 * 1024,
              value.installedSkills.count <= 32,
              value.installedSkills.allSatisfy({ !$0.content.isEmpty && $0.content.utf8.count <= 64 * 1024 }),
              value.installedSkills.reduce(0, { $0 + $1.content.utf8.count }) <= 256 * 1024 else {
            throw HarnessError.invalidSkill("Agent settings exceed their limits: 16 KB instructions, 32 skills and 256 KB of skill content.")
        }
    }

    enum HarnessError: LocalizedError {
        case invalidSkill(String)

        var errorDescription: String? {
            switch self {
            case .invalidSkill(let message): message
            }
        }
    }
}
