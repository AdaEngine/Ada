//
//  PreviewableMacro.swift
//  AdaEngineMacros
//

import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct PreviewableMacro: ExtensionMacro {
    public static func expansion<D: DeclGroupSyntax, T: TypeSyntaxProtocol, C: MacroExpansionContext>(
        of node: AttributeSyntax,
        attachedTo declaration: D,
        providingExtensionsOf type: T,
        conformingTo _: [TypeSyntax],
        in _: C
    ) throws -> [ExtensionDeclSyntax] {
        guard declaration.is(StructDeclSyntax.self) || declaration.is(ClassDeclSyntax.self) || declaration.is(EnumDeclSyntax.self) else {
            throw MacroError.macroUsage("Previewable macro can be applied only to nominal View types.")
        }

        guard
            declaration.inheritanceClause?.inheritedTypes
                .contains(where: { inheritedType in
                    ["View", "AdaUI.View", "AdaEngine.View"].contains(inheritedType.type.trimmedDescription)
                }) == true
        else {
            throw MacroError.macroUsage("Previewable macro can be applied only to types that conform to View.")
        }

        let access = declaration.previewableAccessModifier
        let titleExpression: ExprSyntax = "\(raw: previewTitleExpression(from: node) ?? "nil")"
        let extensionDecl: DeclSyntax =
            """
            extension \(type.trimmed): AdaUI.AdaPreviewable {
                \(raw: access)static var adaPreviewTitle: Swift.String? {
                    \(titleExpression)
                }

                @MainActor
                \(raw: access)static func makeAdaPreview() -> AdaUI.AnyView {
                    AdaUI.AnyView(Self())
                }
            }
            """

        return [extensionDecl.cast(ExtensionDeclSyntax.self)]
    }

    private static func previewTitleExpression(from node: AttributeSyntax) -> String? {
        guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else {
            return nil
        }

        guard let argument = arguments.first(where: { $0.label?.text == "title" }) ?? arguments.first else {
            return nil
        }

        let expression = argument.expression.trimmedDescription
        return expression.isEmpty ? nil : expression
    }
}

extension PreviewableMacro: PeerMacro {
    public static func expansion(
        of _: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in _: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let typeName = declaration.previewableTypeName else {
            throw MacroError.macroUsage("Previewable macro can be applied only to nominal View types.")
        }

        let symbolName = "ada_editor_preview_make_\(symbolComponent(for: typeName))"
        let peer: DeclSyntax =
            """
            @_cdecl("\(raw: symbolName)")
            @MainActor
            public func \(raw: symbolName)() -> UnsafeMutableRawPointer {
                Swift.Unmanaged.passRetained(
                    AdaUI.UIContainerView(rootView: \(raw: typeName).makeAdaPreview())
                ).toOpaque()
            }
            """

        return [peer]
    }

    private static func symbolComponent(for typeName: String) -> String {
        String(
            typeName.map { character in
                character.isLetter || character.isNumber || character == "_" ? character : "_"
            }
        )
    }
}

extension DeclSyntaxProtocol {
    var previewableTypeName: String? {
        if let structDecl = self.as(StructDeclSyntax.self) {
            return structDecl.name.text
        }
        if let classDecl = self.as(ClassDeclSyntax.self) {
            return classDecl.name.text
        }
        if let enumDecl = self.as(EnumDeclSyntax.self) {
            return enumDecl.name.text
        }
        return nil
    }

    var previewableAccessModifier: String {
        guard let declaration = self.asProtocol(DeclGroupSyntax.self) else {
            return ""
        }

        if declaration.modifiers.contains(where: { $0.name.tokenKind == .keyword(.public) || $0.name.tokenKind == .keyword(.open) }) {
            return "public "
        }

        return ""
    }
}
