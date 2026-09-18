//
//  StateMacro.swift
//  AdaEngineMacros
//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct StateMacro {}

extension StateMacro: AccessorMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in _: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        let property = try StateProperty(declaration: declaration, attribute: node)
        let storageName = property.initialValue == nil ? "_\(property.name)" : "__\(property.name)"

        let getAccessor: AccessorDeclSyntax = "get { \(raw: storageName).wrappedValue }"
        let setAccessor: AccessorDeclSyntax = "nonmutating set { \(raw: storageName).wrappedValue = newValue }"
        return [getAccessor, setAccessor]
    }
}

extension StateMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in _: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let property = try StateProperty(declaration: declaration, attribute: node)
        let access = property.accessModifier
        let typeAnnotation = property.type.map { ": \($0.trimmedDescription)" } ?? ""

        let backingStorage: DeclSyntax
        let storageName: String
        if let initialValue = property.initialValue {
            storageName = "__\(property.name)"
            backingStorage =
                """
                private let __\(raw: property.name) = \(raw: property.qualifier)State._makeStorage({
                    let value\(raw: typeAnnotation) = \(initialValue)
                    return value
                })
                """
        } else {
            storageName = "_\(property.name)"
            backingStorage =
                """
                private var _\(raw: property.name): \(raw: property.qualifier)State<\(property.valueType)>
                """
        }

        let projectedValue: DeclSyntax =
            """
            \(raw: access)var $\(raw: property.name): \(raw: property.qualifier)Binding<\(property.valueType)> {
                get {
                    \(raw: storageName).projectedValue
                }
            }
            """

        return [backingStorage, projectedValue]
    }
}

private struct StateProperty {
    let name: String
    let type: TypeSyntax?
    let initialValue: ExprSyntax?
    let accessModifier: String
    let valueType: TypeSyntax
    let qualifier: String

    init(declaration: some DeclSyntaxProtocol, attribute: AttributeSyntax) throws {
        guard
            let variable = declaration.as(VariableDeclSyntax.self),
            let binding = variable.bindings.first,
            variable.bindings.count == 1
        else {
            throw MacroError.macroUsage("State macro can be applied only to a single stored property.")
        }

        guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text else {
            throw MacroError.macroUsage("State macro can be applied only to identifier properties.")
        }

        self.name = identifier
        self.type = binding.typeAnnotation?.type
        self.accessModifier = variable.stateAccessModifier
        self.qualifier = attribute.stateQualifier

        let initialValue: ExprSyntax?
        if let value = binding.initializer?.value {
            initialValue = value
        } else if let attributeInitialValue = attribute.argument(for: "initialValue") ?? attribute.argument(for: "wrappedValue") {
            initialValue = attributeInitialValue
        } else if binding.typeAnnotation?.type.is(OptionalTypeSyntax.self) == true {
            initialValue = "nil"
        } else {
            initialValue = nil
        }

        self.initialValue = initialValue
        if let type = binding.typeAnnotation?.type {
            self.valueType = type
        } else if let inferredType = initialValue?.inferredStateValueType {
            self.valueType = inferredType
        } else {
            throw MacroError.macroUsage("State macro requires an explicit type for uninitialized or non-literal initial values.")
        }
    }
}

extension VariableDeclSyntax {
    var stateAccessModifier: String {
        if modifiers.contains(where: { $0.name.tokenKind == .keyword(.public) }) {
            return "public "
        }
        if modifiers.contains(where: { $0.name.tokenKind == .keyword(.package) }) {
            return "package "
        }
        if modifiers.contains(where: { $0.name.tokenKind == .keyword(.private) }) {
            return "private "
        }
        if modifiers.contains(where: { $0.name.tokenKind == .keyword(.private) }) {
            return "private "
        }
        return ""
    }
}

extension ExprSyntax {
    var inferredStateValueType: TypeSyntax? {
        if self.is(IntegerLiteralExprSyntax.self) {
            return "Int"
        }
        if self.is(BooleanLiteralExprSyntax.self) {
            return "Bool"
        }
        if self.is(StringLiteralExprSyntax.self) {
            return "String"
        }
        if self.is(FloatLiteralExprSyntax.self) {
            return "Double"
        }
        if let memberAccess = self.as(MemberAccessExprSyntax.self),
            let base = memberAccess.base?.trimmedDescription,
            !base.isEmpty {
            return "\(raw: base)"
        }
        if let call = self.as(FunctionCallExprSyntax.self),
            let calledType = call.calledExpression.constructorTypeName {
            return calledType
        }
        return nil
    }
}

extension ExprSyntax {
    private var constructorTypeName: TypeSyntax? {
        let typeName = trimmedDescription
        guard
            !typeName.isEmpty,
            typeName.split(separator: ".").last?.first?.isUppercase == true
        else {
            return nil
        }

        return "\(raw: typeName)"
    }
}

extension AttributeSyntax {
    var stateQualifier: String {
        let name = attributeName.trimmedDescription
        guard
            name.hasSuffix(".State"),
            let dotIndex = name.lastIndex(of: ".")
        else {
            return ""
        }

        return "\(name[..<name.index(after: dotIndex)])"
    }
}
