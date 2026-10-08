//
//  RenderGraph.swift
//  AdaEngine
//
//  Created by v.prusakov on 2/15/23.
//

import AdaECS
import Logging

// Inspired by Bevy https://github.com/bevyengine/bevy/tree/main/crates/bevy_render/src/render_graph

public struct RenderContext: @unchecked Sendable {
    public let device: RenderDevice
    public let commandQueue: CommandQueue
    public let commandEncoder: CommandBuffer?

    public init(
        device: RenderDevice,
        commandQueue: CommandQueue,
        commandEncoder: CommandBuffer? = nil,
    ) {
        self.device = device
        self.commandEncoder = commandEncoder
        self.commandQueue = commandQueue
    }
}

public struct RenderSlot: Sendable {
    public let name: Self.Label
    public let kind: RenderResourceKind

    public init(name: Self.Label, kind: RenderResourceKind) {
        self.name = name
        self.kind = kind
    }
}

public struct RenderSlotValue: Sendable {
    public let name: RenderSlot.Label
    public let value: RenderResource

    public init(name: RenderSlot.Label, value: RenderResource) {
        self.name = name
        self.value = value
    }
}

public struct EmptyNode: RenderNode {
    public init() {}

    public func execute(context _: inout Context, renderContext _: RenderContext) -> [RenderSlotValue] {
        return []
    }
}

struct GraphEntryNode: RenderNode {
    var inputResources: [RenderSlot]
    var outputResources: [RenderSlot]

    init(inputResources: [RenderSlot]) {
        self.inputResources = inputResources
        self.outputResources = inputResources
    }

    func execute(context: inout Context, renderContext _: RenderContext) -> [RenderSlotValue] {
        return context.inputResources
    }
}

public struct RenderNodeLabel: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension RenderNodeLabel: ExpressibleByStringLiteral {
    public init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }
}

extension RenderSlot {
    public struct Label: RawRepresentable, Hashable, Sendable {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }
}

extension RenderSlot.Label: ExpressibleByStringLiteral {
    public init(stringLiteral value: StringLiteralType) {
        self.rawValue = value
    }
}

public struct RunGraphNode: RenderNode {
    public let graphName: RenderGraph.Label

    public init(graphName: RenderGraph.Label) {
        self.graphName = graphName
    }

    public func execute(
        context: inout Context,
        renderContext _: RenderContext
    ) async throws -> [RenderSlotValue] {
        context.runSubgraph(graphName, inputs: context.inputResources, viewEntity: context.viewEntity)
        return []
    }
}

// Inspired by Bevy Render Graph

/// The render graph configures the modular, parallel and re-usable render logic.
/// It is a retained and stateless (nodes themselves may have their own internal state) structure,
/// which can not be modified while it is executed by the graph runner.
///
///  The ``RenderGraphExecutor`` is responsible for executing the entire graph each frame.
///
public struct RenderGraph: Resource {
    public static let entryNodeName: RenderNodeLabel = "_GraphEntryNode"

    enum Edge: Equatable, Hashable {
        case slot(
            outputNode: RenderNodeLabel,
            outputSlotIndex: Int,
            inputNode: RenderNodeLabel,
            inputSlotIndex: Int
        )
        case node(
            outputNode: RenderNodeLabel,
            inputNode: RenderNodeLabel
        )

        var inputNode: RenderNodeLabel {
            switch self {
            case let .node(_, inputNode):
                return inputNode
            case let .slot(_, _, inputNode, _):
                return inputNode
            }
        }

        var outputNode: RenderNodeLabel {
            switch self {
            case let .node(outputNode, _):
                return outputNode
            case let .slot(outputNode, _, _, _):
                return outputNode
            }
        }
    }

    struct Node: Sendable {
        typealias ID = RenderNodeLabel

        let name: RenderNodeLabel
        let node: RenderNode

        var inputEdges: [Edge] = []
        var outputEdges: [Edge] = []
    }

    let label: Label?
    private let logger: Logger

    internal private(set) var nodes: [RenderNodeLabel: Node] = [:]
    internal private(set) var subGraphs: [Label: Self] = [:]

    internal private(set) var entryNode: Node?

    nonisolated public init(label: Label? = nil) {
        self.label = label
        self.logger = Logger(label: label.flatMap { "RenderGraph(\($0))" } ?? "RenderGraph")
    }

    public func update(from world: World) {
        for node in nodes {
            node.value.node.update(from: world)
        }

        for graph in self.subGraphs {
            graph.value.update(from: world)
        }
    }

