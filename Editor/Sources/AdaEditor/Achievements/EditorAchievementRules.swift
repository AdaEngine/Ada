@_spi(AdaEngine) import AdaEngine
import Foundation

/// Evaluated at document commits and successful runtime loads, never in the frame loop.
@MainActor
enum EditorAchievementRules {
    static func savedScene(_ scene: EditorSceneModel, previous: EditorSceneModel?, source: URL, resourceRoot: URL?) -> [EditorAchievementID: Int] {
        var result: [EditorAchievementID: Int] = [.firstScene: 1]
        let entities = scene.entities.filter { $0.id != scene.rootEntityID }
        let childCounts = Dictionary(grouping: scene.entities, by: \.parent).mapValues(\.count)
        let previousComponents = Dictionary((previous?.entities ?? []).map { ($0.id, $0.components) }, uniquingKeysWith: { first, _ in first })
        result[.population] = entities.count
        if entities.count == 42 {
            result[.answer42] = 1
        }
        let standard: Set<String> = [
            EditorBuiltInComponentType.transform,
            EditorBuiltInComponentType.globalTransform,
            EditorBuiltInComponentType.visibility,
            EditorBuiltInComponentType.bounding,
            EditorSceneYAMLDocument.editorGizmoComponentName,
        ]
        for entity in scene.entities {
            let components = entity.components
            let before = previousComponents[entity.id]
            if (childCounts[entity.id] ?? 0) >= 3 {
                result[.hierarchy] = 1
            }
            if Set(components.keys).subtracting(standard).count >= 3 {
                result[.components] = 1
            }
            if components[EditorBuiltInComponentType.light2D] != nil,
                before?[EditorBuiltInComponentType.light2D] == nil {
                result[.firstLight] = 1
            }
            if let camera = components[EditorBuiltInComponentType.camera],
                let old = before?[EditorBuiltInComponentType.camera], camera != old {
                result[.camera] = 1
            }
            if let sprite = components[EditorBuiltInComponentType.sprite] {
                if let reference = sprite["texture"]?.stringValue,
                    reference != before?[EditorBuiltInComponentType.sprite]?["texture"]?.stringValue,
                    localAsset(reference, source: source, root: resourceRoot) != nil {
                    result[.firstSprite] = 1
                }
                if sprite["flipX"]?.boolValue == true, sprite["flipY"]?.boolValue == true {
                    result[.flip] = 1
                }
            }
        }
        for clip in scene.animations ?? []
            where Set(clip.tracks.filter(hasMotion).map(\.property)).count >= 3 {
            result[.choreography] = 1
        }
        let depth = nestedDepth(scene, source: source, root: resourceRoot, visited: [source.standardizedFileURL.path], remaining: 2)
        if depth >= 1 {
            result[.sceneInstance] = 1
        }
        if depth >= 2 {
            result[.inception] = 1
        }
        return result
    }

    static func savedUI(_ document: UISceneDocument, previous: UISceneDocument?) -> [EditorAchievementID: Int] {
        var result: [EditorAchievementID: Int] = [:]
        var nodes: [UINodeDescription] = []
        var previousIDs: Set<String> = []
        previous?.root.visit { previousIDs.insert($0.id) }
        document.root.visit { nodes.append($0) }
        if nodes.contains(where: { $0.id != document.root.id && !previousIDs.contains($0.id) }) {
            result[.firstUI] = 1
        }
        let containers: Set<String> = ["VStack", "HStack", "ZStack", "ScrollView"]
        let content = nodes.filter { !containers.contains($0.type) && $0.type != "Spacer" }.count
        func hasNestedContainer(_ node: UINodeDescription, inside: Bool) -> Bool {
            let isContainer = containers.contains(node.type)
            if inside && isContainer {
                return true
            }
            return (node.children + node.modifiers.flatMap(\.children)).contains { hasNestedContainer($0, inside: inside || isContainer) }
        }
        if content >= 5, hasNestedContainer(document.root, inside: false) {
            result[.layout] = 1
        }
        if nodes.contains(where: { $0.type == "Text" && $0.arguments.values.contains(where: { $0.value?.string == "Hello, Ada!" }) }) {
            result[.helloAda] = 1
        }
        return result
    }

