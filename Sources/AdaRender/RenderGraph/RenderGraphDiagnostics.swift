//
//  RenderGraphDiagnostics.swift
//  AdaEngine
//

import AdaECS
import Foundation
import Math

public struct RenderGraphSlotSnapshot: Codable, Hashable, Sendable {
    public let name: String
    public let kind: String
}

public struct RenderGraphNodeSnapshot: Codable, Hashable, Sendable {
    public let label: String
    public let typeName: String
    public let inputSlots: [RenderGraphSlotSnapshot]
    public let outputSlots: [RenderGraphSlotSnapshot]
    public let inputEdgeCount: Int
    public let outputEdgeCount: Int
}

public struct RenderGraphEdgeSnapshot: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case node
        case slot
    }

    public let kind: Kind
    public let fromNode: String
    public let toNode: String
    public let outputSlot: String?
    public let outputSlotKind: String?
    public let inputSlot: String?
    public let inputSlotKind: String?
}

public struct RenderGraphIssue: Codable, Hashable, Sendable {
    public enum Severity: String, Codable, Sendable {
        case info
        case warning
        case error
    }

    public let severity: Severity
    public let code: String
    public let message: String
    public let node: String?
}

public struct RenderGraphSnapshot: Codable, Hashable, Sendable {
    public let label: String
    public let entryNode: String?
    public let nodes: [RenderGraphNodeSnapshot]
    public let edges: [RenderGraphEdgeSnapshot]
    public let subgraphs: [Self]
    public let issues: [RenderGraphIssue]
}

public struct RenderResourceSummary: Codable, Hashable, Sendable {
    public let name: String
    public let kind: String
    public let typeName: String
    public let label: String?
    public let width: Int?
    public let height: Int?
    public let length: Int?
    public let entityID: Int?
    public let entityName: String?

    init(slotValue: RenderSlotValue) {
        self.name = slotValue.name.rawValue
        self.kind = slotValue.value.resourceKind.rawValue

        switch slotValue.value {
        case let .texture(texture):
            self.typeName = String(reflecting: Swift.type(of: texture))
            self.label = texture.gpuTexture.label
            self.width = texture.gpuTexture.size.width
            self.height = texture.gpuTexture.size.height
            self.length = nil
            self.entityID = nil
            self.entityName = nil
        case let .buffer(buffer):
            self.typeName = String(reflecting: Swift.type(of: buffer))
            self.label = buffer.label
            self.width = nil
            self.height = nil
            self.length = buffer.length
            self.entityID = nil
            self.entityName = nil
        case let .sampler(sampler):
            self.typeName = String(reflecting: Swift.type(of: sampler))
            self.label = nil
            self.width = nil
            self.height = nil
            self.length = nil
            self.entityID = nil
            self.entityName = nil
        case let .entity(entity):
            self.typeName = String(reflecting: Swift.type(of: entity))
            self.label = nil
            self.width = nil
            self.height = nil
            self.length = nil
            self.entityID = entity.id
            self.entityName = entity.name
        }
    }
}

public struct RenderTargetAttachmentSummary: Codable, Hashable, Sendable {
    public let name: String
    public let isAvailable: Bool
    public let typeName: String?
    public let label: String?
    public let width: Int?
    public let height: Int?
    public let pixelFormat: String?
    public let scaleFactor: Float?
    public let isReadableColor: Bool
    public let unsupportedReason: String?

    public init(name: String, texture: RenderTexture?) {
        self.name = name
        guard let texture else {
            self.isAvailable = false
            self.typeName = nil
            self.label = nil
            self.width = nil
            self.height = nil
            self.pixelFormat = nil
            self.scaleFactor = nil
            self.isReadableColor = false
            self.unsupportedReason = "Attachment is not allocated."
            return
        }

        self.isAvailable = true
        self.typeName = String(reflecting: Swift.type(of: texture))
        self.label = texture.gpuTexture.label
        self.width = texture.width
        self.height = texture.height
        self.pixelFormat = String(describing: texture.pixelFormat)
        self.scaleFactor = texture.scaleFactor
        self.isReadableColor = !String(describing: texture.pixelFormat).contains("depth")
        self.unsupportedReason = self.isReadableColor ? nil : "Depth/stencil attachment readback is not supported by render_graph.dump_attachment v1."
    }
}

