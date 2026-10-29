import Foundation
import Yams

extension EditorSceneModel {
    /// Selection and foldouts change no entity payloads. Reuse their original YAML bytes when
    /// the ordinary trailing editor block can be replaced independently of the scene.
    func encodedYAML(updatingEditorStateIn content: String) throws -> String {
        guard let editor, let start = Self.editorStateStart(in: content) else {
            return try encodedYAML()
        }
        let suffix = try YAMLEncoder().encode(["editor": editor])
        var updated = content
        updated.replaceSubrange(start..., with: suffix)
        return updated
    }

    static func onlyEditorStateChanged(from before: String, to after: String) -> Bool {
        guard let oldStart = editorStateStart(in: before), let newStart = editorStateStart(in: after) else { return false }
        return before[..<oldStart] == after[..<newStart]
    }

    private static func editorStateStart(in content: String) -> String.Index? {
        guard let range = content.range(of: "\neditor:", options: .backwards) else { return nil }
        let start = content.index(after: range.lowerBound)
        let tail = String(content[start...])
        // Unusual key order, flow/JSON documents or anchors use the normal complete encoder.
        // Parse only the small suffix; never build a YAML node graph for the mesh arrays.
        guard !tail.contains("&"), let node = try? Yams.compose(yaml: tail),
            let mapping = node.mapping, mapping.count == 1, mapping.first?.key.string == "editor" else {
            return nil
        }
        return start
    }
}
