enum EditorSceneEntityTemplateGroup: String, CaseIterable, Hashable, Sendable {
    case general = "General"
    case twoD = "2D"
    case threeD = "3D"
    case gameplay = "Gameplay"

    var templates: [EditorSceneEntityTemplate] {
        EditorSceneEntityTemplate.allCases.filter { $0.group == self }
    }
}

enum EditorSceneEntityTemplate: String, CaseIterable, Hashable, Sendable {
    case empty
    case scriptable
    case sceneInstance
    case camera2D
    case sprite
    case mesh2D
    case tileMap
    case light2D
    case camera3D
    case model3D
    case directionalLight3D
    case pointLight3D
    case spotLight3D
    case ui
    case physicsBody2D
    case physicsBody3D

    var group: EditorSceneEntityTemplateGroup {
        switch self {
        case .empty,
            .scriptable,
            .sceneInstance:
            .general
        case .camera2D,
            .sprite,
            .mesh2D,
            .tileMap,
            .light2D:
            .twoD
        case .camera3D,
            .model3D,
            .directionalLight3D,
            .pointLight3D,
            .spotLight3D:
            .threeD
        case .ui,
            .physicsBody2D,
            .physicsBody3D:
            .gameplay
        }
    }

    var title: String {
        switch self {
        case .empty: "Empty Entity"
        case .scriptable: "Scriptable Entity"
        case .sceneInstance: "Scene Instance"
        case .camera2D: "Camera 2D"
        case .sprite: "Sprite Entity"
        case .mesh2D: "Mesh Entity 2D"
        case .tileMap: "Tile Map"
        case .light2D: "Light 2D"
        case .camera3D: "Camera 3D"
        case .model3D: "Model Entity 3D"
        case .directionalLight3D: "Directional Light 3D"
        case .pointLight3D: "Point Light 3D"
        case .spotLight3D: "Spot Light 3D"
        case .ui: "UI Entity"
        case .physicsBody2D: "Physics Body 2D"
        case .physicsBody3D: "Physics Body 3D"
        }
    }

    var detail: String {
        switch self {
        case .empty: "Transform only"
        case .scriptable: "Ready for AdaScript behaviours"
        case .sceneInstance: "Nested reusable scene"
        case .camera2D: "Orthographic camera and visibility"
        case .sprite: "Sprite renderer and visibility"
        case .mesh2D: "Built-in 2D mesh and material"
        case .tileMap: "Editable empty tile map"
        case .light2D: "2D light and visibility"
        case .camera3D: "Perspective camera and visibility"
        case .model3D: "PBR mesh, material, and visibility"
        case .directionalLight3D: "Sun-like light with shadows"
        case .pointLight3D: "Omnidirectional 3D light"
        case .spotLight3D: "Focused 3D light"
        case .ui: "AdaUI scene or AdaScript view"
        case .physicsBody2D: "Dynamic 2D rigid body"
        case .physicsBody3D: "Dynamic 3D rigid body"
        }
    }

    func matches(_ query: String) -> Bool {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        let searchable = "\(group.rawValue) \(title) \(detail) bundle entity".lowercased()
        return terms.allSatisfy { searchable.contains($0) }
    }
}
