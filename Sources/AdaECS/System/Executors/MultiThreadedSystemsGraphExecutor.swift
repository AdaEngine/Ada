//
//  MultiThreadedSystemsGraphExecutor.swift
//  AdaEngine
//

import AdaUtils
import DequeModule
import Tracing

/// Executes dependency-ready, non-conflicting systems concurrently.
///
/// The executor follows core scheduling rule: systems may run together
/// when their declared accesses are compatible. Any system that records
/// deferred commands causes a world flush after its current batch completes.
public struct MultiThreadedSystemsGraphExecutor: SystemsGraphExecutor {
    private struct NodeMetadata: Sendable {
        var dependencies: Set<String>
        var access: SystemAccessSet
    }

    private var nodeOrder: [String] = []
    private var metadataByNode: [String: NodeMetadata] = [:]

    /// Initialize a new multi-threaded systems graph executor.
    public init() {}

    public mutating func initialize(_ graph: borrowing SystemsGraph) {
        nodeOrder = makeSingleThreadedNodeOrder(from: graph)
        metadataByNode = Dictionary(
            uniqueKeysWithValues: graph.nodes.map { node in
                let dependencies = Set(graph.getInputNodes(for: node.name).map(\.name))
                return (
                    node.name,
                    NodeMetadata(
                        dependencies: dependencies,
                        access: node.queries.access
                    )
                )
            }
        )
    }

    public mutating func execute(
        _ graph: borrowing SystemsGraph,
        world: World,
        scheduler: SchedulerName
    ) async {
        if nodeOrder.isEmpty && !graph.nodes.isEmpty {
            initialize(graph)
        }

        var completedSystems: Set<String> = []

        while completedSystems.count < nodeOrder.count {
            let batch = makeReadyBatch(
                from: graph,
                completedSystems: completedSystems
            )

            if batch.isEmpty {
                assertionFailure("[SystemsGraph] Unable to find ready systems. Check dependency cycles.")
                return
            }

            for node in batch {
                node.queries.update(from: world)
            }

            await withTaskGroup(of: Void.self) { group in
                for node in batch {
                    group.addTask {
                        await executeSystem(
                            system: node,
                            world: world,
                            scheduler: scheduler
                        )
                    }
                }
            }

            var shouldFlushDeferredCommands = false
            for node in batch {
                await node.queries.finish(world)
                completedSystems.insert(node.name)
                shouldFlushDeferredCommands =
                    shouldFlushDeferredCommands
                    || (metadataByNode[node.name]?.access.hasDeferredWorldAccess == true)
            }

            if shouldFlushDeferredCommands {
                world.flush()
            }
        }

        world.flush()
    }

    private func makeReadyBatch(
        from graph: borrowing SystemsGraph,
        completedSystems: Set<String>
    ) -> [SystemsGraph.Node] {
        var batch: [SystemsGraph.Node] = []
        var batchAccess: [SystemAccessSet] = []

        for nodeName in nodeOrder where !completedSystems.contains(nodeName) {
            guard
                let metadata = metadataByNode[nodeName],
                metadata.dependencies.isSubset(of: completedSystems),
                batchAccess.allSatisfy({ $0.isCompatible(with: metadata.access) }),
                let node = graph.nodes[nodeName]
            else {
                continue
            }

            batch.append(node)
            batchAccess.append(metadata.access)
        }

        return batch
    }

    private func makeSingleThreadedNodeOrder(from graph: borrowing SystemsGraph) -> [String] {
        var completedSystems: Set<String> = []
        var nodes = Deque(graph.nodes.filter(\.inputEdges.isEmpty))
        var order: [String] = []

        nextNode: while let currentNode = nodes.popLast() {
            if completedSystems.contains(currentNode.name) {
                continue
            }

            for inputNode in graph.getInputNodes(for: currentNode.name)
                where !completedSystems.contains(inputNode.name) {
                nodes.prepend(currentNode)
                continue nextNode
            }

            completedSystems.insert(currentNode.name)
            order.append(currentNode.name)

            for outputNode in graph.getOuputNodes(for: currentNode.name) {
                nodes.prepend(outputNode)
            }
        }

        return order
    }
}

@concurrent
private func executeSystem(
    system: SystemsGraph.Node,
    world: World,
    scheduler: SchedulerName
) async {
    await AdaTrace.span(
        lazyName: "System.execute.\(system.name)",
        attributes: [
            "ada.profile.category": "system",
            "ada.scheduler.name": .string(scheduler.rawValue),
            "ada.system.name": .string(system.name),
            "ada.world.name": .string(world.name ?? "UnknownWorld"),
        ]
    ) {
        await system.system.update(
            context: WorldUpdateContext(
                world: world,
                scheduler: scheduler
            )
        )
    }
}
