import AdaECS
import Testing

@Suite("Generated Ada Script data registration", .serialized)
struct GeneratedDataRegistrationTests {
    @Test("Registers component and resource aliases")
    @MainActor
    func registersStableAliases() {
        RuntimeTypeRegistry.registerComponent(
            GeneratedRegistrationComponent.self,
            names: ["GeneratedHealth", "game.generated-health"],
            makeDefault: { GeneratedRegistrationComponent() }
        )
        RuntimeTypeRegistry.registerResource(
            GeneratedRegistrationResource.self,
            names: ["GeneratedBalance", "game.generated-balance"]
        )

        #expect(RuntimeTypeRegistry.componentType(named: "GeneratedHealth").map(ObjectIdentifier.init) == ObjectIdentifier(GeneratedRegistrationComponent.self))
        #expect(RuntimeTypeRegistry.componentType(named: "game.generated-health").map(ObjectIdentifier.init) == ObjectIdentifier(GeneratedRegistrationComponent.self))
        #expect(RuntimeTypeRegistry.resourceType(named: "GeneratedBalance").map(ObjectIdentifier.init) == ObjectIdentifier(GeneratedRegistrationResource.self))
        #expect(RuntimeTypeRegistry.resourceType(named: "game.generated-balance").map(ObjectIdentifier.init) == ObjectIdentifier(GeneratedRegistrationResource.self))

        let world = World(name: "Generated component aliases")
        let entity = world.spawn()
        #expect(world.insertDefaultComponent(named: "game.generated-health", into: entity.id))
        #expect(world.get(GeneratedRegistrationComponent.self, from: entity.id)?.value == 1)
    }
}

@Component
private struct GeneratedRegistrationComponent {
    var value: Double = 1
}

private struct GeneratedRegistrationResource: Resource {
    var value: Double = 2
}
