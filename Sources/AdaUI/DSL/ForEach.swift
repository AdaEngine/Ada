//
//  ForEach.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 21.06.2024.
//

/// A structure that computes Views on demand from an underlying collection of
/// identified data.
public struct ForEach<Data: RandomAccessCollection, ID: Hashable, Content: View>: View {
    public typealias Body = Never
    public var body: Never { fatalError("Unreachable code") }

    let data: Data
    var content: (Data.Element) -> Content
    let idProvider: ((Data.Element) -> AnyHashable)?

    @MainActor @preconcurrency
    public static func _makeView(_ view: _ViewGraphNode<Self>, inputs: _ViewInputs) -> _ViewOutputs {
        let data = view[\.data].value
        let contentBlock = view[\.content].value
        let idProvider = view[\.idProvider].value

        let node = LayoutViewContainerNode(layout: inputs.layout, content: view.value) { [contentBlock] listInputs in
            let outputs = data.map { item in
                let content = contentBlock(item)
                if let idProvider {
                    let idView = IDView(id: idProvider(item), content: content)
                    return IDView._makeView(_ViewGraphNode(value: idView), inputs: listInputs.input)
                } else {
                    return Content._makeView(_ViewGraphNode(value: content), inputs: listInputs.input)
                }
            }

            return _ViewListOutputs(outputs: outputs)
        }

        node.isVirtual = true
        node.updateEnvironment(inputs.environment)
        node.invalidateContent()

        return _ViewOutputs(node: node)
    }

    @MainActor @preconcurrency
    public static func _makeListView(_ view: _ViewGraphNode<Self>, inputs: _ViewListInputs) -> _ViewListOutputs {
        let data = view[\.data].value
        let contentBlock = view[\.content].value
        let idProvider = view[\.idProvider].value

        let outputs = data.map { item in
            let content = contentBlock(item)
            if let idProvider {
                let idView = IDView(id: idProvider(item), content: content)
                return IDView._makeView(_ViewGraphNode(value: idView), inputs: inputs.input)
            } else {
                return Content._makeView(_ViewGraphNode(value: content), inputs: inputs.input)
            }
        }

        return _ViewListOutputs(outputs: outputs)
    }
}

extension ForEach where ID == Data.Element.ID, Data.Element: Identifiable {
    /// Creates an instance that uniquely identifies and creates views across
    /// updates based on the identity of the underlying data.
    ///
    /// It's important that the `id` of a data element doesn't change unless you
    /// replace the data element with a new data element that has a new
    /// identity. If the `id` of a data element changes, the content view
    /// generated from that data element loses any current state and animations.
    ///
    /// - Parameters:
    ///   - data: The identified data that the ``ForEach`` instance uses to
    ///     create views dynamically.
    ///   - content: The View builder that creates Views dynamically.
    public init(_ data: Data, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
        self.idProvider = { AnyHashable($0.id) }
    }
}

extension ForEach {
    /// Creates an instance that uniquely identifies and creates widegts across
    /// updates based on the provided key path to the underlying data's
    /// identifier.
    ///
    /// It's important that the `id` of a data element doesn't change, unless
    /// AdaEngine considers the data element to have been replaced with a new data
    /// element that has a new identity. If the `id` of a data element changes,
    /// then the content view generated from that data element will lose any
    /// current state and animations.
    ///
    /// - Parameters:
    ///   - data: The data that the ``ForEach`` instance uses to create views
    ///     dynamically.
    ///   - id: The key path to the provided data's identifier.
    ///   - content: The View builder that creates Views dynamically.
    public init(_ data: Data, id: KeyPath<Data.Element, ID>, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.content = content
        self.idProvider = { AnyHashable($0[keyPath: id]) }
    }
}

extension ForEach where Data == Range<Int>, ID == Int {
    /// Creates an instance that computes Views on demand over a given constant
    /// range.
    ///
    /// The instance only reads the initial value of the provided `data` and
    /// doesn't need to identify Viewss across updates. To compute Views on
    /// demand over a dynamic range, use ``ForEach/init(_:id:content:)``.
    ///
    /// - Parameters:
    ///   - data: A constant range.
    ///   - content: The View builder that creates Views dynamically.
    public init(_ data: Range<Int>, @ViewBuilder content: @escaping (Int) -> Content) {
        self.data = data
        self.content = content
        self.idProvider = nil
    }
}
