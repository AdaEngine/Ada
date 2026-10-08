import Foundation

/// Sendable JSON values at the debugger protocol boundary.
public enum DebugJSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([DebugJSON])
    case object([String: DebugJSON])

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let decoded = try? value.decode(Bool.self) { self = .bool(decoded) }
        else if let decoded = try? value.decode(Int.self) { self = .integer(decoded) }
        else if let decoded = try? value.decode(Double.self) { self = .number(decoded) }
        else if let decoded = try? value.decode(String.self) { self = .string(decoded) }
        else if let decoded = try? value.decode([DebugJSON].self) { self = .array(decoded) }
        else { self = .object(try value.decode([String: DebugJSON].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let item): try value.encode(item)
        case .integer(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        }
    }

    public subscript(_ key: String) -> DebugJSON {
        guard case .object(let values) = self else { return .null }
        return values[key] ?? .null
    }

    public var string: String? { if case .string(let value) = self { value } else { nil } }
    public var int: Int? { if case .integer(let value) = self { value } else { nil } }
    public var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var array: [DebugJSON] { if case .array(let value) = self { value } else { [] } }
}

public enum DebuggerError: Error, LocalizedError, Sendable {
    case protocolViolation(String)
    case disconnected
    case requestFailed(String)
    case timeout(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .protocolViolation(let message), .requestFailed(let message), .unavailable(let message): message
        case .disconnected: "Debugger disconnected."
        case .timeout(let command): "Debugger request timed out: \(command)."
        }
    }
}

/// Incremental DAP framing; lengths are UTF-8 bytes, not character counts.
public struct DebugMessageFramer: Sendable {
    private var buffer = Data()
    private var expectedLength: Int?
    private let maximumMessageSize = 16 * 1024 * 1024

    public init() {}

    public mutating func append(_ data: Data) throws -> [DebugJSON] {
        buffer.append(data)
        var messages: [DebugJSON] = []
        while true {
            if expectedLength == nil {
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    guard buffer.count <= 8192 else { throw DebuggerError.protocolViolation("DAP header is too large.") }
                    break
                }
                guard end.lowerBound - buffer.startIndex <= 8192,
                      let header = String(data: buffer[..<end.lowerBound], encoding: .utf8) else {
                    throw DebuggerError.protocolViolation("Invalid DAP header.")
                }
                let lengths = header.components(separatedBy: "\r\n").compactMap { line -> String? in
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
                    return parts[1].trimmingCharacters(in: .whitespaces)
                }
                guard lengths.count == 1, let length = Int(lengths[0]), length > 0, length <= maximumMessageSize else {
                    throw DebuggerError.protocolViolation("Invalid DAP Content-Length.")
                }
                expectedLength = length
                buffer.removeSubrange(..<end.upperBound)
            }
            guard let length = expectedLength, buffer.count >= length else { break }
            messages.append(try JSONDecoder().decode(DebugJSON.self, from: Data(buffer.prefix(length))))
            buffer.removeFirst(length)
            expectedLength = nil
        }
        return messages
    }

    public func finish() throws {
        guard buffer.isEmpty, expectedLength == nil else { throw DebuggerError.protocolViolation("Truncated DAP message.") }
    }

    public static func encode(_ message: DebugJSON) throws -> Data {
        let body = try JSONEncoder().encode(message)
        return Data("Content-Length: \(body.count)\r\n\r\n".utf8) + body
    }
}
