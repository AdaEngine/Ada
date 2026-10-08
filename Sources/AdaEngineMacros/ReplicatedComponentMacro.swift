import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct ReplicatedComponentMacro {}
public struct NetworkCommandMacro {}

extension ReplicatedComponentMacro: MemberMacro {
    public static func expansion(
        of _: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo _: [TypeSyntax],
        in _: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let component = try ParsedReplicatedComponent(declaration: declaration)
        let codingCases = component.fields.map { field in
            "case \(field.name) = \"\(field.tag)\""
        }.joined(separator: "\n")
        return [
            """
            private enum CodingKeys: String, CodingKey {
                \(raw: codingCases)
            }
            """
        ]
    }
}

extension ReplicatedComponentMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo _: [TypeSyntax],
        in _: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let component = try ParsedReplicatedComponent(declaration: declaration)
        let arguments = try ReplicatedComponentArguments(attribute: node)
        let existingConformances = Set(
            declaration.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        )
        let requestedConformances = [
            "AdaECS.Component",
            "Swift.Codable",
            "Swift.Sendable",
            "AdaMultiplayer.NetworkReplicatedComponent",
        ].filter { conformance in
            let shortName = conformance.split(separator: ".").last.map(String.init) ?? conformance
            return !existingConformances.contains(conformance) && !existingConformances.contains(shortName)
        }
        let conformanceClause = requestedConformances.joined(separator: ", ")
        let inheritance = conformanceClause.isEmpty ? "" : ": \(conformanceClause)"
        let fieldDescriptors = component.fields.map { field in
            """
            AdaMultiplayer.NetworkFieldDescriptor(
                tag: \(field.tag),
                wireType: \(field.wireTypeExpression),
                replication: \(field.modeExpression),
                interpolation: \(field.interpolationExpression)
            )
            """
        }.joined(separator: ",\n")

        let extensionDeclaration: DeclSyntax =
            """
            extension \(type.trimmed) \(raw: inheritance) {
                \(raw: component.accessPrefix)static var requiredComponents: AdaECS.RequiredComponents {
                    AdaECS.RequiredComponents(components: [AdaMultiplayer.ReplicatedEntity.self])
                }

                \(raw: component.accessPrefix)static var networkDescriptor: AdaMultiplayer.NetworkTypeDescriptor {
                    AdaMultiplayer.NetworkTypeDescriptor(
                        typeID: \(literal: arguments.id),
                        version: \(raw: arguments.versionExpression),
                        kind: .component,
                        authority: \(arguments.authorityExpression),
                        visibility: \(arguments.visibilityExpression),
                        fields: [
                            \(raw: fieldDescriptors)
                        ]
                    )
                }
            }
            """
        return [extensionDeclaration.cast(ExtensionDeclSyntax.self)]
    }
}

extension NetworkCommandMacro: MemberMacro {
    public static func expansion(
        of _: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo _: [TypeSyntax],
        in _: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let command = try ParsedReplicatedComponent(declaration: declaration, macroName: "NetworkCommand")
        let codingCases = command.fields.map { field in
            "case \(field.name) = \"\(field.tag)\""
        }.joined(separator: "\n")
        return [
            """
            private enum CodingKeys: String, CodingKey {
                \(raw: codingCases)
            }
            """
        ]
    }
}

extension NetworkCommandMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo _: [TypeSyntax],
        in _: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        let command = try ParsedReplicatedComponent(declaration: declaration, macroName: "NetworkCommand")
        let arguments = try NetworkCommandArguments(attribute: node)
        let existingConformances = Set(
            declaration.inheritanceClause?.inheritedTypes.map { $0.type.trimmedDescription } ?? []
        )
        let requestedConformances = [
            "Swift.Codable",
            "Swift.Sendable",
            "AdaMultiplayer.NetworkCommand",
            "AdaMultiplayer.NetworkDescribedMessage",
        ].filter { conformance in
            let shortName = conformance.split(separator: ".").last.map(String.init) ?? conformance
            return !existingConformances.contains(conformance) && !existingConformances.contains(shortName)
        }
        let conformanceClause = requestedConformances.joined(separator: ", ")
        let inheritance = conformanceClause.isEmpty ? "" : ": \(conformanceClause)"
        let fieldDescriptors = command.fields.map { field in
            """
            AdaMultiplayer.NetworkFieldDescriptor(
                tag: \(field.tag),
                wireType: \(field.wireTypeExpression),
                replication: \(field.modeExpression),
                interpolation: \(field.interpolationExpression)
            )
            """
        }.joined(separator: ",\n")

        let extensionDeclaration: DeclSyntax =
            """
            extension \(type.trimmed) \(raw: inheritance) {
                \(raw: command.accessPrefix)static let networkIdentifier = \(literal: arguments.id)
                \(raw: command.accessPrefix)static let networkVersion: UInt16 = \(raw: arguments.versionExpression)

                \(raw: command.accessPrefix)static var networkDescriptor: AdaMultiplayer.NetworkTypeDescriptor {
                    AdaMultiplayer.NetworkTypeDescriptor(
                        typeID: networkIdentifier,
                        version: networkVersion,
                        kind: .command,
                        authority: .anyPeer,
                        direction: \(arguments.directionExpression),
                        delivery: \(arguments.deliveryExpression),
                        channel: \(literal: arguments.channel),
                        maximumPayloadSize: \(raw: arguments.maximumPayloadSizeExpression),
                        fields: [
                            \(raw: fieldDescriptors)
                        ]
                    )
                }
            }
            """
        return [extensionDeclaration.cast(ExtensionDeclSyntax.self)]
    }
}

