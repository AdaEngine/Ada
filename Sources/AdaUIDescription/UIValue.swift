import Foundation

/// Detached values shared by UI documents, tools, and runtime bindings.
public indirect enum UIValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: Self].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public var string: String? {
        if case let .string(value) = self {
            value
        } else {
            nil
        }
    }
    public var number: Double? {
        if case let .number(value) = self {
            value
        } else {
            nil
        }
    }
    public var bool: Bool? {
        if case let .bool(value) = self {
            value
        } else {
            nil
        }
    }
    public var array: [Self]? {
        if case let .array(value) = self {
            value
        } else {
            nil
        }
    }

    public func value(at path: ArraySlice<String>) -> Self? {
        guard let key = path.first else {
            return self
        }
        guard case let .object(values) = self else {
            return nil
        }
        return values[key]?.value(at: path.dropFirst())
    }
    public func setting(_ value: Self, at path: ArraySlice<String>) -> Self? {
        guard let key = path.first else {
            return value
        }
        guard case var .object(values) = self else {
            return nil
        }
        if path.count == 1 {
            values[key] = value
        } else {
            guard let updated = values[key]?.setting(value, at: path.dropFirst()) else {
                return nil
            }
            values[key] = updated
        }
        return .object(values)
    }

    public var type: UIValueType {
        switch self {
        case .null: .any
        case .bool: .bool
        case .number: .number
        case .string: .string
        case .array: .array
        case .object: .object
        }
    }
}

public enum UIValueType: String, Codable, CaseIterable, Sendable {
    case bool, number, string, array, object, any

    public func accepts(_ value: UIValue) -> Bool {
        switch (self, value) {
        case (.any, _),
            (.bool, .bool),
            (.number, .number),
            (.string, .string),
            (.array, .array),
            (.object, .object):
            true
        default: false
        }
    }
}

/// An argument is either a literal or a named binding; these are never inferred from string contents.
public struct UIArgument: Codable, Hashable, Sendable {
    public var value: UIValue?
    public var binding: String?

    public init(value: UIValue) { self.value = value }
    public init(binding: String) { self.binding = binding }

    private enum CodingKeys: String, CodingKey { case value, binding }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = container.contains(.value) ? try container.decode(UIValue.self, forKey: .value) : nil
        binding = try container.decodeIfPresent(String.self, forKey: .binding)
    }
}

/// Optional authoring hints; serialized values retain their existing wire types.
public enum UIParameterEditor: Codable, Hashable, Sendable {
    case color
    case enumeration([String])
}

public struct UIParameter: Codable, Hashable, Sendable {
    public var name: String
    public var type: UIValueType
    public var defaultValue: UIValue?
    public var isBinding: Bool
    public var editor: UIParameterEditor?

    public init(_ name: String, type: UIValueType, defaultValue: UIValue? = nil, isBinding: Bool = false, editor: UIParameterEditor? = nil) {
        self.name = name
        self.type = type
        self.defaultValue = defaultValue
        self.editor = editor
        self.isBinding = isBinding
    }
    private enum CodingKeys: String, CodingKey { case name, type, defaultValue, isBinding, editor }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(UIValueType.self, forKey: .type)
        defaultValue = c.contains(.defaultValue) ? try c.decode(UIValue.self, forKey: .defaultValue) : nil
        editor = try c.decodeIfPresent(UIParameterEditor.self, forKey: .editor)
        isBinding = try c.decodeIfPresent(Bool.self, forKey: .isBinding) ?? false
    }
}

public struct UIActionSignature: Codable, Hashable, Sendable {
    public var name: String
    public var parameters: [UIParameter]

    public init(_ name: String, parameters: [UIParameter] = []) {
        self.name = name
        self.parameters = parameters
    }
    private enum CodingKeys: String, CodingKey { case name, parameters }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        parameters = try c.decodeIfPresent([UIParameter].self, forKey: .parameters) ?? []
    }
}

public enum UIContentShape: String, Codable, Sendable { case none, single, children }

/// Stable metadata; inspecting a signature never executes application code.
public struct UIDescriptorSignature: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var version: Int
    public var name: String
    public var parameters: [UIParameter]
    public var actions: [UIActionSignature]
    public var content: UIContentShape
    public var platforms: [String]

    public init(
        id: String,
        name: String,
        version: Int = 1,
        parameters: [UIParameter] = [],
        actions: [UIActionSignature] = [],
        content: UIContentShape = .none,
        platforms: [String] = []
    ) {
        self.id = id
        self.version = version
        self.name = name
        self.parameters = parameters
        self.actions = actions
        self.content = content
        self.platforms = platforms
    }
}

public struct UIDiagnostic: Error, LocalizedError, Hashable, Sendable {
    public var nodeID: String?
    public var message: String
    public var errorDescription: String? { nodeID.map { "\($0): \(message)" } ?? message }

    public init(_ message: String, nodeID: String? = nil) {
        self.message = message
        self.nodeID = nodeID
    }
}
