import AdaStudioCore
import Foundation
import Yams

/// Decodes YAML scenes without sending component payloads through `Codable`.
///
/// `StudioValue.init(from:)` probes Bool, Int, UInt64, Double and String for every scalar; through
/// `YAMLDecoder` each failed probe builds a `DecodingError`. Scenes with physics or mesh data hold
/// millions of scalars, which made opening them take minutes. This path parses the document once,
/// converts component payloads with the same Yams constructors in the same order, and decodes only the
/// remaining envelope (scene metadata, entity identity, editor state) with `YAMLDecoder`.
enum EditorSceneYAMLPayloadDecoder {
    /// The document shape this path does not handle; callers fall back to the full `YAMLDecoder` path.
    struct Unsupported: Error {}

    private static let mergeOnlyResolver = Resolver.basic.appending(.merge)

    static func decode(_ content: String) throws -> EditorSceneModel {
        // Same parser configuration as `YAMLDecoder.decode(_:from: String)`: a merge-only resolver.
        let parser = try Parser(yaml: content, resolver: mergeOnlyResolver, encoding: .utf8)
        return try withExtendedLifetime(parser) {
            guard let root = try parser.singleRoot(), case var .mapping(document) = root,
                  case var .sequence(entities)? = document["entities"] else {
                throw Unsupported()
            }
            var payloads: [[String: EditorComponentPayload]] = []
            payloads.reserveCapacity(entities.count)
            for index in entities.indices {
                guard case var .mapping(entity) = entities[index], case let .mapping(components)? = entity["components"] else {
                    throw Unsupported()
                }
                var typed: [String: EditorComponentPayload] = [:]
                for (name, component) in try keyedValues(components) {
                    guard case let .mapping(payload) = component else {
                        throw Unsupported()
                    }
                    typed[name] = try keyedValues(payload).mapValues(value)
                }
                payloads.append(typed)
                entity["components"] = .mapping([:])
                entities[index] = .mapping(entity)
            }
            document["entities"] = .sequence(entities)
            var model = try YAMLDecoder(encoding: .utf8).decode(EditorSceneModel.self, from: Node.mapping(document))
            guard model.entities.count == payloads.count else {
                throw Unsupported()
            }
            for index in model.entities.indices {
                model.entities[index].components = payloads[index]
            }
            return model
        }
    }

    /// Mirrors Yams' keyed container used by `Dictionary<String, _>.init(from:)`: keys come from each key
    /// node's string, and each value is the one `Node.Mapping[string]` resolves for that key.
    private static func keyedValues(_ source: Node.Mapping) throws -> [String: Node] {
        let needsFlattening = source.keys.contains { key in
            let tag = Tag.Name(rawValue: key.tag.rawValue)
            return tag == .merge || tag == .value
        }
        let mapping = needsFlattening ? Node.Mapping(try flattened(source), source.tag, source.style) : source
        var result: [String: Node] = [:]
        result.reserveCapacity(mapping.count)
        for key in mapping.keys {
            guard let name = key.string else {
                continue
            }
            // Yams' keyed container hides its anchor/tag marker keys; leave such payloads to `YAMLDecoder`.
            guard name != "yamlAnchor", name != "yamlTag", let node = mapping[name] else {
                throw Unsupported()
            }
            result[name] = node
        }
        return result
    }

    /// Mirrors Yams' internal `Node.Mapping.flatten()`, applied by every keyed container: `<<` merge
    /// sources come first (sequence sources in reverse), so the mapping's own keys win on lookup.
    private static func flattened(_ mapping: Node.Mapping) throws -> [(Node, Node)] {
        var own: [(Node, Node)] = []
        var merged: [(Node, Node)] = []
        for pair in mapping {
            switch Tag.Name(rawValue: pair.key.tag.rawValue) {
            case .merge:
                switch pair.value {
                case let .mapping(source):
                    merged += try flattened(source)
                case let .sequence(sources):
                    for source in sources.compactMap(\.mapping).reversed() {
                        merged += try flattened(source)
                    }
                default:
                    break
                }
            case .value:
                // Yams rewrites these key tags in place; leave such documents to `YAMLDecoder`.
                throw Unsupported()
            default:
                own.append((pair.key, pair.value))
            }
        }
        return merged + own
    }

    /// Mirrors `StudioValue.init(from:)` for a `YAMLDecoder` single-value container.
    static func value(_ node: Node) throws -> StudioValue {
        switch node {
        case let .scalar(scalar):
            return try scalarValue(scalar)
        case let .sequence(sequence):
            var values: [StudioValue] = []
            values.reserveCapacity(sequence.count)
            for element in sequence {
                values.append(try value(element))
            }
            return .array(values)
        case let .mapping(mapping):
            return .object(try keyedValues(mapping).mapValues(value))
        case .alias:
            throw Unsupported()
        }
    }

    /// Same probe order as `StudioValue.init(from:)`. `decodeNil()` is `node.null`, which uses
    /// `NSNull.construct(from:)` directly.
    private static func scalarValue(_ scalar: Node.Scalar) throws -> StudioValue {
        if NSNull.construct(from: scalar) != nil {
            return .null
        } else if let value = construct(Bool.self, scalar) {
            return .bool(value)
        } else if let value = construct(Int.self, scalar) {
            return .int(value)
        } else if let value = construct(UInt64.self, scalar) {
            return .uint(value)
        } else if let value = construct(Double.self, scalar) {
            return .double(value)
        } else if let value = construct(String.self, scalar) {
            return .string(value)
        }
        throw Unsupported()
    }

    /// Generic so each type uses its `ScalarConstructible` witness, exactly as `YAMLDecoder` does.
    private static func construct<T: ScalarConstructible>(_: T.Type, _ scalar: Node.Scalar) -> T? {
        T.construct(from: scalar)
    }
}
