#if os(macOS) || os(Windows)
import Crypto
import Foundation

struct EditorLocalMCPTool: Identifiable, Sendable {
    let id: String
    let alias: String
    let description: String
    let schema: EditorLocalMCPToolSchema?
    let fingerprint: String?

    init?(server: UUID, value: EditorCloudValue) {
        guard let name = value["name"].string, (1...128).contains(name.utf8.count), !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        id = name
        let nameHash = Self.hash(Data(name.utf8))
        alias = "mcp.\(server.uuidString.lowercased()).\(nameHash.prefix(32))"
        description = Self.clean(value["description"].string ?? "", limit: 300, multiline: false)
        schema = try? EditorLocalMCPToolSchema(value["inputSchema"])
        fingerprint = schema.flatMap { try? Self.hash(Self.encode($0.value)) }
    }

    func detail(serverName: String) -> EditorCloudValue {
        ["tool": .string(alias), "name": .string(id), "server": .string(serverName), "description": .string(description), "inputSchema": schema?.value ?? .null]
    }

    static func discover(_ values: [EditorCloudValue], server: UUID) throws -> [Self] {
        let tools = values.compactMap { Self(server: server, value: $0) }
        guard tools.count == values.count, Set(tools.map(\.id)).count == tools.count else { throw EditorLocalMCPConnection.Failure.invalidResponse }
        return tools.sorted { $0.id < $1.id }
    }

    static func boundedResult(_ reply: EditorCloudValue) throws -> String {
        let structured = reply["structuredContent"]
        var result: [String: EditorCloudValue] = [:]
        var truncated = false
        if structured != .null {
            if EditorLocalMCPToolSchema.isBounded(structured, remaining: 6_000, depth: 0), try encode(structured).count <= 8_000 { result["result"] = structured }
            else { truncated = true }
        }
        let content = reply["content"].array
        var remaining = 2_000
        var text: [EditorCloudValue] = []
        for item in content.prefix(16) where item["type"].string == "text" {
            guard let value = item["text"].string, remaining > 0 else { truncated = true; continue }
            let safe = clean(value, limit: remaining, multiline: true)
            truncated = truncated || safe != value
            remaining -= safe.utf8.count
            text.append(.string(safe))
        }
        if !text.isEmpty { result["text"] = .array(text) }
        if content.count > text.count || truncated { result["truncated"] = true }
        return try EditorAgentToolEncoding.string(encode(.object(result)))
    }

    static func clean(_ text: String, limit: Int, multiline: Bool) -> String {
        var result = ""
        var available = limit
        for scalar in text.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar) && !(multiline && (scalar == "\n" || scalar == "\t")) { continue }
            available -= String(scalar).utf8.count
            guard available >= 0 else { break }
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    static func encode(_ value: EditorCloudValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func inputDetails(_ input: EditorCloudValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(input), as: UTF8.self)
    }

    static func hash(_ data: Data) -> String { digestString(SHA256.hash(data: data)) }

    static func digestString(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}
#endif
