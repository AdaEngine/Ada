import Foundation
import Yams

public struct UIModifierDescription: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var type: String
    public var version: Int
    public var arguments: [String: UIArgument]
    public var children: [UINodeDescription]
    public var actions: [String: String]

    public init(
        id: String = UUID().uuidString,
        type: String,
        version: Int = 1,
        arguments: [String: UIArgument] = [:],
        children: [UINodeDescription] = [],
        actions: [String: String] = [:]
    ) {
        self.id = id
        self.type = type
        self.version = version
        self.arguments = arguments
        self.children = children
        self.actions = actions
    }
    private enum CodingKeys: String, CodingKey { case id, type, version, arguments, children, actions }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            type: try c.decode(String.self, forKey: .type),
            version: try c.decodeIfPresent(Int.self, forKey: .version) ?? 1,
            arguments: try c.decodeIfPresent([String: UIArgument].self, forKey: .arguments) ?? [:],
            children: try c.decodeIfPresent([UINodeDescription].self, forKey: .children) ?? [],
            actions: try c.decodeIfPresent([String: String].self, forKey: .actions) ?? [:]
        )
    }
}

public struct UINodeDescription: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var type: String
    public var version: Int
    public var arguments: [String: UIArgument]
    public var actions: [String: String]
    public var children: [Self]
    public var modifiers: [UIModifierDescription]

    public init(
        id: String = UUID().uuidString,
        type: String,
        version: Int = 1,
        arguments: [String: UIArgument] = [:],
        actions: [String: String] = [:],
        children: [Self] = [],
        modifiers: [UIModifierDescription] = []
    ) {
        self.id = id
        self.type = type
        self.version = version
        self.arguments = arguments
        self.actions = actions
        self.children = children
        self.modifiers = modifiers
    }

    private enum CodingKeys: String, CodingKey { case id, type, version, arguments, actions, children, modifiers }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            type: try c.decode(String.self, forKey: .type),
            version: try c.decodeIfPresent(Int.self, forKey: .version) ?? 1,
            arguments: try c.decodeIfPresent([String: UIArgument].self, forKey: .arguments) ?? [:],
            actions: try c.decodeIfPresent([String: String].self, forKey: .actions) ?? [:],
            children: try c.decodeIfPresent([Self].self, forKey: .children) ?? [],
            modifiers: try c.decodeIfPresent([UIModifierDescription].self, forKey: .modifiers) ?? []
        )
    }

    public func visit(_ body: (Self) throws -> Void) rethrows {
        try body(self)
        for child in children { try child.visit(body) }
        for modifier in modifiers {
            for child in modifier.children { try child.visit(body) }
        }
    }
}

/// A portable UI asset. Modifier order and node identity are part of the file contract.
public struct UISceneDocument: Codable, Hashable, Sendable {
    public var format: String = "ada.ui"
    public var schemaVersion: Int = 1
    public var inputs: [UIParameter]
    public var actions: [UIActionSignature]
    public var root: UINodeDescription

    public init(root: UINodeDescription = .init(type: "ZStack"), inputs: [UIParameter] = [], actions: [UIActionSignature] = []) {
        self.root = root
        self.inputs = inputs
        self.actions = actions
    }

    private enum CodingKeys: String, CodingKey { case format, schemaVersion, inputs, actions, root }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        root = try c.decode(UINodeDescription.self, forKey: .root)
        format = try c.decode(String.self, forKey: .format)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        inputs = try c.decodeIfPresent([UIParameter].self, forKey: .inputs) ?? []
        actions = try c.decodeIfPresent([UIActionSignature].self, forKey: .actions) ?? []
    }

    public static func decode(_ yaml: String) throws -> Self {
        let document = try YAMLDecoder().decode(Self.self, from: yaml)
        try document.validate()
        return document
    }

    public func encodedYAML() throws -> String {
        try validate()
        let encoder = YAMLEncoder()
        encoder.options.sortKeys = true
        return try encoder.encode(self)
    }

    public func validate() throws {
        guard format == "ada.ui", schemaVersion == 1 else {
            throw UIDiagnostic("Unsupported UI document format or version.")
        }
        var ids = Set<String>()
        try root.visit { node in
            guard !node.id.isEmpty, ids.insert(node.id).inserted else {
                throw UIDiagnostic("Duplicate or empty node ID.", nodeID: node.id)
            }
            guard !node.type.isEmpty, node.version > 0 else {
                throw UIDiagnostic("Invalid descriptor reference.", nodeID: node.id)
            }
            for argument in Array(node.arguments.values) + node.modifiers.flatMap({ Array($0.arguments.values) }) {
                guard (argument.value != nil) != (argument.binding != nil), argument.binding?.isEmpty != true else {
                    throw UIDiagnostic("An argument requires exactly one literal value or binding.", nodeID: node.id)
                }
            }
            var modifierIDs = Set<String>()
            for modifier in node.modifiers where !modifierIDs.insert(modifier.id).inserted {
                throw UIDiagnostic("Duplicate modifier ID.", nodeID: node.id)
            }
        }
        guard Set(inputs.map(\.name)).count == inputs.count, Set(actions.map(\.name)).count == actions.count else {
            throw UIDiagnostic("Duplicate input or action declaration.")
        }
        for input in inputs {
            if let value = input.defaultValue, !input.type.accepts(value) {
                throw UIDiagnostic("Invalid default for '\(input.name)'.")
            }
        }
    }
}
