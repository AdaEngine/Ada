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
            componentMacroForStruct(structDecl, type: type, requiredComponents: dependencies)
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
    ) -> [SwiftSyntax.ExtensionDeclSyntax] {
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

        let editorFields = properties.map { propertyName, propertyType, _ in
            """
            unsafe AdaECS.EditorComponentFieldDescriptor(
                key: "\(propertyName)",
                label: "\(propertyName.editorFieldLabel)",
                kind: AdaECS.EditorComponentReflection.kind(for: \(propertyType).self),
                isEditable: AdaECS.EditorComponentReflection.isEditable(\(propertyType).self),
                accepts: { fieldValue in
                    AdaECS.EditorComponentReflection.accepts(fieldValue, for: \(propertyType).self)
                },
                read: { component in
                    guard let typedComponent = component as? Self else {
                        return nil
                    }
                    return AdaECS.EditorComponentReflection.read(typedComponent.\(propertyName))
                },
                write: { component, fieldValue in
                    guard var typedComponent = component as? Self else {
                        return nil
                    }
                    guard AdaECS.EditorComponentReflection.write(fieldValue, to: &typedComponent.\(propertyName)) else {
                        return nil
                    }
                    return typedComponent
                },
                readPointer: { pointer in
                    let typedComponent = unsafe pointer.assumingMemoryBound(to: Self.self)
                    return AdaECS.EditorComponentReflection.read(unsafe typedComponent.pointee.\(propertyName))
                },
                writePointer: { pointer, fieldValue in
                    let typedComponent = unsafe pointer.assumingMemoryBound(to: Self.self)
                    return unsafe AdaECS.EditorComponentReflection.write(
                        fieldValue,
                        to: &typedComponent.pointee.\(propertyName)
                    )
                }
            )
            """
        }

        return generateDeclaration(
            type: type,
            availability: structDecl.modifiers,
            functions: functions,
            requiredComponents: requiredComponents,
            editorFields: editorFields
        )
    }

    private static func generateDeclaration<T: TypeSyntaxProtocol>(
        type: T,
        availability: DeclModifierListSyntax?,
        functions: [String],
        requiredComponents: [String] = [],
        editorFields: [String] = []
    ) -> [SwiftSyntax.ExtensionDeclSyntax] {
        // Process modifiers: if private or private, change to internal
        let processedAvailability = processModifiers(availability)
        let requiredComponentTypeNames = requiredComponents.map { "String(reflecting: \($0))" }.joined(separator: ", ")

        let proto = "AdaECS.Component, AdaECS.EditorInspectableComponent"
        let ext: DeclSyntax =
            """
            extension \(type.trimmed): \(raw: proto) {
                \(raw: functions.joined(separator: "\n"))
                \(processedAvailability) static var requiredComponents: RequiredComponents {
                    RequiredComponents(components: [\(raw: requiredComponents.joined(separator: ", "))])
                }
                \(processedAvailability) static var editorComponentDescriptor: AdaECS.EditorComponentDescriptor {
                    AdaECS.EditorComponentDescriptor(
                        type: Self.self,
                        displayName: String(describing: Self.self),
                        requiredComponentTypeNames: [\(raw: requiredComponentTypeNames)],
                        fields: [
                            \(raw: editorFields.joined(separator: ",\n"))
                        ]
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

    var editorFieldLabel: String {
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
