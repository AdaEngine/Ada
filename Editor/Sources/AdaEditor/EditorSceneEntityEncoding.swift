import Foundation
import Yams

extension EditorSceneModel {
    private static let largeSceneThreshold = 128 * 1024

    /// Reuse the original blocks for unchanged entities in large, flat block-style YAML files.
    func encodedYAML(updatingEntitiesFrom previous: Self, in source: String) throws -> String {
        if let json = encodedAsJSONIfNeeded(for: source) {
            return json
        }
        guard source.utf8.count >= Self.largeSceneThreshold,
              format == previous.format, schemaVersion == previous.schemaVersion,
              engineVersion == previous.engineVersion, scene == previous.scene,
              let original = SceneEntityYAMLBlocks(source, entities: previous.entities) else {
            return try encodedYAML()
        }
        var bytes = Data()
        bytes.reserveCapacity(original.data.count)
        bytes.append(original.data[original.header])
        if entities.isEmpty {
            bytes.append(contentsOf: " []\n".utf8)
        } else {
            bytes.append(0x0a)
        }
        let encoder = YAMLEncoder()
        for entity in entities {
            if let entry = original.entries[entity.id], previous.entities[entry.index] == entity {
                bytes.append(original.data[entry.range])
                if bytes.last != 0x0a { bytes.append(0x0a) }
            } else {
                bytes.append(contentsOf: try encoder.encode([entity]).utf8)
            }
        }
        if animations != nil || editor != nil {
            bytes.append(contentsOf: try encoder.encode(SceneEntityYAMLTail(animations: animations, editor: editor)).utf8)
        }
        return try String(bytes: bytes, encoding: .utf8) ?? encodedYAML()
    }

    func encodedAsJSONIfNeeded(for source: String) -> String? {
        // Generated scenes may be JSON. Retain that representation instead of building a YAML node tree.
        let start = source.firstIndex { !$0.isWhitespace && $0 != "\u{FEFF}" }
        guard let start, source[start] == "{", source[source.index(after: start)...].first(where: { !$0.isWhitespace }) == "\"" else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // JSON collapses distinctions such as an integral Double and an Int.
        guard let data = try? encoder.encode(self), let content = String(bytes: data, encoding: .utf8),
              (try? Self.decode(from: content)) == self else {
            return nil
        }
        return content
    }
}

private struct SceneEntityYAMLTail: Encodable {
    let animations: [EditorAnimationClip]?
    let editor: EditorSceneState?
}

private struct SceneEntityYAMLBlocks {
    let data: Data
    let header: Range<Int>
    let entries: [String: (index: Int, range: Range<Int>)]

    init?(_ source: String, entities: [EditorSceneEntity]) {
        let data = Data(source.utf8)
        guard !entities.isEmpty, data.starts(with: Data("format:".utf8)),
              // Anchors can couple an otherwise unchanged block to an edited one.
              data.range(of: Data("&".utf8)) == nil, data.range(of: Data("*".utf8)) == nil,
              let start = data.range(of: Data("\nentities:\n".utf8)) else {
                  return nil
              }
        guard start.lowerBound <= 16 * 1024,
              let headerText = String(bytes: data[..<start.lowerBound], encoding: .utf8),
              let header = try? Yams.compose(yaml: headerText)?.mapping,
              header.keys.allSatisfy({ ["format", "schemaVersion", "engineVersion", "scene"].contains($0.string ?? "") }) else {
            return nil
        }
        let entityStart = Data("\n- id: ".utf8)
        let tailStart = ["\nanimations:", "\neditor:", "\n..."].compactMap {
            data.range(of: Data($0.utf8), in: start.upperBound..<data.endIndex)?.lowerBound
        }.min().map { $0 + 1 } ?? data.endIndex
        var cursor = start.upperBound
        var indexed: [String: (index: Int, range: Range<Int>)] = [:]
        for (index, entity) in entities.enumerated() {
            let prefix = Data("- id: \(entity.id)\n".utf8)
            guard cursor < tailStart, data[cursor..<tailStart].starts(with: prefix) else {
                return nil
            }
            let boundary = data.range(of: entityStart, in: (cursor + prefix.count - 1)..<tailStart)
            guard (boundary == nil) == (index == entities.count - 1) else {
                return nil
            }
            let end = boundary.map { $0.lowerBound + 1 } ?? Self.endOfLastBlock(
                in: data,
                range: (cursor + prefix.count - 1)..<tailStart
            )
            guard indexed.updateValue((index, cursor..<end), forKey: entity.id) == nil else {
                return nil
            }
            cursor = end
        }
        self.data = data
        self.header = data.startIndex..<(start.upperBound - 1)
        self.entries = indexed
    }

    private static func endOfLastBlock(in data: Data, range: Range<Int>) -> Int {
        var startsLine = false
        for (offset, byte) in data[range].enumerated() {
            // A new key at column zero ends the root-level sequence.
            if startsLine, byte != 0x20, byte != 0x09, byte != 0x0a, byte != 0x0d, byte != 0x23 {
                return range.lowerBound + offset
            }
            startsLine = byte == 0x0a
        }
        return range.upperBound
    }
}
