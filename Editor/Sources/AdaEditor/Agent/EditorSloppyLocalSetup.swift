import Foundation

#if os(macOS)
    import AppKit

    @MainActor
    enum EditorSloppyLocalSetup {
        static func isSloppyTarget(_ target: AdaProjectAgentTarget?) -> Bool {
            guard let target else { return false }
            return URL(fileURLWithPath: target.command ?? "").lastPathComponent == "sloppy"
                && target.arguments.starts(with: ["acp", "serve"])
        }

        static func prepare(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Bool {
            let configURL = home.appendingPathComponent(".sloppy/sloppy.json")
            let agentIDs = availableAgentIDs(home: home)
            guard !agentIDs.isEmpty else {
                throw EditorAgentCatalogError(message: "Sloppy has no agents. Create an agent in Sloppy, then try Connect again.")
            }
            let server = try serverSettings(at: configURL)
            if server.enabled, let agentID = server.agentID, agentIDs.contains(agentID) {
                return true
            }

            let alert = NSAlert()
            alert.messageText = "Enable Sloppy ACP Server"
            alert.informativeText = "AdaEditor will enable Sloppy's local ACP Server and use the selected agent."
            alert.addButton(withTitle: "Enable & Connect")
            alert.addButton(withTitle: "Cancel")
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28), pullsDown: false)
            picker.addItems(withTitles: agentIDs)
            if let agentID = server.agentID, let index = agentIDs.firstIndex(of: agentID) {
                picker.selectItem(at: index)
            }
            alert.accessoryView = picker
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            guard let agentID = picker.selectedItem?.title else { return false }
            try enableACP(at: configURL, agentID: agentID)
            return true
        }

        static func availableAgentIDs(home: URL, fileManager: FileManager = .default) -> [String] {
            let root = home.appendingPathComponent(".sloppy/agents")
            let entries = (try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            return entries.compactMap { entry in
                guard !entry.lastPathComponent.hasPrefix("."),
                      (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      fileManager.fileExists(atPath: entry.appendingPathComponent("agent.json").path) else { return nil }
                return entry.lastPathComponent
            }.sorted()
        }

        static func enableACP(at configURL: URL, agentID: String, fileManager: FileManager = .default) throws {
            guard !agentID.isEmpty else { throw EditorAgentCatalogError(message: "Choose a Sloppy agent.") }
            let data = try Data(contentsOf: configURL)
            guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw EditorAgentCatalogError(message: "Sloppy configuration is invalid JSON.")
            }
            var acp = object["acp"] as? [String: Any] ?? [:]
            var server = acp["server"] as? [String: Any] ?? [:]
            server["enabled"] = true
            server["agentId"] = agentID
            acp["server"] = server
            object["acp"] = acp
            let permissions = try fileManager.attributesOfItem(atPath: configURL.path)[.posixPermissions]
            let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try (updated + Data("\n".utf8)).write(to: configURL, options: .atomic)
            if let permissions {
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: configURL.path)
            }
        }

        private static func serverSettings(at configURL: URL) throws -> (enabled: Bool, agentID: String?) {
            let data = try Data(contentsOf: configURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw EditorAgentCatalogError(message: "Sloppy configuration is invalid JSON.")
            }
            let server = (object["acp"] as? [String: Any])?["server"] as? [String: Any]
            let agentID = (server?["agentId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (server?["enabled"] as? Bool ?? false, agentID?.isEmpty == false ? agentID : nil)
        }
    }
#endif