    public mutating func addEntryNode(inputs: [RenderSlot]) -> RenderNodeLabel {
        let node = GraphEntryNode(inputResources: inputs)
        let renderNode = Node(name: Self.entryNodeName, node: node)
        self.nodes[Self.entryNodeName] = renderNode
        self.entryNode = renderNode

        return Self.entryNodeName
    }

    @inline(__always)
    public mutating func addNode<T: RenderNode>(_ node: T) {
        self.addNode(node, by: T.name)
    }

    public mutating func addNode(_ node: RenderNode, by name: RenderNodeLabel) {
        self.nodes[name] = Node(name: name, node: node)
    }

    @inline(__always)
    public mutating func addSlotEdge<From: RenderNode, To: RenderNode>(
        from _: From.Type,
        outputSlot: RenderSlot.Label,
        to _: To.Type,
        inputSlot: RenderSlot.Label
    ) {
        self.addSlotEdge(
            fromNode: From.name,
            outputSlot: outputSlot,
            toNode: To.name,
            inputSlot: inputSlot
        )
    }

    public mutating func addSlotEdge(
        fromNode outputNode: RenderNodeLabel,
        outputSlot: RenderSlot.Label,
        toNode inputNode: RenderNodeLabel,
        inputSlot: RenderSlot.Label
    ) {
        let oNode = self.nodes[outputNode]
        let iNode = self.nodes[inputNode]
        assert(oNode != nil, "Can't find node by name \(outputNode)")
        assert(iNode != nil, "Can't find node by name \(inputNode)")
        guard var iNode, var oNode else {
            return
        }

        let outputSlotIndex = oNode.node.outputResources.firstIndex(where: { $0.name == outputSlot })
        let inputSlotIndex = iNode.node.inputResources.firstIndex(where: { $0.name == inputSlot })
        assert(outputSlotIndex != nil, "Can't find slot by name \(outputSlot)")
        assert(inputSlotIndex != nil, "Can't find slot by name \(inputSlot)")

        guard let outputSlotIndex, let inputSlotIndex else {
            return
        }

        let edge = Edge.slot(
            outputNode: outputNode,
            outputSlotIndex: outputSlotIndex,
            inputNode: inputNode,
            inputSlotIndex: inputSlotIndex
        )

        guard self.validateEdge(edge, shouldExsits: false) else {
            return
        }

        oNode.outputEdges.append(edge)
        iNode.inputEdges.append(edge)

        self.nodes[outputNode] = oNode
        self.nodes[inputNode] = iNode
    }

    @inline(__always)
    public mutating func addNodeEdge<From: RenderNode, To: RenderNode>(from _: From.Type, to _: To.Type) {
        self.addNodeEdge(from: From.name, to: To.name)
    }

    public mutating func addNodeEdge(from outputNode: RenderNodeLabel, to inputNode: RenderNodeLabel) {
        let oNode = self.nodes[outputNode]
        let iNode = self.nodes[inputNode]
        assert(oNode != nil, "Can't find node by name \(outputNode)")
        assert(iNode != nil, "Can't find node by name \(inputNode)")
        guard var iNode, var oNode else {
            return
        }

        let edge = Edge.node(outputNode: outputNode, inputNode: inputNode)

        oNode.outputEdges.append(edge)
        iNode.inputEdges.append(edge)

        self.nodes[outputNode] = oNode
        self.nodes[inputNode] = iNode
    }

    /// Removes a node-to-node edge if it exists.
    @discardableResult
    public mutating func removeNodeEdge(from outputNode: RenderNodeLabel, to inputNode: RenderNodeLabel) -> Bool {
        let edge = Edge.node(outputNode: outputNode, inputNode: inputNode)
        guard var oNode = self.nodes[outputNode], var iNode = self.nodes[inputNode] else {
            return false
        }
        if !self.hasEdge(edge) {
            return false
        }
        oNode.outputEdges.removeAll(where: { $0 == edge })
        iNode.inputEdges.removeAll(where: { $0 == edge })
        self.nodes[outputNode] = oNode
        self.nodes[inputNode] = iNode
        return true
    }

    @inline(__always)
    public mutating func removeNode<T: RenderNode>(by _: T.Type) -> Bool {
        self.removeNode(by: T.name)
    }

    public mutating func removeNode(by name: RenderNodeLabel) -> Bool {
        guard let node = self.nodes.removeValue(forKey: name) else {
            logger.error(
                "Node not exists",
                metadata: [
                    "graph": .string(self.label?.rawValue ?? "Unknonw")
                ]
            )
            return false
        }

        for edge in node.inputEdges {
            self.nodes[edge.outputNode]?.outputEdges.removeAll(where: { edge == $0 })
        }

        for edge in node.outputEdges {
            self.nodes[edge.inputNode]?.inputEdges.removeAll(where: { edge == $0 })
        }

        return true
    }

