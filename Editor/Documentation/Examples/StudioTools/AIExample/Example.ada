@tool(id: "studio.ai-example", name: "AI Example", version: "1.0.0", api: 1,
    platforms: ["macos", "windows"], permissions: [])
class AIExample {
    func activate(editor) {}

    func status(inputJSON) {
        return "{\"status\":\"ready\"}";
    }
}
