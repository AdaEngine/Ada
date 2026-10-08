import MCP

/// Offline knowledge has one inventory for desktop MCP and the portable agent.
enum EditorAgentKnowledgeTools {
    static func tools() -> [Tool] {
        let query: Value = .object(["type": "string", "description": "Search words; omit to list available entries."])
        return [
            EditorMobileAgentTools.tool("editor.docs.search", "Search the offline bundled AdaEngine and AdaScript documentation. Returns article IDs and excerpts.", ["query": query]),
            EditorMobileAgentTools.tool("editor.docs.read", "Read a bundled documentation article by ID.", ["id": .object(["type": "string"])], ["id"]),
            EditorMobileAgentTools.tool("editor.api.describe", "Read the current AdaScript compiler API catalog, including signatures and host constructors.", ["query": query]),
            EditorMobileAgentTools.tool(
                "editor.components.describe",
                "Read registered component names, required components, fields, and complete default YAML payloads.",
                ["query": query]
            ),
            EditorMobileAgentTools.tool("editor.skills.list", "List bundled Ada Studio workflow skill descriptions. Load a matching skill with editor.skills.read.", ["query": query]),
            EditorMobileAgentTools.tool(
                "editor.skills.read",
                "Read a bundled workflow skill by ID, including 3D import, PBR lighting and animation guidance.",
                ["id": .object(["type": "string"])],
                ["id"]
            ),
            EditorMobileAgentTools.tool("editor.examples.list", "List bundled complete AdaScript example projects and their files."),
            EditorMobileAgentTools.tool(
                "editor.examples.read",
                "Read complete example project files. Adapt with files.write; configure via editor.project.configure on mobile or .ada/project.json on desktop.",
                ["id": .object(["type": "string"])],
                ["id"]
            ),
        ]
    }
}