    @inline(__always)
    public mutating func removeSlotEdge<From: RenderNode, To: RenderNode>(
        from _: From.Type,
        outputSlot: RenderSlot.Label,
        to _: To.Type,
        inputSlot: RenderSlot.Label
    ) -> Bool {
        self.removeSlotEdge(fromNode: From.name, outputSlot: outputSlot, toNode: To.name, inputSlot: inputSlot)
    }

    public mutating func removeSlotEdge(
        fromNode outputNode: RenderNodeLabel,
        outputSlot _: RenderSlot.Label,
        toNode inputNode: RenderNodeLabel,
        inputSlot _: RenderSlot.Label
    ) -> Bool {
        guard
            var oNode = self.nodes[outputNode],
            var iNode = self.nodes[inputNode],
            let outputSlotIndex = oNode.node.outputResources.firstIndex(where: { $0.name.rawValue == outputNode.rawValue }),
            let inputSlotIndex = iNode.node.inputResources.firstIndex(where: { $0.name.rawValue == inputNode.rawValue })
        else {
            return false
        }

        let edge = Edge.slot(
            outputNode: outputNode,
            outputSlotIndex: outputSlotIndex,
            inputNode: inputNode,
            inputSlotIndex: inputSlotIndex
        )

        if !self.hasEdge(edge) {
            return false
        }

        oNode.outputEdges.removeAll(where: { $0 == edge })
        iNode.inputEdges.removeAll(where: { $0 == edge })

        self.nodes[outputNode] = oNode
        self.nodes[inputNode] = iNode

        return true
    }

    public mutating func addSubgraph(_ graph: Self, name: Label) {
        self.subGraphs[name] = graph
    }

    public func getSubgraph(by name: Label) -> Self? {
        return self.subGraphs[name]
    }

    public mutating func updateSubgraph(
        by name: Label,
        block: (inout Self) -> Void
    ) throws(RenderGraphError) {
        guard var graph = self.subGraphs[name] else {
            throw RenderGraphError.subgraphNotExists(name.rawValue)
        }
        block(&graph)
        self.subGraphs[name] = graph
    }

    // MARK: Private

    internal func getOutputNodes(for node: Node.ID) -> [(Edge, Node)] {
        guard let node = self.nodes[node] else {
            return []
        }

        return node.outputEdges.compactMap { edge in
            guard let node = self.nodes[edge.inputNode] else {
                return nil
            }

            return (edge, node)
        }
    }

    internal func getInputNodes(for node: Node.ID) -> [(Edge, Node)] {
        guard let node = self.nodes[node] else {
            return []
        }

        return node.inputEdges.compactMap { edge in
            guard let node = self.nodes[edge.outputNode] else {
                return nil
            }

            return (edge, node)
        }
    }

    private func hasEdge(_ edge: Edge) -> Bool {
        switch edge {
        case let .slot(outputNode, _, inputNode, _):
            guard let oNode = self.nodes[outputNode], let iNode = self.nodes[inputNode] else {
                return false
            }

            return oNode.outputEdges.contains(edge) && iNode.inputEdges.contains(edge)
        case let .node(outputNode, inputNode):
            guard let oNode = self.nodes[outputNode], let iNode = self.nodes[inputNode] else {
                return false
            }

            return oNode.outputEdges.contains(edge) && iNode.inputEdges.contains(edge)
        }
    }

    // TODO: (Vlad) Throw errors?
    private func validateEdge(_ edge: Edge, shouldExsits: Bool) -> Bool {
        if !shouldExsits && hasEdge(edge) {
            return false
        }

        // We should validate only slots
        guard case let .slot(outputNode, outputSlotIndex, inputNode, inputSlotIndex) = edge else {
            return true
        }

        guard let oNode = self.nodes[outputNode], let iNode = self.nodes[inputNode] else {
            self.logger.error("[Validation Error] Nodes not exists. Output: \(outputNode), Input: \(inputNode)")
            return false
        }

        let outputSlot = oNode.node.outputResources[outputSlotIndex]
        let inputSlot = iNode.node.inputResources[inputSlotIndex]

        let isSlotConnected = iNode.inputEdges.contains(where: { edge in
            guard case let .slot(_, _, _, slotIndex) = edge else {
                return false
            }

            return slotIndex == outputSlotIndex
        })

        if isSlotConnected && !shouldExsits {
            self.logger.error("[Validation Error] Slot already connected. Output slot: \(outputSlot.name), Input slot: \(inputSlot.name)")
            return false
        }

        if outputSlot.kind != inputSlot.kind {
            self.logger.error("[Validation Error] Mismatched types. Output slot: \((outputSlot.name, outputSlot.kind.rawValue)), Input slot: \((inputSlot.name, inputSlot.kind.rawValue))")
            return false
        }

        return true
    }
}

