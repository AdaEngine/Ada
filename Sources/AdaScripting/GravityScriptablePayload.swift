import AdaECS
import Foundation

enum GravityScriptablePayload {
    static func decode(from decoder: Decoder) throws -> [String: ReflectedFieldValue] {
        try decoder.singleValueContainer()
            .decode([String: CodableFieldValue].self)
            .mapValues(\.value)
    }

    static func encode(_ payload: [String: ReflectedFieldValue], to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(payload.mapValues(CodableFieldValue.init))
    }
}

private struct CodableFieldValue: Codable {
    let value: ReflectedFieldValue

    init(_ value: ReflectedFieldValue) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = .null
        } else if let decoded = try? container.decode(Bool.self) {
            value = .bool(decoded)
        } else if let decoded = try? container.decode(Int.self) {
            value = .int(decoded)
        } else if let decoded = try? container.decode(Double.self) {
            value = .double(decoded)
        } else if let decoded = try? container.decode(String.self) {
            value = .string(decoded)
        } else if let decoded = try? container.decode([Self].self) {
            value = .array(decoded.map(\.value))
        } else if let decoded = try? container.decode([String: Self].self) {
            value = .object(decoded.mapValues(\.value))
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported scriptable field value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(values):
            try container.encode(values.map(Self.init))
        case let .object(values):
            try container.encode(values.mapValues(Self.init))
        }
    }
}
