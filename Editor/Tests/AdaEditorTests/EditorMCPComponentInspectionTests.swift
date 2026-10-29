import AdaEngine
import AdaMCPCore
import Foundation
import MCP
import Testing

@MainActor
@Suite("MCP component inspection")
struct EditorMCPComponentInspectionTests {
    private final class OpaqueReference: Sendable, CustomStringConvertible {
        let hidden = 42
        var description: String { "This description must not be inspected" }
    }

    private struct Unregistered: Component {
        var enabled = true
        var values = Array(0..<200)
        var absent: Int?
        var reference = OpaqueReference()
    }

    @Test("Runtime schemas preserve distinct names, fields, aliases and world ownership")
    func runtimeSchemas() async throws {
        let world = World(name: "Inspection")
        let health = RuntimeComponentDescriptor(
            stableID: "game.Health", name: "Health", aliases: ["OldHealth"],
            fieldNames: ["hp", "position"], fieldKinds: [.int, .vector3],
            defaultValues: [.int(42), .array([.double(1), .double(2), .double(3)])]
        )
        let score = RuntimeComponentDescriptor(stableID: "game.Score", name: "Score", fieldNames: ["points"], defaultValues: [.int(7)])
        world.registerRuntimeComponent(health)
        world.registerRuntimeComponent(score)
        let player = world.spawn("Player") { health.makeDefault(); score.makeDefault() }
        let runtime = makeRuntime(world)
        let listing = try await payload(runtime, "entity.list_components", ["entityId": .int(player.id)])
        let components = try #require(listing["components"]?.arrayValue)
        #expect(listing["diagnostics"]?.arrayValue?.isEmpty == true)
        #expect(components.contains { $0.objectValue?["type"]?.stringValue == "game.Score" })
        for name in ["game.Health", "Health", "OldHealth"] {
            let result = try await payload(runtime, "component.get", ["entityId": .int(player.id), "componentType": .string(name)])
            #expect(result["type"]?.stringValue == "game.Health")
            #expect(result["fields"]?.objectValue?["hp"]?.intValue == 42)
            #expect(result["fields"]?.objectValue?["position"]?.arrayValue?.count == 3)
            let found = try await payload(runtime, "entity.find", ["componentType": .string(name)])
            #expect(found["entities"]?.arrayValue?.count == 1)
        }
        let other = World(name: "Other")
        let otherHealth = RuntimeComponentDescriptor(stableID: "game.Health", name: "Health", fieldNames: ["mana"], defaultValues: [.int(99)])
        other.registerRuntimeComponent(otherHealth)
        let otherPlayer = other.spawn("Other player") { otherHealth.makeDefault() }
        let result = try await payload(makeRuntime(other), "component.get", ["entityId": .int(otherPlayer.id), "componentType": .string("Health")])
        #expect(result["fields"]?.objectValue?["mana"]?.intValue == 99)
        #expect(result["fields"]?.objectValue?["hp"] == nil)
    }

    @Test("Unregistered native components expose live state and bounded partial values")
    func nativeComponents() async throws {
        let world = World(name: "Inspection")
        let player = world.spawn("Player") {
            MouseCaptureComponent(isRequested: true)
            CharacterController3DComponent()
            Unregistered()
        }
        let runtime = makeRuntime(world)
        let mouse = try await payload(runtime, "component.get", ["entityId": .int(player.id), "componentType": .string(String(reflecting: MouseCaptureComponent.self))])
        #expect(mouse["fields"]?.objectValue?["isRequested"]?.boolValue == true)
        #expect(mouse["fields"]?.objectValue?["isCaptured"]?.boolValue == false)
        let controller = try await payload(runtime, "component.get", ["entityId": .int(player.id), "componentType": .string(String(reflecting: CharacterController3DComponent.self))])
        #expect(controller["fields"]?.objectValue?["heightChangeBlocked"]?.boolValue == false)
        #expect(controller["fields"]?.objectValue?["desiredVelocity"] != nil)
        let fallback = try await payload(runtime, "component.get", ["entityId": .int(player.id), "componentType": .string(String(reflecting: Unregistered.self))])
        #expect(fallback["readOnly"]?.boolValue == true)
        #expect(fallback["fields"]?.objectValue?["enabled"]?.boolValue == true)
        #expect(fallback["fields"]?.objectValue?["absent"] == .null)
        #expect(fallback["fields"]?.objectValue?["reference"]?.objectValue?["$unavailable"]?.stringValue == "reference")
        #expect(fallback["fields"]?.objectValue?["values"]?.objectValue?["items"]?.arrayValue?.count == 128)
        #expect(fallback["diagnostics"]?.arrayValue?.first?.objectValue?["code"]?.stringValue == "partial_inspection")
        let listing = try await payload(runtime, "entity.list_components", ["entityId": .int(player.id)])
        #expect(listing["diagnostics"]?.arrayValue?.isEmpty == true)
        #expect(listing["components"]?.arrayValue?.count == world.getComponents(for: player.id).count)
    }

    @Test("Explicit serializer failures remain visible")
    func serializerFailure() async throws {
        let world = World(name: "Inspection")
        let player = world.spawn("Player") { Unregistered() }
        let registry = MCPIntrospectionRegistry()
        registry.register(Unregistered.self, descriptor: .init(name: "Broken", kind: .component)) { _ in
            throw AdaMCPError.invalidArguments("Serializer failed")
        }
        let result = try await payload(makeRuntime(world, registry: registry), "entity.list_components", ["entityId": .int(player.id)])
        #expect(result["diagnostics"]?.arrayValue?.first?.objectValue?["code"]?.stringValue == "inspection_failed")
    }

    private func makeRuntime(_ world: World, registry: MCPIntrospectionRegistry = .init()) -> AdaMCPRuntime {
        let app = AppWorlds(main: world)
        return AdaMCPRuntime(appWorlds: app, registry: registry, renderCaptureService: RenderCaptureService(appWorlds: app))
    }

    private func payload(_ runtime: AdaMCPRuntime, _ name: String, _ arguments: [String: Value]) async throws -> [String: Value] {
        let result = await runtime.callTool(name: name, arguments: arguments)
        #expect(result.isError != true)
        let content = try #require(result.content.first)
        guard case let .text(text, _, _) = content else { throw AdaMCPError.invalidArguments("Expected JSON text") }
        return try #require(JSONDecoder().decode(Value.self, from: Data(text.utf8)).objectValue)
    }
}
