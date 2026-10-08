import Foundation

/// Some ACP adapters send provider errors as text chunks and still report end_turn.
enum EditorAgentProviderFailure {
    static func message(in text: String) -> String? {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard
            let line = lines.last,
            lines.dropLast().allSatisfy({ $0.hasPrefix("Warning:") })
        else {
            return nil
        }
        do {
            guard
                let data = String(line).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["type"] as? String == "error",
                let status = object["status"] as? Int, status >= 400,
                let error = object["error"] as? [String: Any],
                let message = error["message"] as? String, !message.isEmpty
            else {
                return nil
            }
            return message
        }
    }
}