public enum NetworkFieldMacro: PeerMacro {
    public static func expansion(
        of _: AttributeSyntax,
        providingPeersOf _: some DeclSyntaxProtocol,
        in _: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

public enum LocalOnlyMacro: PeerMacro {
    public static func expansion(
        of _: AttributeSyntax,
        providingPeersOf _: some DeclSyntaxProtocol,
        in _: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        []
    }
}

private struct ReplicatedComponentArguments {
    let id: String
    let versionExpression: String
    let authorityExpression: ExprSyntax
    let visibilityExpression: ExprSyntax

    init(attribute: AttributeSyntax) throws {
        guard
            let idExpression = attribute.argument(for: "id")?.as(StringLiteralExprSyntax.self),
            idExpression.segments.count == 1,
            case let .stringSegment(idSegment)? = idExpression.segments.first,
            !idSegment.content.text.isEmpty
        else {
            throw MacroError.macroUsage("ReplicatedComponent requires a non-empty static string id.")
        }
        id = idSegment.content.text
        if let versionArgument = attribute.argument(for: "version") {
            guard
                let literal = versionArgument.as(IntegerLiteralExprSyntax.self),
                let version = UInt16(literal.literal.text),
                version > 0
            else {
                throw MacroError.macroUsage("ReplicatedComponent version must be a positive UInt16 literal.")
            }
            versionExpression = String(version)
        } else {
            versionExpression = "1"
        }
        authorityExpression = attribute.argument(for: "authority") ?? ".host"
        visibilityExpression = attribute.argument(for: "visibility") ?? ".allPeers"
    }
}

private struct NetworkCommandArguments {
    let id: String
    let versionExpression: String
    let directionExpression: ExprSyntax
    let deliveryExpression: ExprSyntax
    let channel: String
    let maximumPayloadSizeExpression: String

    init(attribute: AttributeSyntax) throws {
        let common = try ParsedNetworkTypeArguments(attribute: attribute, macroName: "NetworkCommand")
        id = common.id
        versionExpression = common.versionExpression
        directionExpression = attribute.argument(for: "direction") ?? ".peerToHost"
        deliveryExpression = attribute.argument(for: "delivery") ?? ".reliableOrdered"
        if let channelExpression = attribute.argument(for: "channel") {
            guard
                let literal = channelExpression.as(StringLiteralExprSyntax.self),
                literal.segments.count == 1,
                case let .stringSegment(segment)? = literal.segments.first,
                !segment.content.text.isEmpty
            else {
                throw MacroError.macroUsage("NetworkCommand channel must be a non-empty static string.")
            }
            channel = segment.content.text
        } else {
            channel = "command"
        }
        if let payloadExpression = attribute.argument(for: "maximumPayloadSize") {
            guard
                let literal = payloadExpression.as(IntegerLiteralExprSyntax.self),
                let size = Int(literal.literal.text),
                size > 0
            else {
                throw MacroError.macroUsage("NetworkCommand maximumPayloadSize must be a positive integer literal.")
            }
            maximumPayloadSizeExpression = String(size)
        } else {
            maximumPayloadSizeExpression = String(64 * 1_024)
        }
    }
}

private struct ParsedNetworkTypeArguments {
    let id: String
    let versionExpression: String

    init(attribute: AttributeSyntax, macroName: String) throws {
        guard
            let idExpression = attribute.argument(for: "id")?.as(StringLiteralExprSyntax.self),
            idExpression.segments.count == 1,
            case let .stringSegment(idSegment)? = idExpression.segments.first,
            !idSegment.content.text.isEmpty
        else {
            throw MacroError.macroUsage("\(macroName) requires a non-empty static string id.")
        }
        id = idSegment.content.text
        if let versionArgument = attribute.argument(for: "version") {
            guard
                let literal = versionArgument.as(IntegerLiteralExprSyntax.self),
                let version = UInt16(literal.literal.text),
                version > 0
            else {
                throw MacroError.macroUsage("\(macroName) version must be a positive UInt16 literal.")
            }
            versionExpression = String(version)
        } else {
            versionExpression = "1"
        }
    }
}

private struct ParsedReplicatedComponent {
    let accessPrefix: String
    let fields: [ParsedNetworkField]

    init(declaration: some DeclGroupSyntax, macroName: String = "ReplicatedComponent") throws {
        guard declaration.is(StructDeclSyntax.self) else {
            throw MacroError.macroUsage("\(macroName) can be applied only to a struct.")
        }

        if declaration.modifiers.contains(where: { $0.name.tokenKind == .keyword(.public) || $0.name.tokenKind == .keyword(.open) }) {
            accessPrefix = "public "
        } else if declaration.modifiers.contains(where: { $0.name.tokenKind == .keyword(.package) }) {
            accessPrefix = "package "
        } else {
            accessPrefix = ""
        }

        var parsedFields: [ParsedNetworkField] = []
        var usedTags: Set<UInt16> = []
        for member in declaration.memberBlock.members {
            guard let variable = member.decl.as(VariableDeclSyntax.self) else {
                continue
            }
            guard !variable.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) else {
                continue
            }
            guard variable.bindings.count == 1,
                let binding = variable.bindings.first,
                binding.accessorBlock == nil,
                let name = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
            else {
                continue
            }

            let networkAttribute = variable.attribute(named: "NetworkField")
            let isLocalOnly = variable.attribute(named: "LocalOnly") != nil
            if networkAttribute != nil && isLocalOnly {
                throw MacroError.macroUsage("Property '\(name)' cannot be both NetworkField and LocalOnly.")
            }
            guard let networkAttribute else {
                if binding.initializer == nil && binding.typeAnnotation?.type.is(OptionalTypeSyntax.self) != true {
                    throw MacroError.macroUsage(
                        "Local property '\(name)' needs a default value so replicated decoding can preserve it."
                    )
                }
                continue
            }
            guard let type = binding.typeAnnotation?.type else {
                throw MacroError.macroUsage("Network field '\(name)' requires an explicit type.")
            }
            let field = try ParsedNetworkField(name: name, type: type, attribute: networkAttribute)
            guard usedTags.insert(field.tag).inserted else {
                throw MacroError.macroUsage("Duplicate network field tag \(field.tag).")
            }
            parsedFields.append(field)
        }
        guard !parsedFields.isEmpty else {
            throw MacroError.macroUsage("\(macroName) requires at least one NetworkField.")
        }
        fields = parsedFields.sorted { $0.tag < $1.tag }
    }
}

private struct ParsedNetworkField {
    let name: String
    let tag: UInt16
    let wireTypeExpression: String
    let modeExpression: ExprSyntax
    let interpolationExpression: ExprSyntax

