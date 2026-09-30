import AdaEngine
import AdaScriptCompilerCore
import Foundation
import MCP

/// Offline references available on devices without access to the engine checkout.
@MainActor
enum EditorAgentKnowledge {
    static func query(name: String, arguments: [String: Value]) throws -> [String: Any] {
        let query = arguments["query"]?.stringValue ?? ""
        switch name {
        case "editor.docs.search":
            let articles = try EditorDocumentationLibrary.load().filter { matches($0.section + " " + $0.plainText, query) }
            return [
                "articles": articles.prefix(20).map {
                    ["id": $0.id, "title": $0.title, "source": $0.source, "excerpt": String($0.plainText.prefix(1200))]
                },
                "total": articles.count,
            ]
        case "editor.docs.read":
            guard let article = try EditorDocumentationLibrary.load().first(where: { $0.id == arguments["id"]?.stringValue }) else {
                throw KnowledgeError("Unknown article. Call editor.docs.search for IDs.")
            }
            return [
                "id": article.id, "source": article.source, "content": article.plainText,
                "portableRuntimeNote": "This app currently rejects @view and @resource declarations. Check editor.project.context for device capabilities.",
            ]
        case "editor.api.describe":
            let environment = AdaScriptTypeEnvironment.standard
            let types = environment.members.keys.sorted().filter {
                matches($0 + " " + (environment.members[$0] ?? [:]).keys.sorted().joined(separator: " "), query)
            }
            let constructors = RuntimeTypeRegistry.registeredRuntimeComponentConstructors().filter { matches($0.name, query) }
            return [
                "types": types.prefix(30).map { type in
                    [
                        "name": type,
                        "members": (environment.members[type] ?? [:]).sorted { $0.key < $1.key }.map { name, member in
                            ["name": name, "type": member.type.displayName, "description": member.detail ?? "", "insertText": member.insertText ?? name]
                        },
                    ] as [String: Any]
                },
                "constructors": constructors.prefix(50).map { ["name": $0.name, "parameters": $0.parameters.map(\.name)] as [String: Any] },
                "source": "Current compiler type environment and linked runtime component constructors",
            ]
        case "editor.components.describe":
            EditorComponentRegistry.registerBuiltIns()
            let components = EditorComponentRegistry.descriptors.filter { matches($0.typeName + " " + $0.displayName, query) }
            return [
                "components": try components.prefix(40).map { descriptor in
                    [
                        "typeName": descriptor.typeName, "description": descriptor.description,
                        "requiredComponents": descriptor.requiredComponentTypeNames,
                        "defaultPayload": try JSONSerialization.jsonObject(with: JSONEncoder().encode(descriptor.makeDefaultPayload())),
                        "fields": descriptor.fields.map { ["name": $0.key, "kind": String(describing: $0.kind), "editable": $0.isEditable] as [String: Any] },
                    ]
                },
                "total": components.count,
            ]
        case "editor.examples.list":
            return ["examples": examples.map { ["id": $0.id, "description": $0.description, "files": $0.files.keys.sorted()] }]
        case "editor.examples.read":
            guard let example = examples.first(where: { $0.id == arguments["id"]?.stringValue }) else {
                throw KnowledgeError("Unknown example. Call editor.examples.list for IDs.")
            }
            return [
                "id": example.id, "description": example.description, "files": example.files,
                "instructions":
                    "Adapt files with files.write and settings with editor.project.configure. Build and simulate, then add and test touch UI in Play.",
            ]
        default: throw KnowledgeError("Unknown knowledge operation.")
        }
    }

    struct Example {
        let id: String
        let description: String
        let files: [String: String]
    }

    static var examples: [Example] {
        [
            example(
                id: "keyboard-movement",
                description: "Complete scene-based AdaScript example: MoveRight/MoveLeft keyboard actions move a player Transform. Includes exact scene payloads and input configuration.",
                source: """
                    @system(id: "example.movement")
                    class Movement {
                        @res var input: Input;
                        @query(Transform) var players;
                        func update(context) {
                            var dx = input.getActionStrength("MoveRight") - input.getActionStrength("MoveLeft");
                            for (var row in players) {
                                var position = row.transform.position;
                                position[0] += dx * 120.0 * context.deltaTime;
                                row.transform.position = position;
                            }
                        }
                    }
                    """,
                actions: [InputAction(name: "MoveRight", bindings: [.key(.d), .key(.arrowRight)]), InputAction(name: "MoveLeft", bindings: [.key(.a), .key(.arrowLeft)])]
            ),
            example(
                id: "runtime-component",
                description: "Complete AdaScript dynamic component and startup/update systems. Spawns Counter data, increments it per frame, and exposes values to runtime.inspect.",
                source: """
                    @component(id: "agent.example.counter") struct Counter {
                        @export var value = 0;
                    }
                    @system(id: "example.spawn", scheduler: "startup")
                    class Spawn {
                        func update(context) { context.world.commands.spawn([Counter(value: 0)]); }
                    }
                    @system(id: "example.tick")
                    class Tick {
                        @query(Counter) var counters;
                        func update(context) {
                            for (var row in counters) { row.counter.value += 1; }
                        }
                    }
                    """,
                actions: []
            ),
        ]
    }

    private static func example(id: String, description: String, source: String, actions: [InputAction]) -> Example {
        var project = ProjectSystem.defaultProject(projectName: id, buildSystem: .adaScript)
        project.runtime.moduleName = "AgentExample_" + id.replacingOccurrences(of: "-", with: "_")
        project.runtime.entry = .init(scene: SceneDocumentFormat.defaultScenePath)
        project.runtime.plugins.preset = .ui
        project.inputActions = actions
        var model = EditorSceneModel.default(projectName: id)
        model.entities = []
        if id == "keyboard-movement" {
            let player = model.addEntity(name: "Player")
            if let index = model.entities.firstIndex(where: { $0.id == player.id }) {
                model.entities[index].components = [EditorBuiltInComponentType.transform: EditorComponentRegistry.defaultPayload(for: EditorBuiltInComponentType.transform)]
            }
        }
        do {
            let configuration = try EditorAgentToolEncoding.string(JSONEncoder().encode(project))
            return Example(
                id: id,
                description: description,
                files: [
                    ".ada/project.json": configuration,
                    "Sources/Game.ada": source,
                    SceneDocumentFormat.defaultScenePath: try model.encodedYAML(),
                ]
            )
        } catch {
            return Example(id: id, description: "Example could not be encoded: \(error.localizedDescription)", files: [:])
        }
    }

    private static func matches(_ value: String, _ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy { value.localizedStandardContains(String($0)) }
    }

    private struct KnowledgeError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
