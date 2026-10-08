import AdaUIDescription
import Foundation

/// A validation failure that can be returned to the originating agent for correction.
public struct A2UIValidationError: Error, LocalizedError, Hashable, Sendable {
    public let surfaceID: String
    public let path: String
    public let message: String
    public var errorDescription: String? { "\(path): \(message)" }

    public init(surfaceID: String = "", path: String = "/", message: String) {
        self.surfaceID = surfaceID
        self.path = path
        self.message = message
    }

    public var envelope: UIValue {
        .object([
            "error": .object([
                "code": .string("VALIDATION_FAILED"),
                "surfaceId": .string(surfaceID),
                "path": .string(path),
                "message": .string(message)
            ])
        ])
    }
}

/// A transport-independent outgoing envelope and its transport metadata.
/// Hosts route these messages only to the agent that owns this client session.
public struct A2UIClientEvent: Hashable, Sendable {
    public let envelope: UIValue
    public let metadata: UIValue

    public init(envelope: UIValue, metadata: UIValue = .object([:])) {
        self.envelope = envelope
        self.metadata = metadata
    }
}

struct A2UIMessage {
    let kind: String
    let surfaceID: String
    let body: [String: UIValue]

    init(json: Data, maximumBytes: Int) throws {
        guard json.count <= maximumBytes else {
            throw A2UIValidationError(message: "Message exceeds the byte limit.")
        }
        let value: UIValue
        do { value = try JSONDecoder().decode(UIValue.self, from: json) } catch { throw A2UIValidationError(message: "Expected a complete JSON object.") }
        let envelope = try value.objectFields()
        let kinds = ["createSurface", "updateComponents", "updateDataModel", "deleteSurface"]
        let present = kinds.filter { envelope[$0] != nil }
        guard present.count == 1, let kind = present.first else {
            throw A2UIValidationError(message: "Expected exactly one surface message.")
        }
        let body = try envelope[kind]?.objectFields() ?? [:]
        let surfaceID = try body.requiredString("surfaceId")
        do {
            guard envelope["version"] == .string("v0.9.1") else {
                throw A2UIValidationError(path: "/version", message: "Only v0.9.1 is supported.")
            }
            try envelope.checkKeys(["version", kind])
        } catch let failure as A2UIValidationError {
            throw A2UIValidationError(surfaceID: surfaceID, path: failure.path, message: failure.message)
        }
        self.kind = kind
        self.body = body
        self.surfaceID = surfaceID
    }
}

extension UIValue {
    func objectFields() throws -> [String: UIValue] {
        guard case let .object(fields) = self else {
            throw A2UIValidationError(message: "Expected an object.")
        }
        return fields
    }
}

extension Dictionary where Key == String, Value == UIValue {
    func requiredString(_ name: String) throws -> String {
        guard let value = self[name]?.string, !value.isEmpty else {
            throw A2UIValidationError(path: "/" + name, message: "Expected a nonempty string.")
        }
        return value
    }

    func checkKeys(_ keys: Set<String>) throws {
        if let unknown = self.keys.sorted().first(where: { !keys.contains($0) }) {
            throw A2UIValidationError(path: "/" + unknown, message: "Unsupported property '\(unknown)'.")
        }
    }
}