    init(name: String, type: TypeSyntax, attribute: AttributeSyntax) throws {
        guard
            let arguments = attribute.arguments?.as(LabeledExprListSyntax.self),
            let tagExpression = arguments.first(where: { $0.label == nil })?.expression,
            let tagLiteral = tagExpression.as(IntegerLiteralExprSyntax.self),
            let parsedTag = UInt16(tagLiteral.literal.text),
            parsedTag > 0
        else {
            throw MacroError.macroUsage("NetworkField requires a positive UInt16 literal tag.")
        }
        self.name = name
        self.tag = parsedTag
        self.wireTypeExpression = Self.wireType(for: type)
        self.modeExpression = attribute.argument(for: "mode") ?? ".state"
        self.interpolationExpression = attribute.argument(for: "interpolate") ?? ".none"
    }

    private static func wireType(for type: TypeSyntax) -> String {
        let name = type.trimmedDescription
        let unqualified = name.split(separator: ".").last.map(String.init) ?? name
        switch unqualified {
        case "Bool":
            return ".bool"
        case "Int", "Int8", "Int16", "Int32", "Int64":
            return ".signedInteger"
        case "UInt", "UInt8", "UInt16", "UInt32", "UInt64":
            return ".unsignedInteger"
        case "Float", "Double":
            return ".floatingPoint"
        case "String":
            return ".string"
        case "Vector2":
            return ".vector2"
        case "Vector3":
            return ".vector3"
        case "Vector4":
            return ".vector4"
        default:
            return ".named(\"\(name)\")"
        }
    }
}

private extension VariableDeclSyntax {
    func attribute(named name: String) -> AttributeSyntax? {
        for element in attributes {
            guard case let .attribute(attribute) = element else {
                continue
            }
            let attributeName = attribute.attributeName.trimmedDescription
            if attributeName == name || attributeName.hasSuffix(".\(name)") {
                return attribute
            }
        }
        return nil
    }
}
