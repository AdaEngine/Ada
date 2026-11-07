import Foundation
import MCP
import Yams

struct FlowError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) { errorDescription = message }
}

struct StudioInteractionFlow {
    struct Target: Decodable {
        let id: String
        let anchor: String?

        var isValid: Bool {
            !id.isEmpty && (anchor == nil || (anchor == "translate.x" && id == "AdaEditor.SceneViewport.Surface"))
        }
    }

    struct Offset: Decodable {
        let x: Float
        let y: Float
    }

    struct Drag: Decodable {
        enum End: String, Decodable { case release, cancel }

        let from: Target
        let to: Target?
        let by: Offset?
        let durationMs: Int
        let end: End?
    }

    struct Key: Decodable {
        let key: String
        let modifiers: [String]?
    }

    struct Assertion: Decodable {
        let entity: String
        let position: [Float]?
        let tolerance: Float?
        let parent: String?
        let undoCount: Int?
    }

    enum Step {
        case tapOn(Target)
        case drag(Drag)
        case pressKey(Key)
        case assertScene(Assertion)

        var command: String {
            switch self {
            case .tapOn: "tapOn"
            case .drag: "drag"
            case .pressKey: "pressKey"
            case .assertScene: "assertScene"
            }
        }
    }

    let steps: [Step]

    init(source: String) throws {
        guard source.utf8.count <= 65_536 else { throw FlowError("Flow exceeds 64 KiB.") }
        let envelope = try YAMLDecoder().decode(Value.self, from: source)
        guard let root = envelope.objectValue, Set(root.keys) == ["version", "profile", "steps"],
              root["version"]?.intValue == 1, root["profile"]?.stringValue == "studio-ui",
              let steps = root["steps"]?.arrayValue, (1...64).contains(steps.count) else {
            throw FlowError("Expected version 1, profile studio-ui and 1–64 steps.")
        }
        self.steps = try steps.enumerated().map { index, value in
            do {
                return try Self.parseStep(value)
            } catch {
                throw FlowError("Step \(index + 1): \(error.localizedDescription)")
            }
        }
    }

    private static func parseStep(_ value: Value) throws -> Step {
        guard let object = value.objectValue, object.count == 1, let (command, args) = object.first else {
            throw FlowError("Expected one command per step.")
        }
        switch command {
        case "tapOn":
            let target = try decode(Target.self, args, keys: ["id"])
            guard target.isValid else { throw FlowError("tapOn needs a non-empty id.") }
            return .tapOn(target)
        case "drag":
            let drag = try decode(Drag.self, args, keys: ["from", "to", "by", "durationMs", "end"])
            _ = try decode(Target.self, args.objectValue?["from"], keys: ["id", "anchor"])
            if let to = args.objectValue?["to"] {
                _ = try decode(Target.self, to, keys: ["id"])
            }
            if let by = args.objectValue?["by"] {
                _ = try decode(Offset.self, by, keys: ["x", "y"])
            }
            guard drag.from.isValid, drag.to?.isValid != false, (drag.to == nil) != (drag.by == nil),
                  (80...2000).contains(drag.durationMs),
                  [drag.by?.x, drag.by?.y].compactMap({ $0 }).allSatisfy({ $0.isFinite && abs($0) <= 4000 }) else {
                throw FlowError("drag needs a valid from, one destination and durationMs from 80 to 2000.")
            }
            return .drag(drag)
        case "pressKey":
            let key = try decode(Key.self, args, keys: ["key", "modifiers"])
            guard key.key == "z", key.modifiers == ["main"] || key.modifiers == ["main", "shift"] else {
                throw FlowError("This profile supports main+z and main+shift+z.")
            }
            return .pressKey(key)
        case "assertScene":
            let assertion = try decode(Assertion.self, args, keys: ["entity", "position", "tolerance", "parent", "undoCount"])
            guard !assertion.entity.isEmpty,
                  assertion.position != nil || assertion.parent != nil || assertion.undoCount != nil,
                  assertion.position.map({ $0.count == 3 && $0.allSatisfy(\.isFinite) }) != false,
                  assertion.undoCount.map({ $0 >= 0 }) != false,
                  assertion.tolerance.map({ $0.isFinite && $0 >= 0 }) != false else {
                throw FlowError("assertScene needs an entity and a valid position, parent or undoCount expectation.")
            }
            return .assertScene(assertion)
        default:
            throw FlowError("Unknown command '\(command)'.")
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ value: Value?, keys: Set<String>) throws -> T {
        guard let value, let object = value.objectValue, Set(object.keys).isSubset(of: keys) else {
            throw FlowError("Unexpected fields or missing command arguments.")
        }
        return try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
    }
}
