import AdaECS
import Foundation
import Math
import Testing

@Suite("Generated runtime component constructors", .serialized)
struct RuntimeComponentConstructorTests {
    @Test("Macro applies positional values directly to the concrete component")
    func appliesGeneratedArguments() throws {
        let descriptor = RuntimeConstructedProbe.runtimeComponentConstructor

        #expect(descriptor.parameters.map(\.name) == ["position", "count"])
        let component = try descriptor.apply(
            to: RuntimeConstructedProbe(),
            arguments: [
                .array([.double(4), .double(5), .double(6)]),
                .int(7),
            ]
        )
        let typed = try #require(component as? RuntimeConstructedProbe)
        #expect(typed.position == Vector3(4, 5, 6))
        #expect(typed.count == 7)
        #expect(typed.readOnlyToken == "stable")
    }

    @MainActor
    @Test("Runtime aliases expose the same generated constructor schema")
    func registersAliasCatalog() throws {
        RuntimeTypeRegistry.registerComponent(
            RuntimeConstructedProbe.self,
            names: ["RuntimeConstructedProbe"],
            makeDefault: { RuntimeConstructedProbe() }
        )

        let constructor = try #require(
            RuntimeTypeRegistry.registeredRuntimeComponentConstructors()
                .first { $0.name == "RuntimeConstructedProbe" }
        )
        #expect(constructor.parameters.map(\.name) == ["position", "count"])
        let component = try constructor.construct(arguments: [nil, .int(11)])
        #expect((component as? RuntimeConstructedProbe)?.count == 11)
    }

    @Test("Marked constructors preserve Swift initializer invariants")
    func callsMarkedInitializerDirectly() throws {
        let descriptor = RuntimeInvariantProbe.runtimeComponentConstructor

        #expect(descriptor.parameters.map(\.name) == ["rawValue"])
        let component = try descriptor.apply(
            to: RuntimeInvariantProbe(rawValue: 100),
            arguments: [.int(-7)]
        )
        let typed = try #require(component as? RuntimeInvariantProbe)
        #expect(typed.normalizedValue == 0)
    }

    @Test("Marked constructors skip the registered default factory")
    func skipsDefaultFactoryForMarkedInitializer() throws {
        let counter = RuntimeConstructorFactoryCounter()
        let constructor = RegisteredRuntimeComponentConstructor(
            name: "RuntimeInvariantProbe",
            descriptor: RuntimeInvariantProbe.runtimeComponentConstructor,
            makeDefault: {
                counter.increment()
                return RuntimeInvariantProbe(rawValue: 100)
            }
        )

        let component = try constructor.construct(arguments: [.int(4)])
        #expect((component as? RuntimeInvariantProbe)?.normalizedValue == 4)
        #expect(counter.value == 0)
    }

    @MainActor
    @Test("Marked constructors register without a default factory")
    func registersMarkedInitializerWithoutDefaultFactory() throws {
        RuntimeTypeRegistry.registerComponent(
            RuntimeInvariantProbe.self,
            names: ["RuntimeInvariantWithoutDefault"]
        )

        let constructor = try #require(
            RuntimeTypeRegistry.registeredRuntimeComponentConstructors()
                .first { $0.name == "RuntimeInvariantWithoutDefault" }
        )
        let component = try constructor.construct(arguments: [.int(-3)])
        #expect((component as? RuntimeInvariantProbe)?.normalizedValue == 0)
    }
}

@Component
private struct RuntimeConstructedProbe {
    var position: Vector3 = .zero
    var count: Int = 0
    let readOnlyToken = "stable"
}

@Component
private struct RuntimeInvariantProbe {
    var normalizedValue: Int

    @AdaScriptInit
    init(rawValue: Int = 0) {
        self.normalizedValue = max(0, rawValue)
    }
}

private final class RuntimeConstructorFactoryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}
