import AdaA2UI
import Foundation

/// ACP text binding: one JSON envelope per line in a fenced `a2ui` block.
/// Other Markdown and ordinary code fences remain ordinary assistant content.
struct EditorAgentA2UIStream {
    private var pending = ""
    private var visible = ""
    private var inA2UI = false
    private var codeFenceLength = 0
    private var inCode: Bool { codeFenceLength > 0 }
    private var droppingLine = false
    private(set) var didPresentUI = false
    private let maximumLineBytes = 1_048_576

    var displayText: String {
        guard !inA2UI else {
            return visible
        }
        let trimmed = pending.trimmingCharacters(in: .whitespaces)
        if !inCode, !trimmed.isEmpty, "```a2ui".hasPrefix(trimmed) {
            return visible
        }
        return visible + pending
    }

    mutating func append(_ text: String) -> [Result<Data, A2UIValidationError>] {
        var frames: [Result<Data, A2UIValidationError>] = []
        // Scan complete lines once, rather than replaying the accumulated assistant message.
        for piece in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if piece.offset > 0 {
                frames += consumeLine()
                pending = ""
                droppingLine = false
            }
            if !droppingLine {
                pending += piece.element
                if inA2UI, pending.utf8.count > maximumLineBytes {
                    frames.append(.failure(.init(message: "A2UI envelope exceeds the byte limit.")))
                    pending = ""
                    droppingLine = true
                }
            }
        }
        return frames
    }

    mutating func finish() -> [Result<Data, A2UIValidationError>] {
        let frames = consumeLine(hasNewline: false)
        pending = ""
        droppingLine = false
        return frames
    }

    private mutating func consumeLine(hasNewline: Bool = true) -> [Result<Data, A2UIValidationError>] {
        guard !droppingLine else {
            return []
        }
        let line = pending.trimmingCharacters(in: .whitespacesAndNewlines)
        if inA2UI {
            if line == "```" {
                inA2UI = false
                return []
            }
            return line.isEmpty ? [] : [.success(Data(line.utf8))]
        }
        // Some ACP agents concatenate a planner reply and the final answer without
        // a newline. Accept an exact opener at the end of that boundary line.
        if !inCode, line.hasSuffix("```a2ui"), let opener = pending.range(of: "```a2ui", options: .backwards),
           !pending[..<opener.lowerBound].hasSuffix("\\") {
            let prose = String(pending[..<opener.lowerBound])
            if !prose.isEmpty { visible += prose + (hasNewline ? "\n" : "") }
            inA2UI = true
            didPresentUI = true
            return []
        }
        let fenceLength = line.prefix { $0 == "`" }.count
        if inCode, fenceLength >= codeFenceLength, line.allSatisfy({ $0 == "`" }) {
            codeFenceLength = 0
        } else if !inCode, fenceLength >= 3 {
            codeFenceLength = fenceLength
        }
        visible += pending + (hasNewline ? "\n" : "")
        return []
    }
}
