//
//  ComponentMacro.swift
//  AdaEngineMacros
//
//  Created by v.prusakov on 2/14/24.
//

import SwiftDiagnostics
import SwiftOperators
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros

// TODO: Support Comments for generated methods

public struct ComponentMacro: ExtensionMacro {
    public static func expansion<D: DeclGroupSyntax, T: TypeSyntaxProtocol, C: MacroExpansionContext>(
        of node: SwiftSyntax.AttributeSyntax,
        attachedTo declaration: D,
        providingExtensionsOf type: T,
        conformingTo _: [SwiftSyntax.TypeSyntax],
        in _: C
    ) throws -> [SwiftSyntax.ExtensionDeclSyntax] {
        if let inheritanceClause = declaration.inheritanceClause,
            inheritanceClause.inheritedTypes.contains(where: {
                ["Component"].withQualified.contains($0.type.trimmedDescription)
            }) {
            return []
        }

        // Get dependencies from macro arguments
        var dependencies: [String] = []
        if let arguments = node.arguments?.as(LabeledExprListSyntax.self) {
            for argument in arguments where argument.label?.text == "required" {
                if let arrayExpr = argument.expression.as(ArrayExprSyntax.self) {
                    for element in arrayExpr.elements {
                        if let typeName = extractTypeName(from: element.expression) {
                            dependencies.append(typeName)
                        }
                    }
                }
            }
        }

        return if let structDecl = declaration.as(StructDeclSyntax.self) {
            try componentMacroForStruct(structDecl, type: type, requiredComponents: dependencies)
        } else if let enumDecl = declaration.as(EnumDeclSyntax.self) {
            generateDeclaration(
                type: type,
                availability: enumDecl.modifiers,
                functions: [],
                requiredComponents: dependencies
            )
        } else {
            throw MacroError.macroUsage("Component macro can be applied only for structs or enums.")
        }
    }
}

extension ComponentMacro {
    private struct ExplicitRuntimeConstructor {
        let body: String
        let parameters: [String]
    }

    private struct RuntimeConstructorParameter {
        let defaultExpression: String?
        let externalName: String
        let localName: String
        let typeName: String
    }

    /// Extracts type name from expression like Transform.self or AdaTransform.Transform.self
    private static func extractTypeName(from expression: ExprSyntax) -> String? {
        // Handle cases like Transform.self or AdaTransform.Transform.self
        if let memberAccess = expression.as(MemberAccessExprSyntax.self) {
            // Check if it's a .self access
            if memberAccess.declName.baseName.text == "self" {
                // Recursively build the full type name
                var typeParts: [String] = []
                var current: ExprSyntax? = memberAccess.base

                while let expr = current {
                    if let declRef = expr.as(DeclReferenceExprSyntax.self) {
                        typeParts.insert(declRef.baseName.text, at: 0)
                        break
                    } else if let nestedMember = expr.as(MemberAccessExprSyntax.self) {
                        typeParts.insert(nestedMember.declName.baseName.text, at: 0)
                        current = nestedMember.base
                    } else {
                        break
                    }
                }

                if !typeParts.isEmpty {
                    let fullTypeName = typeParts.joined(separator: ".")
                    return "\(fullTypeName).self"
                }
            }
        }
        // Handle cases where it might be just a type reference (shouldn't happen, but handle it)
        else if let declRef = expression.as(DeclReferenceExprSyntax.self) {
            return "\(declRef.baseName.text).self"
        }

        return nil
    }
    private static func componentMacroForStruct<T: TypeSyntaxProtocol>(
        _ structDecl: StructDeclSyntax,
        type: T,
        requiredComponents: [String]
    ) throws -> [SwiftSyntax.ExtensionDeclSyntax] {
        let properties = structDecl.memberBlock.members.compactMap { member -> (String, TypeSyntax, String)? in
            guard let varDecl = member.decl.as(VariableDeclSyntax.self) else {
                return nil
            }
            guard let binding = varDecl.bindings.first else {
                return nil
            }
            guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
                return nil
            }
            guard let type = binding.typeAnnotation?.type else {
                return nil
            }
            if varDecl.bindingSpecifier.tokenKind == .keyword(.let) {
                return nil
            }

            // Ignore computed properties that only have a getter
            if let accessors = binding.accessorBlock?.accessors {
                switch accessors {
                case .getter:
                    return nil
                default:
                    break
                }
            }

            let accessModifier = varDecl.modifiers.first?.name.text ?? "internal"
            return (identifier, type, accessModifier)
        }

