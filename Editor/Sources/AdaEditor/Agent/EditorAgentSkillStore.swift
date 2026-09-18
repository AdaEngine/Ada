import Foundation

enum EditorAgentSkillStore {
    static func discoverSkills(
        projectURL: URL,
        directories: [String],
        builtInRootURL: URL? = builtInSkillsRootURL(),
        fileManager: FileManager = .default
    ) -> [EditorAgentSkill] {
        var skillsByID: [String: EditorAgentSkill] = [:]

        if let builtInRootURL {
            for skill in discoverSkills(in: builtInRootURL, fileManager: fileManager) {
                skillsByID[skill.id] = skill
            }
        }

        var projectDirectories = directories
        if !projectDirectories.contains(".ada/skills") {
            projectDirectories.append(".ada/skills")
        }

        for directory in projectDirectories {
            let rootURL = projectURL.appendingPathComponent(directory, isDirectory: true)
            for skill in discoverSkills(in: rootURL, fileManager: fileManager) {
                skillsByID[skill.id] = skill
            }
        }

        return skillsByID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func discoverSkills(in rootURL: URL, fileManager: FileManager = .default) -> [EditorAgentSkill] {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return []
        }

        var skillFiles: [URL] = []
        if rootURL.lastPathComponent == "SKILL.md" {
            skillFiles = [rootURL]
        } else if let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator where url.lastPathComponent == "SKILL.md" {
                skillFiles.append(url)
            }
        }

        return skillFiles.compactMap { skillFile in
            guard let content = try? String(contentsOf: skillFile, encoding: .utf8) else {
                return nil
            }
            return parseSkill(content: content, skillFileURL: skillFile)
        }
    }

    static func parseSkill(content: String, skillFileURL: URL) -> EditorAgentSkill {
        let metadata = parseFrontMatter(content)
        let directoryName = skillFileURL.deletingLastPathComponent().lastPathComponent
        let declaredName = metadata["name"]?.nilIfEmpty ?? directoryName
        let id =
            metadata["id"]?.nilIfEmpty
            ?? declaredName
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9_.-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let name = displayName(for: declaredName)

        return EditorAgentSkill(
            id: id.isEmpty ? directoryName : id,
            name: name,
            description: metadata["description"]?.nilIfEmpty,
            localPath: skillFileURL.path,
            userInvocable: metadata["user_invocable"].map { $0 != "false" } ?? true,
            allowedTools: (metadata["allowed-tools"] ?? metadata["allowed_tools"])?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? [],
            instructions: content
        )
    }

    private static func builtInSkillsRootURL(bundle: Bundle = .editor) -> URL? {
        bundle.url(forResource: "AgentSkills", withExtension: nil, subdirectory: "Assets")
    }

    private static func displayName(for declaredName: String) -> String {
        guard declaredName.contains("-") else {
            return declaredName
        }
        return declaredName.split(separator: "-")
            .map { word in
                switch word.lowercased() {
                case "ada": "Ada"
                case "adaui": "AdaUI"
                default: word.prefix(1).uppercased() + word.dropFirst()
                }
            }
            .joined(separator: " ")
    }

    private static func parseFrontMatter(_ content: String) -> [String: String] {
        let lines = content.components(separatedBy: .newlines)
        guard lines.first == "---" else {
            return [:]
        }

        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            guard line != "---" else {
                break
            }
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            result[key] = value
        }
        return result
    }
}
