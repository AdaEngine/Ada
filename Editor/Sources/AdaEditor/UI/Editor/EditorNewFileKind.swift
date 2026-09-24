@_spi(AdaEngine) import AdaEngine
import Foundation

enum EditorNewFileGroup: String, CaseIterable, Hashable, Sendable {
    case adaScript = "AdaScript"
    case scenes = "Scenes"
    case shaders = "Shaders"
    case resources = "Resources"
    case swift = "Swift"

    var templates: [EditorNewFileKind] { EditorNewFileKind.allCases.filter { $0.group == self && $0 != .uiScript } }
}

enum EditorNewFileKind: String, CaseIterable, Hashable, Sendable {
    case uiScript, scriptableObject, script, emptyScript
    case scene, uiScene
    case vertexShader, fragmentShader, computeShader
    case atlas, tileSource, tileMap, plainText, localization, json, yaml
    case swift

    var group: EditorNewFileGroup {
        switch self {
        case .uiScript,
            .scriptableObject,
            .script,
            .emptyScript:
            .adaScript
        case .scene,
            .uiScene:
            .scenes
        case .vertexShader,
            .fragmentShader,
            .computeShader:
            .shaders
        case .atlas,
            .tileSource,
            .tileMap,
            .plainText,
            .localization,
            .json,
            .yaml:
            .resources
        case .swift: .swift
        }
    }

    var title: String {
        switch self {
        case .uiScript: "UI Script"
        case .scriptableObject: "Scriptable Object"
        case .script: "System"
        case .emptyScript: "Empty"
        case .scene: "Scene"
        case .uiScene: "UI Scene"
        case .vertexShader: "Vertex Shader"
        case .fragmentShader: "Fragment Shader"
        case .computeShader: "Compute Shader"
        case .atlas: "Atlas"
        case .tileSource: "Tile Source"
        case .tileMap: "Tile Map"
        case .plainText: "Plain Text"
        case .localization: "Localization"
        case .json: "JSON"
        case .yaml: "YAML"
        case .swift: "Swift File"
        }
    }

    var detail: String {
        switch self {
        case .uiScript: "Temporarily unavailable"
        case .scriptableObject: "Attachable behavior with lifecycle hooks"
        case .script: "ECS system in the update scheduler"
        case .emptyScript: "Blank AdaScript source"
        case .scene: "Ada scene"
        case .uiScene: "Declarative AdaUI scene"
        case .vertexShader: "GLSL vertex stage"
        case .fragmentShader: "GLSL fragment stage"
        case .computeShader: "GLSL compute kernel"
        case .atlas: "Packed PNG images with an atlas editor"
        case .tileSource: "PNG sprite sheets with a visual tile editor"
        case .tileMap: "Paint cells on a map resource"
        case .plainText: "Unformatted text"
        case .localization: "String table; place in a language .lproj folder"
        case .json: "Structured JSON data"
        case .yaml: "Structured YAML data"
        case .swift: "Swift source importing AdaEngine"
        }
    }

    var fileExtension: String {
        switch self {
        case .uiScript,
            .scriptableObject,
            .script,
            .emptyScript:
            "ada"
        case .scene: SceneDocumentFormat.canonicalExtension
        case .uiScene: "ui"
        case .vertexShader,
            .fragmentShader,
            .computeShader:
            "glsl"
        case .atlas: "atlas"
        case .tileSource: "tileset"
        case .tileMap: "tilemap"
        case .plainText: "txt"
        case .localization: "strings"
        case .json: "json"
        case .yaml: "yaml"
        case .swift: "swift"
        }
    }

    var icon: String {
        switch self {
        case .uiScript,
            .uiScene:
            "\u{E871}"
        case .scriptableObject: "\u{E87B}"
        case .script: "\u{E8B8}"
        case .emptyScript,
            .swift:
            "\u{E86F}"
        case .scene: "\u{F720}"
        case .vertexShader: "\u{E3E7}"
        case .fragmentShader: "\u{E3B7}"
        case .computeShader: "\u{E322}"
        case .atlas: "\u{E3B6}"
        case .tileSource: "\u{E8F1}"
        case .tileMap: "\u{E8F1}"
        case .plainText: "\u{E873}"
        case .localization: "\u{E8E2}"
        case .json,
            .yaml:
            "\u{EF42}"
        }
    }