        let functions = properties.map { propertyName, propertyType, accessModifier in
            """
            \(accessModifier) func set\(propertyName.capitalizingFirstLetter())(_ value: \(propertyType)) -> Self {
                var newValue = self
                newValue.\(propertyName) = value
                return newValue
            }
            """
        }

        let reflectedFields = properties.map { propertyName, propertyType, _ in
            """
            unsafe AdaECS.ReflectedComponentField(
                key: "\(propertyName)",
                label: "\(propertyName.reflectedFieldLabel)",
                kind: AdaECS.ComponentReflection.kind(for: \(propertyType).self),
                isWritable: AdaECS.ComponentReflection.isWritable(\(propertyType).self),
                accepts: { fieldValue in
                    AdaECS.ComponentReflection.accepts(fieldValue, for: \(propertyType).self)
                },
                read: { component in
                    guard let typedComponent = component as? Self else {
                        return nil
                    }
                    return AdaECS.ComponentReflection.read(typedComponent.\(propertyName))
                },
                write: { component, fieldValue in
                    guard var typedComponent = component as? Self else {
                        return nil
                    }
                    guard AdaECS.ComponentReflection.write(fieldValue, to: &typedComponent.\(propertyName)) else {
                        return nil
                    }
                    return typedComponent
                },
                readPointer: { pointer in
                    let typedComponent = unsafe pointer.assumingMemoryBound(to: Self.self)
                    return AdaECS.ComponentReflection.read(unsafe typedComponent.pointee.\(propertyName))
                },
                writePointer: { pointer, fieldValue in
                    let typedComponent = unsafe pointer.assumingMemoryBound(to: Self.self)
                    return unsafe AdaECS.ComponentReflection.write(
                        fieldValue,
                        to: &typedComponent.pointee.\(propertyName)
                    )
                }
            )
            """
        }

        let runtimeConstructorParameters = properties.map { propertyName, propertyType, _ in
            """
            AdaECS.RuntimeComponentConstructorParameter(
                name: "\(propertyName)",
                kind: AdaECS.ComponentReflection.kind(for: \(propertyType).self)
            )
            """
        }
        let runtimeConstructorAssignments = properties.map { propertyName, propertyType, _ in
            """
            if AdaECS.ComponentReflection.isWritable(\(propertyType).self) {
                if let fieldValue = arguments[argumentIndex],
                    !AdaECS.ComponentReflection.write(fieldValue, to: &typedComponent.\(propertyName)) {
                    throw AdaECS.RuntimeComponentConstructorError.invalidArgument(
                        component: String(reflecting: Self.self),
                        parameter: "\(propertyName)"
                    )
                }
                argumentIndex += 1
            }
            """
        }