public struct RenderGraphNodeRecord: Codable, Hashable, Sendable {
    public let label: String
    public let typeName: String
    public let inputResources: [RenderResourceSummary]
    public let outputResources: [RenderResourceSummary]
    public let pendingSubgraphs: [String]
    public let durationMilliseconds: Double
    public let error: String?
}

public struct RenderGraphFrameRecord: Codable, Hashable, Sendable {
    public let frameIndex: Int
    public let graphLabel: String
    public let isSubgraph: Bool
    public let viewEntityID: Int?
    public let viewEntityName: String?
    public let executionOrder: [String]
    public let nodes: [RenderGraphNodeRecord]
    public let pendingSubgraphs: [String]
    public let durationMilliseconds: Double
    public let error: String?
}

public final class RenderGraphDiagnostics: @unchecked Sendable, Resource {
    public private(set) var records: [RenderGraphFrameRecord] = []
    public var isEnabled: Bool
    public var capacity: Int
    private var nextFrameIndex: Int = 0

    public init(isEnabled: Bool = false, capacity: Int = 120) {
        self.isEnabled = isEnabled
        self.capacity = max(capacity, 1)
    }

    public func configure(isEnabled: Bool, capacity: Int? = nil) {
        self.isEnabled = isEnabled
        if let capacity {
            self.capacity = max(capacity, 1)
            trimToCapacity()
        }
    }

    public func clear() {
        records.removeAll(keepingCapacity: true)
    }

    public func recentFrames(limit: Int? = nil) -> [RenderGraphFrameRecord] {
        guard let limit, limit > 0, records.count > limit else {
            return records
        }
        return Array(records.suffix(limit))
    }

    func makeFrameIndex() -> Int {
        defer { nextFrameIndex += 1 }
        return nextFrameIndex
    }

    func append(_ record: RenderGraphFrameRecord) {
        guard isEnabled else {
            return
        }
        records.append(record)
        trimToCapacity()
    }

    private func trimToCapacity() {
        guard records.count > capacity else {
            return
        }
        records.removeFirst(records.count - capacity)
    }
}

extension RenderGraph {
    public func makeSnapshot(includeSubgraphs: Bool = true) -> RenderGraphSnapshot {
        let sortedNodes = nodes.values.sorted { $0.name.rawValue < $1.name.rawValue }
        let nodeSnapshots = sortedNodes.map { node in
            RenderGraphNodeSnapshot(
                label: node.name.rawValue,
                typeName: String(reflecting: Swift.type(of: node.node)),
                inputSlots: node.node.inputResources.map { RenderGraphSlotSnapshot(slot: $0) },
                outputSlots: node.node.outputResources.map { RenderGraphSlotSnapshot(slot: $0) },
                inputEdgeCount: node.inputEdges.count,
                outputEdgeCount: node.outputEdges.count
            )
        }

        var uniqueEdges: Set<Edge> = []
        for node in nodes.values {
            for edge in node.outputEdges {
                uniqueEdges.insert(edge)
            }
        }

        let edgeSnapshots =
            uniqueEdges
            .sorted { edgeSortKey($0) < edgeSortKey($1) }
            .map(makeEdgeSnapshot)

        let subgraphSnapshots =
            includeSubgraphs
            ? subGraphs
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map { $0.value.makeSnapshot(includeSubgraphs: true) }
            : []

        return RenderGraphSnapshot(
            label: label?.rawValue ?? "RenderGraph",
            entryNode: entryNode?.name.rawValue,
            nodes: nodeSnapshots,
            edges: edgeSnapshots,
            subgraphs: subgraphSnapshots,
            issues: makeIssues(edges: uniqueEdges)
        )
    }

    private func makeEdgeSnapshot(_ edge: Edge) -> RenderGraphEdgeSnapshot {
        switch edge {
        case let .node(outputNode, inputNode):
            return RenderGraphEdgeSnapshot(
                kind: .node,
                fromNode: outputNode.rawValue,
                toNode: inputNode.rawValue,
                outputSlot: nil,
                outputSlotKind: nil,
                inputSlot: nil,
                inputSlotKind: nil
            )
        case let .slot(outputNode, outputSlotIndex, inputNode, inputSlotIndex):
            let outputSlot = nodes[outputNode]?.node.outputResources[validated: outputSlotIndex]
            let inputSlot = nodes[inputNode]?.node.inputResources[validated: inputSlotIndex]
            return RenderGraphEdgeSnapshot(
                kind: .slot,
                fromNode: outputNode.rawValue,
                toNode: inputNode.rawValue,
                outputSlot: outputSlot?.name.rawValue,
                outputSlotKind: outputSlot?.kind.rawValue,
                inputSlot: inputSlot?.name.rawValue,
                inputSlotKind: inputSlot?.kind.rawValue
            )
        }
    }

