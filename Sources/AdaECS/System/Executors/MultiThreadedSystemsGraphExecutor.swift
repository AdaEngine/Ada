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
    /// Systems that may run together, resolved once per graph change.
    private struct Batch: Sendable {
        var nodeNames: [String]
        /// True when any system in the batch records deferred world access.
        var flushesDeferredCommands: Bool
    }

    private var plan: [Batch] = []
    /// True when no further system was ready although some were left (dependency cycle).
    private var isStalled = false
    private var isPlanned = false

    /// Initialize a new multi-threaded systems graph executor.
    public init() {}

    public mutating func initialize(_ graph: borrowing SystemsGraph) {
        let nodeOrder = makeSingleThreadedNodeOrder(from: graph)
        var dependencies: [String: Set<String>] = [:]
        var accesses: [String: SystemAccessSet] = [:]
        for node in graph.nodes {
            dependencies[node.name] = Set(graph.getInputNodes(for: node.name).map(\.name))
            accesses[node.name] = node.queries.access
        }

        // Same greedy batching the executor used to redo every frame: it depends only on the graph.
        var completedSystems: Set<String> = []
        var batches: [Batch] = []
        var stalled = false
        while completedSystems.count < nodeOrder.count {
            var names: [String] = []
            var batchAccess: [SystemAccessSet] = []
            var flushes = false

            for nodeName in nodeOrder where !completedSystems.contains(nodeName) {
                guard
                    let nodeDependencies = dependencies[nodeName],
                    let access = accesses[nodeName],
                    nodeDependencies.isSubset(of: completedSystems),
                    batchAccess.allSatisfy({ $0.isCompatible(with: access) })
                else {
                    continue
                }
                names.append(nodeName)
                batchAccess.append(access)
                flushes = flushes || access.hasDeferredWorldAccess
            }

            if names.isEmpty {
                stalled = true
                break
            }
            completedSystems.formUnion(names)
            batches.append(Batch(nodeNames: names, flushesDeferredCommands: flushes))
        }

        plan = batches
        isStalled = stalled
        isPlanned = true
    }

    public mutating func execute(
        _ graph: borrowing SystemsGraph,
        world: World,
        scheduler: SchedulerName
    ) async {
        if !isPlanned && !graph.nodes.isEmpty {
            initialize(graph)
        }

        for batch in plan {
            var nodes: [SystemsGraph.Node] = []
            nodes.reserveCapacity(batch.nodeNames.count)
            for name in batch.nodeNames {
                if let node = graph.nodes[name] {
                    nodes.append(node)
                }
            }

            for node in nodes {
                node.queries.update(from: world)
            }

            if nodes.count == 1, let node = nodes.first {
                // A singleton has no parallel work. Avoid a child task and its
                // executor hops for the common dependency-constrained case.
                await executeSystemInline(system: node, world: world, scheduler: scheduler)
            } else {
                await withTaskGroup(of: Void.self) { group in
                    for node in nodes {
                        group.addTask {
                            await executeSystem(system: node, world: world, scheduler: scheduler)
                        }
                    }
                }
            }

            for node in nodes {
                await node.queries.finish(world)
            }

            if batch.flushesDeferredCommands {
                world.flush()
            }
        }

        if isStalled {
            assertionFailure("[SystemsGraph] Unable to find ready systems. Check dependency cycles.")
            return
        }

        world.flush()
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
    await executeSystemInline(system: system, world: world, scheduler: scheduler)
}

private func executeSystemInline(
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
