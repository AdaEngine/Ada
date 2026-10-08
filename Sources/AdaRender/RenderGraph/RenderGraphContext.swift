//
//  RenderGraphContext.swift
//  AdaEngine
//
//  Created by v.prusakov on 2/19/23.
//

import AdaECS
import Logging

struct PendingSubGraph: Sendable {
    let graph: RenderGraph
    let inputs: [RenderSlotValue]
    let viewEntity: Entity?
}

/// The context with all graph information required to run a ``RenderNode``.
/// This context is created for each node by the ``RenderGraphExecutor``.
public struct RenderGraphContext: ~Copyable, Sendable {
    public let graph: RenderGraph
    public let world: World
    public internal(set) var inputResources: [RenderSlotValue]
    public let tracer: Logger
    public let viewEntity: Entity?

    init(
        graph: RenderGraph,
        world: World,
        inputResources: [RenderSlotValue],
        tracer: Logger,
        viewEntity: Entity?
    ) {
        self.graph = graph
        self.world = world
        self.tracer = tracer
        self.inputResources = inputResources
        self.viewEntity = viewEntity
    }

    internal var pendingSubgraphs: [PendingSubGraph] = []
}

extension RenderGraphContext {
    public mutating func runSubgraph(
        _ name: RenderGraph.Label,
        inputs: [RenderSlotValue],
        viewEntity: Entity? = nil
    ) {
        guard let graph = self.graph.subGraphs[name] else {
            return
        }

        if let inputResources = graph.entryNode?.node.inputResources {
            for (index, inputResource) in inputResources.enumerated()
                where inputs[index].value.resourceKind != inputResource.kind {
                return
            }
        }

        self.pendingSubgraphs.append(PendingSubGraph(graph: graph, inputs: inputs, viewEntity: viewEntity))
    }

    public func entityResource(by name: RenderSlot.Label) -> Entity? {
        self.inputResources.first(where: { $0.name == name })?.value.entity
    }

    public func textureResource(by name: RenderSlot.Label) -> Texture? {
        self.inputResources.first(where: { $0.name == name })?.value.texture
    }

    public func bufferResource(by name: RenderSlot.Label) -> Buffer? {
        self.inputResources.first(where: { $0.name == name })?.value.buffer
    }

    public func samplerResource(by name: RenderSlot.Label) -> Sampler? {
        self.inputResources.first(where: { $0.name == name })?.value.sampler
    }
}

/// A global actor that is used to run render graph nodes.
@globalActor
public actor RenderGraphActor: GlobalActor {
    public static let shared = RenderGraphActor()
}