    var tint: Color {
        switch group {
        case .adaScript: Color(red: 0.91, green: 0.73, blue: 0.30)
        case .scenes: Color(red: 0.35, green: 0.70, blue: 0.94)
        case .shaders: Color(red: 0.65, green: 0.55, blue: 0.94)
        case .resources: Color(red: 0.44, green: 0.75, blue: 0.62)
        case .swift: Color(red: 0.96, green: 0.55, blue: 0.37)
        }
    }

    func matches(_ query: String) -> Bool {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        let searchable = "\(group.rawValue) \(title) \(detail) \(fileExtension)".lowercased()
        return terms.allSatisfy { searchable.contains($0) }
    }

    func initialContent(fileName: String) -> String {
        let name = Self.typeIdentifier(URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent)
        switch self {
        case .uiScene: return (try? UISceneDocument().encodedYAML()) ?? ""
        case .scene:
            return SceneDocumentFormat.defaultSceneYAML(projectName: URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent)
        case .uiScript:
            return """
                // \(fileName)
                // AdaUI views in AdaScript are temporarily unavailable.
                """
        case .scriptableObject:
            return """
                // \(fileName)

                @scriptable(id: "game.\(name.lowercased())", version: 1)
                class \(name.hasSuffix("Script") ? name : name + "Script") {
                    func ready(context) {
                    }

                    func update(context: AdaScriptableContext) {
                    }

                    func destroy(context) {
                    }
                }
                """
        case .script:
            return """
                // \(fileName)

                @system(scheduler: "update")
                class \(name.hasSuffix("System") ? name : name + "System") {
                    func update(context: AdaSystemContext) {
                    }
                }
                """
        case .emptyScript,
            .plainText:
            return ""
        case .swift: return "import AdaEngine\n\n"
        case .atlas: return "images: []\nmargin: 0\npadding: 2\nextrude: 1\nsampler: linear\n"
        case .tileSource: return "tileSize:\n  x: 16\n  y: 16\nsources: []\n"
        case .tileMap: return "atlasColors:\n- {red: 0.48, green: 0.25, blue: 0.21, alpha: 1}\n- {red: 0.38, green: 0.48, blue: 0.62, alpha: 1}\ncells: []\n"
        case .json: return "{}\n"
        case .yaml: return "{}\n"
        case .localization:
            return "/* Add this table to a language folder, such as en.lproj. */\n\"hello\" = \"Hello\";\n"
        case .vertexShader:
            return """
                #version 450 core
                #pragma stage : vert

                layout(location = 0) in vec3 a_Position;
                layout(location = 2) in vec2 a_UV;
                layout(location = 0) out vec2 v_UV;

                [[main]]
                void vertex_main() {
                    v_UV = a_UV;
                    gl_Position = vec4(a_Position, 1.0);
                }
                """
        case .fragmentShader:
            return """
                #version 450 core
                #pragma stage : frag

                layout(location = 0) in vec2 v_UV;
                layout(location = 0) out vec4 COLOR;

                [[main]]
                void fragment_main() {
                    COLOR = vec4(v_UV, 0.5, 1.0);
                }
                """
        case .computeShader:
            return """
                #version 450 core
                #pragma stage : comp

                layout(local_size_x = 64) in;
                layout(set = 0, binding = 0, std430) buffer Values {
                    float values[];
                } data;

                [[main]]
                void compute_main() {
                    uint index = gl_GlobalInvocationID.x;
                    if (index < data.values.length()) {
                        data.values[index] = 0.0;
                    }
                }
                """
        }
    }

    private static func typeIdentifier(_ value: String) -> String {
        let joined = value.split { !$0.isASCII || (!$0.isLetter && !$0.isNumber) }
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined()
        guard let first = joined.first else {
            return "Script"
        }
        return first.isNumber ? "Script\(joined)" : joined
    }
}