    static func playedScene(_ scene: EditorSceneModel, adaScript: Bool) -> [EditorAchievementID: Int] {
        var result: [EditorAchievementID: Int] = [.firstRun: 1]
        for entity in scene.entities where entity.enabled != false {
            if let physics = entity.components[EditorBuiltInComponentType.physicsBody2D],
                case let .array(shapes) = physics["shapes"], !shapes.isEmpty {
                let dynamic: Bool
                if case let .object(mode) = physics["mode"] {
                    dynamic = mode["dynamic"] != nil
                } else {
                    dynamic = physics["mode"]?.stringValue == "dynamic"
                }
                if dynamic {
                    result[.physics] = 1
                    if entity.name == "Apple" {
                        result[.newton] = 1
                    }
                }
            }
            if adaScript, case let .array(scripts) = entity.components[EditorBuiltInComponentType.scriptableComponents]?["scripts"], !scripts.isEmpty {
                result[.script] = 1
            }
            if adaScript, let payload = entity.components[EditorBuiltInComponentType.uiComponent],
                let bindings = payload["scriptBindings"]?.stringValue,
                let decoded = try? JSONDecoder().decode([String: UIScriptFieldBinding].self, from: Data(bindings.utf8)), !decoded.isEmpty,
                case let .array(scripts) = entity.components[EditorBuiltInComponentType.scriptableComponents]?["scripts"],
                decoded.values.allSatisfy({ mapping in
                    let matches = scripts.compactMap { value -> EditorComponentPayload? in
                        guard
                            case let .object(script) = value, script["type"]?.stringValue == mapping.script,
                            case let .object(fields) = script["payload"]
                        else {
                            return nil
                        }
                        return fields
                    }
                    return matches.count == 1 && matches[0][mapping.field] != nil
                }) {
                result[.binding] = 1
            }
        }
        return result
    }

    static func hasMotion(_ track: EditorAnimationTrack) -> Bool {
        guard let first = track.keyframes.first else {
            return false
        }
        return track.keyframes.contains { $0.time != first.time && $0.value != first.value }
    }

    private static func nestedDepth(_ scene: EditorSceneModel, source: URL, root: URL?, visited: Set<String>, remaining: Int) -> Int {
        guard remaining > 0 else {
            return 0
        }
        var maximum = 0
        for entity in scene.entities {
            guard
                let reference = entity.components[EditorBuiltInComponentType.sceneInstance]?["scene"]?.stringValue,
                let url = localAsset(reference, source: source, root: root), !visited.contains(url.path),
                let content = try? String(contentsOf: url, encoding: .utf8),
                let child = try? EditorSceneModel.decode(from: content)
            else {
                continue
            }
            maximum = max(maximum, 1 + nestedDepth(child, source: url, root: root, visited: visited.union([url.path]), remaining: remaining - 1))
            if maximum == remaining {
                return maximum
            }
        }
        return maximum
    }

    private static func localAsset(_ reference: String, source: URL, root: URL?) -> URL? {
        guard !reference.isEmpty else {
            return nil
        }
        let url: URL
        if reference.hasPrefix("@res://"), let root {
            url = root.appendingPathComponent(String(reference.dropFirst(7)))
        } else if reference.hasPrefix("file://"), let file = URL(string: reference) {
            url = file
        } else if reference.hasPrefix("/") {
            url = URL(fileURLWithPath: reference)
        } else if reference.contains("://") {
            return nil
        } else {
            url = source.deletingLastPathComponent().appendingPathComponent(reference)
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        if let root {
            let allowed = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard resolved.path.hasPrefix(allowed) else {
                return nil
            }
        }
        guard FileManager.default.fileExists(atPath: resolved.path) else {
            return nil
        }
        return resolved
    }
}