        let explicitConstructor = try adaScriptConstructor(in: structDecl)
        return generateDeclaration(
            type: type,
            availability: structDecl.modifiers,
            functions: functions,
            requiredComponents: requiredComponents,
            reflectedFields: reflectedFields,
            runtimeConstructorParameters: explicitConstructor?.parameters ?? runtimeConstructorParameters,
            runtimeConstructorAssignments: explicitConstructor == nil ? runtimeConstructorAssignments : [],
            runtimeConstructorBody: explicitConstructor?.body
        )
    }

    private static func adaScriptConstructor(
        in structDecl: StructDeclSyntax
    ) throws -> ExplicitRuntimeConstructor? {
        let markedInitializers = structDecl.memberBlock.members.compactMap { member -> InitializerDeclSyntax? in
            guard let initializer = member.decl.as(InitializerDeclSyntax.self) else {
                return nil
            }
            let isMarked = initializer.attributes.contains { element in
                guard let attribute = element.as(AttributeSyntax.self) else {
                    return false
                }
                let name = attribute.attributeName.trimmedDescription
                return name == "AdaScriptInit" || name.hasSuffix(".AdaScriptInit")
            }
            return isMarked ? initializer : nil
        }

        guard !markedInitializers.isEmpty else {
            return nil
        }
        guard markedInitializers.count == 1, let initializer = markedInitializers.first else {
            throw MacroError.macroUsage("A component can declare only one @AdaScriptInit initializer.")
        }

        let parameters = try initializer.signature.parameterClause.parameters.map { parameter in
            let externalName = parameter.firstName.text
            let localName: String
            if let secondName = parameter.secondName {
                localName = secondName.text
            } else if externalName != "_" {
                localName = externalName
            } else {
                throw MacroError.macroUsage("An unnamed @AdaScriptInit parameter requires a local name.")
            }
            return RuntimeConstructorParameter(
                defaultExpression: parameter.defaultValue?.value.trimmedDescription,
                externalName: externalName,
                localName: localName,
                typeName: parameter.type.trimmedDescription
            )
        }

        var exposedParameters: [String] = []
        var argumentDecoders: [String] = []
        var initializerArguments: [String] = []
        var argumentIndex = 0

        for parameter in parameters {
            let callArgument = parameter.externalName == "_"
                ? parameter.localName
                : "\(parameter.externalName): \(parameter.localName)"
            initializerArguments.append(callArgument)

            guard isSupportedRuntimeConstructorType(parameter.typeName) else {
                guard let defaultExpression = parameter.defaultExpression else {
                    throw MacroError.macroUsage(
                        "@AdaScriptInit parameter '\(parameter.externalName)' has unsupported type "
                            + "'\(parameter.typeName)' and must provide a default value."
                    )
                }
                argumentDecoders.append(
                    "let \(parameter.localName): \(parameter.typeName) = \(defaultExpression)"
                )
                continue
            }

            let scriptName = parameter.externalName == "_" ? parameter.localName : parameter.externalName
            exposedParameters.append(
                """
                AdaECS.RuntimeComponentConstructorParameter(
                    name: "\(scriptName)",
                    kind: AdaECS.ComponentReflection.kind(for: \(parameter.typeName).self)
                )
                """
            )

            let missingValue: String
            if let defaultExpression = parameter.defaultExpression {
                missingValue = "\(parameter.localName) = \(defaultExpression)"
            } else {
                missingValue =
                    """
                    throw AdaECS.RuntimeComponentConstructorError.missingArgument(
                        component: String(reflecting: Self.self),
                        parameter: "\(scriptName)"
                    )
                    """
            }
            argumentDecoders.append(
                """
                let \(parameter.localName): \(parameter.typeName)
                if let fieldValue = arguments[\(argumentIndex)] {
                    guard let decoded = AdaECS.ComponentReflection.value(
                        fieldValue,
                        as: \(parameter.typeName).self
                    ) else {
                        throw AdaECS.RuntimeComponentConstructorError.invalidArgument(
                            component: String(reflecting: Self.self),
                            parameter: "\(scriptName)"
                        )
                    }
                    \(parameter.localName) = decoded
                } else {
                    \(missingValue)
                }
                """
            )
            argumentIndex += 1
        }

        return ExplicitRuntimeConstructor(
            body:
                """
                \(argumentDecoders.joined(separator: "\n"))
                return Self(\(initializerArguments.joined(separator: ", ")))
                """,
            parameters: exposedParameters
        )
    }

    private static func isSupportedRuntimeConstructorType(_ typeName: String) -> Bool {
        let supportedTypes = [
            "Bool", "Int", "Float", "Double", "String",
            "Vector2", "Vector3", "Vector4", "Quat", "Color",
        ]
        return supportedTypes.contains { typeName == $0 || typeName.hasSuffix(".\($0)") }
    }

    private static func generateDeclaration<T: TypeSyntaxProtocol>(
        type: T,
        availability: DeclModifierListSyntax?,
        functions: [String],
        requiredComponents: [String] = [],
        reflectedFields: [String] = [],
        runtimeConstructorParameters: [String] = [],
        runtimeConstructorAssignments: [String] = [],
        runtimeConstructorBody: String? = nil
    ) -> [SwiftSyntax.ExtensionDeclSyntax] {
        // Process modifiers: if private or private, change to internal
        let processedAvailability = processModifiers(availability)
        let requiredComponentTypeNames = requiredComponents.map { "String(reflecting: \($0))" }.joined(separator: ", ")
        let generatedRuntimeConstructorBody = if let runtimeConstructorBody {
            runtimeConstructorBody
        } else if runtimeConstructorAssignments.isEmpty {
            """
            guard let typedComponent = component as? Self else {
                throw AdaECS.RuntimeComponentConstructorError.invalidBase(
                    component: String(reflecting: Self.self)
                )
            }
            return typedComponent
            """
        } else {
            """
            guard var typedComponent = component as? Self else {
                throw AdaECS.RuntimeComponentConstructorError.invalidBase(
                    component: String(reflecting: Self.self)
                )
            }
            var argumentIndex = 0
            \(runtimeConstructorAssignments.joined(separator: "\n"))
            return typedComponent
            """
        }
        let runtimeConstructorImplementation = if runtimeConstructorBody == nil {
            """
            applyArguments: { component, arguments in
                \(generatedRuntimeConstructorBody)
            }
            """
        } else {
            """
            constructArguments: { arguments in
                \(generatedRuntimeConstructorBody)
            }
            """
        }

        let proto = "AdaECS.Component, AdaECS.ReflectableComponent, AdaECS.RuntimeConstructibleComponent"
        let ext: DeclSyntax =
            """
            extension \(type.trimmed): \(raw: proto) {
                \(raw: functions.joined(separator: "\n"))
                \(processedAvailability) static var requiredComponents: RequiredComponents {
                    RequiredComponents(components: [\(raw: requiredComponents.joined(separator: ", "))])
                }
                \(processedAvailability) static var componentDescriptor: AdaECS.ReflectedComponentDescriptor {
                    AdaECS.ReflectedComponentDescriptor(
                        type: Self.self,
                        displayName: String(describing: Self.self),
                        requiredComponentTypeNames: [\(raw: requiredComponentTypeNames)],
                        fields: [
                            \(raw: reflectedFields.joined(separator: ",\n"))
                        ]
                    )
                }
                \(processedAvailability) static var runtimeComponentConstructor: AdaECS.RuntimeComponentConstructorDescriptor {
                    AdaECS.RuntimeComponentConstructorDescriptor(
                        typeName: String(reflecting: Self.self),
                        parameters: [
                            \(raw: runtimeConstructorParameters.joined(separator: ",\n"))
                        ].filter { $0.kind != .readOnly },
                        \(raw: runtimeConstructorImplementation)
                    )
                }
            }
            """
        return [ext.cast(ExtensionDeclSyntax.self)]
    }

    private static func processModifiers(_ modifiers: DeclModifierListSyntax?) -> DeclModifierListSyntax? {
        guard let modifiers, !modifiers.isEmpty else {
            return nil
        }

        // Check if we have private or private modifiers that need to be changed to internal
        var needsReplacement = false
        for modifier in modifiers {
            let name = modifier.name.text
            if name == "private" || name == "private" {
                needsReplacement = true
                break
            }
        }

        // If we found private or private, replace it with internal
        if needsReplacement {
            var newModifiers: [DeclModifierSyntax] = []
            for modifier in modifiers {
                let name = modifier.name.text
                if name == "private" || name == "private" {
                    // Replace with internal modifier using with method
                    let internalModifier = modifier.with(\.name, .keyword(.internal))
                    newModifiers.append(internalModifier)
                } else {
                    newModifiers.append(modifier)
                }
            }
            return DeclModifierListSyntax(newModifiers)
        }

        // Otherwise return original modifiers
        return modifiers
    }
}

extension ComponentMacro: MemberMacro {
    public static func expansion(
        of _: AttributeSyntax,
        providingMembersOf _: some DeclGroupSyntax,
        conformingTo _: [TypeSyntax],
        in _: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        return []
    }
}

extension String {
    func capitalizingFirstLetter() -> String {
        return prefix(1).capitalized + dropFirst()
    }

    var reflectedFieldLabel: String {
        guard !isEmpty else {
            return self
        }

        var result = ""
        for character in self {
            if character.isUppercase && !result.isEmpty {
                result.append(" ")
            }
            result.append(character)
        }
        return result.capitalizingFirstLetter()
    }
}
