//
//  Extensions.swift
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

extension Array where Element == String {
    var withQualified: Self {
        self.flatMap { [$0, "AdaEngine.\($0)"] }
    }
}

extension AttributeSyntax {
    var availability: AttributeSyntax? {
        if attributeName.identifier == "available" {
            return self
        } else {
            return nil
        }
    }
}

extension IfConfigClauseSyntax.Elements {
    var availability: IfConfigClauseSyntax.Elements? {
        switch self {
        case let .attributes(attributes):
            if let availability = attributes.availability {
                return .attributes(availability)
            } else {
                return nil
            }
        default:
            return nil
        }
    }
}

extension IfConfigClauseSyntax {
    var availability: IfConfigClauseSyntax? {
        if let availability = elements?.availability {
            return with(\.elements, availability)
        } else {
            return nil
        }
    }

    var clonedAsIf: IfConfigClauseSyntax {
        detached.with(\.poundKeyword, .poundIfToken())
    }
}

extension IfConfigDeclSyntax {
    var availability: IfConfigDeclSyntax? {
        var elements = [IfConfigClauseListSyntax.Element]()
        for clause in clauses {
            if let availability = clause.availability {
                if elements.isEmpty {
                    elements.append(availability.clonedAsIf)
                } else {
                    elements.append(availability)
                }
            }
        }
        if elements.isEmpty {
            return nil
        } else {
            return with(\.clauses, IfConfigClauseListSyntax(elements))
        }
    }
}

extension AttributeListSyntax.Element {
    var availability: AttributeListSyntax.Element? {
        switch self {
        case let .attribute(attribute):
            if let availability = attribute.availability {
                return .attribute(availability)
            }
        case let .ifConfigDecl(ifConfig):
            if let availability = ifConfig.availability {
                return .ifConfigDecl(availability)
            }
        }
        return nil
    }
}

extension AttributeListSyntax {
    var availability: AttributeListSyntax? {
        var elements = [Self.Element]()
        for element in self {
            if let availability = element.availability {
                elements.append(availability)
            }
        }
        if elements.isEmpty {
            return nil
        }
        return AttributeListSyntax(elements)
    }
}

extension SyntaxStringInterpolation {
    // It would be nice for SwiftSyntaxBuilder to provide this out-of-the-box.
    mutating func appendInterpolation<Node: SyntaxProtocol>(_ node: Node?) {
        if let node {
            appendInterpolation(node)
        }
    }
}

extension TypeSyntax {
    var identifier: String? {
        for token in tokens(viewMode: .all) {
            switch token.tokenKind {
            case let .identifier(identifier):
                return identifier
            default:
                break
            }
        }
        return nil
    }
}

extension FreestandingMacroExpansionSyntax {
    func argument(for label: String) -> ExprSyntax? {
        arguments.first(where: { $0.label?.text == label })?.expression
    }
}

extension AttributeSyntax {
    func argument(for label: String) -> ExprSyntax? {
        arguments?.as(LabeledExprListSyntax.self)?.first(where: { $0.label?.text == label })?.expression
    }
}
