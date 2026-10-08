//
//  SystemsGraph.swift
//  AdaEngine
//
//  Created by v.prusakov on 2/23/23.
//

import AdaUtils
import OrderedCollections

/// Contains information about execution order of systems.
public struct SystemsGraph: Sendable {
    /// Indicates that graph is changed and needs recalculate deps
    private(set) var isChanged: Bool = false

    /// The edge of the systems graph.
    struct Edge: Equatable {
        /// The output node of the edge.
        let outputNode: String

        /// The input node of the edge.
        let inputNode: String
    }

    /// The node of the systems graph.
    struct Node: Sendable {
        /// The unique identifier of the node.
        typealias ID = String

        /// The name of the node.
        let name: String

        /// The Swift type identity used by type-based graph operations.
        let typeName: String

        /// The system of the node.
        var system: System

        /// The dependencies of the node.
        var dependencies: [SystemDependency]

        /// The queries
        var queries: SystemQueries

        /// The input edges of the node.
        var inputEdges: [Edge] = []

        /// The output edges of the node.
        var outputEdges: [Edge] = []
    }

    /// The nodes of the graph.
    private(set) var nodes: SparseSet<String, Node> = [:]

    /// Initialize a new systems graph.
    public init() {}

    // MARK: - Internal methods

    /// Add a node of the current system. If a node exists with the same type, it will be overridden.
    /// - Note: Systems will be added with nodes without edges.
    /// - Parameter system: The system to add.
    mutating func addSystem<T: System>(_ system: T) {
        let node = Node(
            name: system.systemIdentifier,
            typeName: T.swiftName,
            system: system,
            dependencies: system.systemDependencies,
            queries: system.queries
        )
        self.nodes[node.name] = node
        self.isChanged = true
    }

    /// Remove a system from the graph.
    ///
    /// - Parameter system: The system to remove.
    mutating func removeSystem<T: System>(_: T.Type) {
        let nodeNames = self.nodeNames(matching: T.swiftName)
        for nodeName in nodeNames {
            self.nodes.remove(for: nodeName)
        }
        self.isChanged = true
    }

    /// Create an execution order for all systems.
    /// - Complexity: O(n^2)
    mutating func linkSystems() {
        #if DEBUG
            if !EnvironmentValues.current.ecs.useSystemDependencies {
                return
            }
        #endif
        for node in nodes {
            let systemName = node.name
            for dependency in node.dependencies {
                switch dependency {
                case let .after(system):
                    for dependencyName in nodeNames(matching: system) {
                        self.tryAddEdge(from: dependencyName, to: systemName)
                    }
                case let .before(system):
                    for dependencyName in nodeNames(matching: system) {
                        self.tryAddEdge(from: systemName, to: dependencyName)
                    }
                }
            }
        }
        self.isChanged = false
    }

    /// Get the output nodes for a given node.
    /// - Parameter nodeId: The ID of the node.
    /// - Returns: The output nodes for the given node.
    /// - Complexity: O(n)
    func getOuputNodes(for nodeId: Node.ID) -> [Node] {
        guard let node = self.nodes[nodeId] else {
            return []
        }

        return node.outputEdges.compactMap { edge in
            guard let node = self.nodes[edge.inputNode] else {
                return nil
            }
            return node
        }
    }

    /// Get the input nodes for a given node.
    /// - Parameter nodeId: The ID of the node.
    /// - Returns: The input nodes for the given node.
    /// - Complexity: O(n)
    func getInputNodes(for nodeId: Node.ID) -> [Node] {
        guard let node = self.nodes[nodeId] else {
            return []
        }

        return node.inputEdges.compactMap { edge in
            guard let node = self.nodes[edge.outputNode] else {
                return nil
            }

            return node
        }
    }

    // MARK: - Private methods

    /// Resolve either a Swift system type name or an instance identifier.
    private func nodeNames(matching identifier: String) -> [Node.ID] {
        let typeMatches = nodes.compactMap { node in
            node.typeName == identifier ? node.name : nil
        }
        if !typeMatches.isEmpty {
            return typeMatches
        }
        return [identifier]
    }

    /// Try to add an edge. If a dependency is cycled, it will be skipped with an error.
    /// - Parameter outputSystemName: The name of the output system.
    /// - Parameter inputSystemName: The name of the input system.
    private mutating func tryAddEdge(from outputSystemName: String, to inputSystemName: String) {
        var outputNode = self.nodes[outputSystemName]
        var inputNode = self.nodes[inputSystemName]

        assert(outputNode != nil, "[SystemsGraph] System not exists \(outputSystemName) to \(inputSystemName)")
        assert(inputNode != nil, "[SystemsGraph] System not exists \(inputSystemName) for \(outputSystemName)")

        let edge = Edge(outputNode: outputSystemName, inputNode: inputSystemName)
        let reversedEdge = Edge(outputNode: inputSystemName, inputNode: outputSystemName)

        if self.hasEdge(edge) {
            return
        }
        guard !self.hasEdge(reversedEdge) else {
            assertionFailure("[SystemsGraph] Detected a cycle betweens \"\(outputSystemName)\" and \"\(inputSystemName)\"")
            return
        }

        outputNode?.outputEdges.append(edge)
        inputNode?.inputEdges.append(edge)

        self.nodes[inputSystemName] = inputNode
        self.nodes[outputSystemName] = outputNode
    }

    /// Check if an edge exists.
    /// - Parameter edge: The edge to check.
    /// - Returns: True if the edge exists, otherwise false.
    private func hasEdge(_ edge: Edge) -> Bool {
        guard
            let inputNode = self.nodes[edge.inputNode],
            let outputNode = self.nodes[edge.outputNode]
        else {
            return false
        }

        return inputNode.inputEdges.contains(edge) && outputNode.outputEdges.contains(edge)
    }
}

extension SystemsGraph {
    /// The visualize description of the systems graph.
    public var visualizeDescription: String {
        var string = ""
        for node in nodes {
            for outputNode in getOuputNodes(for: node.name) {
                string += "\(node.name) --> \(outputNode.name)\n"
            }
        }
        return string
    }
}

extension SystemsGraph: CustomDebugStringConvertible {
    /// The debug description of the systems graph.
    public var debugDescription: String {
        var string = ""
        for node in nodes {
            string += "\(node.name)\n"

            string += " in: \n"
            for inputNode in getInputNodes(for: node.name) {
                string += "  \(node.name) --> \(inputNode.name)\n"
            }

            string += " out: \n"
            for ouputNode in getOuputNodes(for: node.name) {
                string += "  \(node.name) --> \(ouputNode.name)\n"
            }
        }

        return string
    }
}