    private func makeIssues(edges: Set<Edge>) -> [RenderGraphIssue] {
        var issues: [RenderGraphIssue] = []

        if nodes.isEmpty {
            issues.append(
                .init(
                    severity: .warning,
                    code: "empty_graph",
                    message: "Render graph has no nodes.",
                    node: nil
                )
            )
        }

        if !nodes.isEmpty && nodes.values.allSatisfy({ !$0.inputEdges.isEmpty }) {
            issues.append(
                .init(
                    severity: .error,
                    code: "empty_executable_graph",
                    message: "Render graph has no node without input dependencies, so execution cannot start.",
                    node: nil
                )
            )
        }

        for node in nodes.values where node.name != Self.entryNodeName && node.inputEdges.isEmpty && node.outputEdges.isEmpty {
            issues.append(
                .init(
                    severity: .warning,
                    code: "disconnected_node",
                    message: "Node has no input or output edges.",
                    node: node.name.rawValue
                )
            )
        }

        for edge in edges {
            switch edge {
            case let .node(outputNode, inputNode):
                if nodes[outputNode] == nil {
                    issues.append(missingNodeIssue(outputNode, edge: edge))
                }
                if nodes[inputNode] == nil {
                    issues.append(missingNodeIssue(inputNode, edge: edge))
                }
            case let .slot(outputNode, outputSlotIndex, inputNode, inputSlotIndex):
                guard let output = nodes[outputNode], let input = nodes[inputNode] else {
                    if nodes[outputNode] == nil {
                        issues.append(missingNodeIssue(outputNode, edge: edge))
                    }
                    if nodes[inputNode] == nil {
                        issues.append(missingNodeIssue(inputNode, edge: edge))
                    }
                    continue
                }
                guard let outputSlot = output.node.outputResources[validated: outputSlotIndex] else {
                    issues.append(invalidSlotIssue(node: outputNode, slotIndex: outputSlotIndex, edge: edge))
                    continue
                }
                guard let inputSlot = input.node.inputResources[validated: inputSlotIndex] else {
                    issues.append(invalidSlotIssue(node: inputNode, slotIndex: inputSlotIndex, edge: edge))
                    continue
                }
                if outputSlot.kind != inputSlot.kind {
                    issues.append(
                        .init(
                            severity: .error,
                            code: "slot_kind_mismatch",
                            message: "Slot edge connects \(outputSlot.kind.rawValue) output to \(inputSlot.kind.rawValue) input.",
                            node: inputNode.rawValue
                        )
                    )
                }
            }
        }

        for node in nodes.values {
            if let runGraphNode = node.node as? RunGraphNode, subGraphs[runGraphNode.graphName] == nil {
                issues.append(
                    .init(
                        severity: .error,
                        code: "missing_subgraph",
                        message: "RunGraphNode references missing subgraph '\(runGraphNode.graphName.rawValue)'.",
                        node: node.name.rawValue
                    )
                )
            }
        }

        return issues
    }

    private func missingNodeIssue(_ node: RenderNodeLabel, edge _: Edge) -> RenderGraphIssue {
        RenderGraphIssue(
            severity: .error,
            code: "missing_edge_node",
            message: "Edge references missing node '\(node.rawValue)'.",
            node: node.rawValue
        )
    }

    private func invalidSlotIssue(node: RenderNodeLabel, slotIndex: Int, edge _: Edge) -> RenderGraphIssue {
        RenderGraphIssue(
            severity: .error,
            code: "invalid_slot_index",
            message: "Edge references missing slot index \(slotIndex).",
            node: node.rawValue
        )
    }

    private func edgeSortKey(_ edge: Edge) -> String {
        switch edge {
        case let .slot(outputNode, _, inputNode, _):
            return "\(outputNode.rawValue)->\(inputNode.rawValue)->slot"
        case let .node(outputNode, inputNode):
            return "\(outputNode.rawValue)->\(inputNode.rawValue)->node"
        }
    }
}

extension RenderGraphSlotSnapshot {
    init(slot: RenderSlot) {
        self.name = slot.name.rawValue
        self.kind = slot.kind.rawValue
    }
}

extension Array {
    subscript(validated index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
