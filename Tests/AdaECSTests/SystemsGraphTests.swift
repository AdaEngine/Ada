//
//  SystemsGraphTests.swift
//  AdaEngine
//

@testable import AdaECS
import Testing

@Suite("Systems graph identity")
struct SystemsGraphTests {
    @Test("Default identifiers retain the qualified type name across worlds")
    func defaultIdentifierMatchesTypeDependencies() {
        let expected = String(reflecting: DependentIdentifierSystem.self)
        for _ in 0..<10 {
            let system = DependentIdentifierSystem(world: World())
            #expect(system.systemIdentifier == expected)
            #expect(system.systemIdentifier == DependentIdentifierSystem.swiftName)
        }
    }

    @Test("Type dependencies resolve custom system identifiers")
    func typeDependenciesResolveCustomIdentifiers() {
        var graph = SystemsGraph()
        graph.addSystem(CustomIdentifierSystem(identifier: "custom.first"))
        graph.addSystem(CustomIdentifierSystem(identifier: "custom.second"))
        graph.addSystem(DependentIdentifierSystem(world: World()))

        graph.linkSystems()

        let dependentName = DependentIdentifierSystem.swiftName
        #expect(graph.getOuputNodes(for: "custom.first").map(\.name) == [dependentName])
        #expect(graph.getOuputNodes(for: "custom.second").map(\.name) == [dependentName])
        #expect(Set(graph.getInputNodes(for: dependentName).map(\.name)) == ["custom.first", "custom.second"])
    }

    @Test("Type removal removes all custom-identified instances")
    func typeRemovalRemovesCustomIdentifiedInstances() {
        var graph = SystemsGraph()
        graph.addSystem(CustomIdentifierSystem(identifier: "custom.first"))
        graph.addSystem(CustomIdentifierSystem(identifier: "custom.second"))

        graph.removeSystem(CustomIdentifierSystem.self)

        #expect(graph.nodes.isEmpty)
    }

    @Test("Instance dependencies support dynamically identified systems")
    func instanceDependenciesSupportDynamicSystems() {
        var graph = SystemsGraph()
        graph.addSystem(CustomIdentifierSystem(identifier: "dynamic.first"))
        graph.addSystem(DynamicDependentSystem(identifier: "dynamic.second", after: "dynamic.first"))

        graph.linkSystems()

        #expect(graph.getOuputNodes(for: "dynamic.first").map(\.name) == ["dynamic.second"])
        #expect(graph.getInputNodes(for: "dynamic.second").map(\.name) == ["dynamic.first"])
    }

    @Test("Equivalent dependency declarations create one edge")
    func equivalentDependenciesCreateOneEdge() {
        var graph = SystemsGraph()
        graph.addSystem(
            DynamicDependencySystem(
                dependencies: [.before("dynamic.second")],
                identifier: "dynamic.first"
            )
        )
        graph.addSystem(
            DynamicDependencySystem(
                dependencies: [.after("dynamic.first")],
                identifier: "dynamic.second"
            )
        )

        graph.linkSystems()

        #expect(graph.getOuputNodes(for: "dynamic.first").map(\.name) == ["dynamic.second"])
        #expect(graph.getInputNodes(for: "dynamic.second").map(\.name) == ["dynamic.first"])
    }
}

private struct CustomIdentifierSystem: System {
    let systemIdentifier: String

    init(identifier: String) {
        self.systemIdentifier = identifier
    }

    init(world: World) {
        self.systemIdentifier = "custom.default"
    }

    func update(context: UpdateContext) async {}
}

private struct DependentIdentifierSystem: System {
    static let dependencies: [SystemDependency] = [
        .after(CustomIdentifierSystem.self)
    ]

    init(world: World) {}

    func update(context: UpdateContext) async {}
}

private struct DynamicDependentSystem: System {
    let systemDependencies: [SystemDependency]
    let systemIdentifier: String

    init(identifier: String, after dependency: String) {
        self.systemDependencies = [.after(dependency)]
        self.systemIdentifier = identifier
    }

    init(world: World) {
        self.systemDependencies = []
        self.systemIdentifier = "dynamic.default"
    }

    func update(context: UpdateContext) async {}
}

private struct DynamicDependencySystem: System {
    let systemDependencies: [SystemDependency]
    let systemIdentifier: String

    init(dependencies: [SystemDependency], identifier: String) {
        self.systemDependencies = dependencies
        self.systemIdentifier = identifier
    }

    init(world: World) {
        self.systemDependencies = []
        self.systemIdentifier = "dynamic.default"
    }

    func update(context: UpdateContext) async {}
}