extension RenderGraph {
    public struct Label: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: StringLiteralType) {
            self.rawValue = value
        }
    }
}

public enum RenderGraphError: Error, CustomStringConvertible {
    case subgraphNotExists(String)

    public var description: String {
        switch self {
        case let .subgraphNotExists(string):
            "Subgraph by name \(string) not exists"
        }
    }
}

extension RenderGraph: CustomDebugStringConvertible {
    public var debugDescription: String {
        var lines: [String] = []
        let graphName = label?.rawValue ?? "RenderGraph"

        // Header
        let headerLine = String(repeating: "═", count: graphName.count + 4)
        lines.append("╔\(headerLine)╗")
        lines.append("║  \(graphName)  ║")
        lines.append("╚\(headerLine)╝")
        lines.append("")

        // Collect all unique edges for visualization
        var uniqueEdges: Set<Edge> = []
        for node in self.nodes.values {
            for edge in node.outputEdges {
                uniqueEdges.insert(edge)
            }
        }

        // Nodes section
        lines.append("┌─ Nodes (\(nodes.count)) ─────────────────────────────")
        for node in self.nodes.values.sorted(by: { $0.name.rawValue < $1.name.rawValue }) {
            let inputSlots = node.node.inputResources.map { "[\($0.name.rawValue):\($0.kind.rawValue)]" }.joined(separator: ", ")
            let outputSlots = node.node.outputResources.map { "[\($0.name.rawValue):\($0.kind.rawValue)]" }.joined(separator: ", ")

            lines.append("│")
            lines.append("│  ┌─ \(node.name.rawValue)")
            if !inputSlots.isEmpty {
                lines.append("│  │  ⬇ in:  \(inputSlots)")
            }
            if !outputSlots.isEmpty {
                lines.append("│  │  ⬆ out: \(outputSlots)")
            }
            lines.append("│  └───")
        }
        lines.append("│")
        lines.append("└──────────────────────────────────────────")
        lines.append("")

        // Data Flow section
        lines.append("┌─ Data Flow ──────────────────────────────")

        if uniqueEdges.isEmpty {
            lines.append("│  (no connections)")
        } else {
            for edge in uniqueEdges.sorted(by: { edgeSortKey($0) < edgeSortKey($1) }) {
                switch edge {
                case let .slot(outputNode, outputSlotIndex, inputNode, inputSlotIndex):
                    let oNode = self.nodes[outputNode]
                    let iNode = self.nodes[inputNode]
                    let outputSlotName = oNode?.node.outputResources[safe: outputSlotIndex]?.name.rawValue ?? "?"
                    let inputSlotName = iNode?.node.inputResources[safe: inputSlotIndex]?.name.rawValue ?? "?"

                    lines.append("│")
                    lines.append("│  \(outputNode.rawValue)")
                    lines.append("│       │")
                    lines.append("│       ╰──[\(outputSlotName)]──▶──[\(inputSlotName)]──╮")
                    lines.append("│                                  │")
                    lines.append("│                          \(inputNode.rawValue)")

                case let .node(outputNode, inputNode):
                    lines.append("│")
                    lines.append("│  \(outputNode.rawValue)")
                    lines.append("│       │")
                    lines.append("│       ╰────── (exec) ──────▶ \(inputNode.rawValue)")
                }
            }
        }

        lines.append("│")
        lines.append("└──────────────────────────────────────────")

        // Subgraphs section
        if !subGraphs.isEmpty {
            lines.append("")
            lines.append("┌─ Subgraphs (\(subGraphs.count)) ────────────────────────")
            for (name, subgraph) in subGraphs.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                lines.append("│  • \(name) (\(subgraph.nodes.count) nodes)")
            }
            lines.append("└──────────────────────────────────────────")
        }

        return lines.joined(separator: "\n")
    }

    private func edgeSortKey(_ edge: Edge) -> String {
        switch edge {
        case let .slot(outputNode, _, inputNode, _):
            return "\(outputNode.rawValue)->\(inputNode.rawValue)"
        case let .node(outputNode, inputNode):
            return "\(outputNode.rawValue)->\(inputNode.rawValue)"
        }
    }
}

extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
