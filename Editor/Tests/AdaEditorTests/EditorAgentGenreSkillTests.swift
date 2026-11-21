import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Editor agent genre skills", .serialized)
struct EditorAgentGenreSkillTests {
    /// The 69 genre names mirrored from the upstream chipset sheets
    /// (Donchitos/Claude-Code-Game-Studios, MIT). Keep in sync with
    /// `Sources/AdaEditor/Assets/AgentSkills/ada-genre-*/`.
    private static let genreNames: [String] = [
        "action-adventure", "action-roguelite", "action-rpg", "arcade-classic",
        "arcade-sports", "async-multiplayer", "auto-battler", "battle-royale",
        "beat-em-up", "board-and-abstract", "card-battler", "character-action",
        "city-builder", "co-op", "colony-sim", "competitive-multiplayer",
        "cozy-cleanup", "creature-collector", "detective", "dungeon-crawler",
        "endless-runner", "extraction", "factory-automation",
        "falling-block-puzzle", "farming-life-sim", "fighting",
        "first-person-shooter", "fishing", "flight", "grid-puzzle",
        "hidden-object", "idle-incremental", "level-maker", "logic-puzzle",
        "management-tycoon", "metroidvania", "mining", "mmo", "moba", "parkour",
        "party-game", "pet-raising", "physics-puzzle", "platformer",
        "point-and-click", "puzzle-platformer", "racing", "real-time-strategy",
        "rhythm", "roguelike-deckbuilder", "sailing", "sandbox", "shoot-em-up",
        "skate-and-surf", "soulslike", "stealth", "survival-crafting",
        "survival-horror", "survivors-like", "tactical-rpg", "tower-defense",
        "traditional-roguelike", "trivia-quiz", "turn-based-jrpg",
        "turn-based-strategy", "twin-stick-shooter", "visual-novel",
        "walking-sim", "word-game",
    ]

    private static let sharedSkillIDs = [
        "ada-genres", "ada-genres-mashups", "ada-genres-art-direction",
    ]

    private func bundledSkills() -> [EditorAgentSkill] {
        EditorAgentSkillStore.discoverSkills(
            projectURL: URL(fileURLWithPath: "/tmp/NoGenreProjectSkills", isDirectory: true),
            directories: []
        )
    }

    @Test("all 69 genre skills and the three shared skills are discoverable")
    func genreSkillsAreDiscoverable() {
        let ids = Set(bundledSkills().map(\.id))
        for name in Self.genreNames {
            #expect(ids.contains("ada-genre-\(name)"), "missing ada-genre-\(name)")
        }
        for id in Self.sharedSkillIDs {
            #expect(ids.contains(id), "missing \(id)")
        }
    }

    @Test("genre-word queries match the expected genre skills")
    func genreQueriesMatch() throws {
        let expectations: [String: String] = [
            "platformer": "ada-genre-platformer",
            "metroidvania": "ada-genre-metroidvania",
            "tower defense": "ada-genre-tower-defense",
            "roguelike": "ada-genre-traditional-roguelike",
            "tycoon": "ada-genre-management-tycoon",
            "fishing": "ada-genre-fishing",
            "rhythm": "ada-genre-rhythm",
        ]
        for (query, expectedID) in expectations {
            let result = try EditorAgentKnowledge.query(
                name: "editor.skills.list",
                arguments: ["query": .string(query)]
            )
            let ids = (result["skills"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? []
            #expect(ids.contains(expectedID), "query '\(query)' should match \(expectedID)")
        }
    }

    @Test("every bundled skill has a non-empty name and description")
    func skillsHaveMetadata() {
        for skill in bundledSkills() {
            #expect(!skill.name.isEmpty, "\(skill.id) has an empty name")
            #expect(skill.description?.isEmpty == false, "\(skill.id) has no description")
        }
    }

    @Test("every genre skill carries the MIT attribution footer and NOTICE exists")
    func genreSkillsHaveAttribution() throws {
        let skills = bundledSkills()
        for name in Self.genreNames {
            let skill = try #require(skills.first { $0.id == "ada-genre-\(name)" })
            #expect(
                skill.instructions.contains("Adapted from Donchitos/Claude-Code-Game-Studios (MIT)"),
                "ada-genre-\(name) misses the attribution footer"
            )
        }
        let firstSkill = try #require(skills.first)
        let noticeURL = URL(fileURLWithPath: firstSkill.localPath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("NOTICE.md")
        #expect(FileManager.default.fileExists(atPath: noticeURL.path), "AgentSkills/NOTICE.md is missing")
    }

    @Test("router skill links the mashups and art-direction skills and the online stand-in policy")
    func routerSkillContent() throws {
        let skill = try #require(bundledSkills().first { $0.id == "ada-genres" })
        #expect(skill.instructions.contains("ada-genres-mashups"))
        #expect(skill.instructions.contains("ada-genres-art-direction"))
        #expect(skill.instructions.contains("stand-in"))
    }
}
