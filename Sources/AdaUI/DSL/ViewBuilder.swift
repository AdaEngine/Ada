//
//  ViewBuilder.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 07.06.2024.
//

/// A custom parameter attribute that constructs views from closures.
///
/// You typically use ``ViewBuilder`` as a parameter attribute for child view-producing closure parameters, allowing those closures to provide multiple child views.
@MainActor
@resultBuilder public enum ViewBuilder {
    /// Builds an empty view from a block containing no statements.
    @_alwaysEmitIntoClient
    public static func buildBlock() -> EmptyView {
        return EmptyView()
    }

    /// Passes a single view written as a child view through unmodified.
    @_alwaysEmitIntoClient
    public static func buildBlock<Content>(_ content: Content) -> Content where Content: View {
        return content
    }

    /// Passes a single view written as a child view through unmodified.
    @_alwaysEmitIntoClient
    public static func buildBlock<each Content>(_ content: repeat each Content) -> ViewTuple<(repeat each Content)> where repeat each Content: View {
        return ViewTuple(value: (repeat each content))
    }

    /// Builds an expression within the builder.
    @_alwaysEmitIntoClient
    public static func buildExpression<Content>(_ content: Content) -> Content where Content: View {
        content
    }
}

extension ViewBuilder {
    /// Produces an optional view for conditional statements in multi-statement closures that’s only visible when the condition evaluates to true.
    @_alwaysEmitIntoClient
    public static func buildIf<Content>(_ content: Content?) -> Content? where Content: View {
        content
    }

    /// Produces content for a conditional statement in a multi-statement closure when the condition is true.
    @_alwaysEmitIntoClient
    public static func buildEither<TrueContent, FalseContent>(first: TrueContent) -> _ConditionalContent<TrueContent, FalseContent> where TrueContent: View, FalseContent: View {
        _ConditionalContent(storage: .trueContent(first))
    }

    /// Produces content for a conditional statement in a multi-statement closure when the condition is false.
    @_alwaysEmitIntoClient
    public static func buildEither<TrueContent, FalseContent>(second: FalseContent) -> _ConditionalContent<TrueContent, FalseContent> where TrueContent: View, FalseContent: View {
        _ConditionalContent(storage: .falseContent(second))
    }
}

extension ViewBuilder {
    /// Processes view content for a conditional compiler-control
    /// statement that performs an availability check.
    public static func buildLimitedAvailability<Content>(_ content: Content) -> AnyView where Content: View {
        AnyView(content)
    }
}

public struct _ConditionalContent<TrueContent, FalseContent> {
    public enum Storage {
        case trueContent(TrueContent)
        case falseContent(FalseContent)
    }

    let storage: _ConditionalContent<TrueContent, FalseContent>.Storage

    public init(storage: Storage) {
        self.storage = storage
    }
}

extension _ConditionalContent: View where TrueContent: View, FalseContent: View {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    @MainActor @preconcurrency
    public static func _makeView(_ view: _ViewGraphNode<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let branchIdentity = view.value.branchIdentity
        var output: _ViewOutputs
        switch view[\.storage].value {
        case let .trueContent(trueContent):
            output = TrueContent._makeView(_ViewGraphNode(value: trueContent), inputs: inputs)
        case let .falseContent(falseContent):
            output = FalseContent._makeView(_ViewGraphNode(value: falseContent), inputs: inputs)
        }
        output.node.prependStructuralIdentity(branchIdentity)
        return output
    }

    @MainActor @preconcurrency
    public static func _makeListView(_ view: _ViewGraphNode<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        let branchIdentity = view.value.branchIdentity
        var outputs: _ViewListOutputs
        switch view[\.storage].value {
        case let .trueContent(trueContent):
            outputs = TrueContent._makeListView(_ViewGraphNode(value: trueContent), inputs: inputs)
        case let .falseContent(falseContent):
            outputs = FalseContent._makeListView(_ViewGraphNode(value: falseContent), inputs: inputs)
        }
        for index in outputs.outputs.indices {
            outputs.outputs[index].node.prependStructuralIdentity(branchIdentity)
        }
        return outputs
    }

    private var branchIdentity: AnyHashable {
        switch storage {
        case .trueContent:
            return "_ConditionalContent.true:\(ObjectIdentifier(TrueContent.self)):\(ObjectIdentifier(FalseContent.self))"
        case .falseContent:
            return "_ConditionalContent.false:\(ObjectIdentifier(TrueContent.self)):\(ObjectIdentifier(FalseContent.self))"
        }
    }
}

extension ViewNode {
    func prependStructuralIdentity(_ identity: AnyHashable) {
        if let structuralIdentity {
            self.structuralIdentity = "\(identity)|\(structuralIdentity)"
        } else {
            self.structuralIdentity = identity
        }
    }
}
