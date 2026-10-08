import AdaApp
@testable import AdaECS
@_spi(Internal) import AdaInput
import AdaScripting
import Testing

@MainActor
@Suite("AdaScript Input resource", .serialized)
struct InputResourceBindingTests {
    @Test func declaresOnlyRequestedReadAccess() throws {
        let plugin = try AdaScriptPlugin(source: """
        @system(id: "with-input")
        class WithInput {
            @res var input: Input;
            func update(context) {}
        }
        @system(id: "without-input")
        class WithoutInput {
            func update(context) {}
        }
        """, name: "InputAccess")
        let world = World()
        plugin.setup(in: AppWorlds(main: world))
        #expect(plugin.diagnostics.isEmpty)
        let scheduler = try #require(world.schedulers.getScheduler(.update))
        let withInput = try #require(scheduler.systemGraph.nodes.first { $0.name.hasSuffix("with-input") })
        let withoutInput = try #require(scheduler.systemGraph.nodes.first { $0.name.hasSuffix("without-input") })
        var expected = SystemAccessSet()
        expected.addResourceRead(DeltaTime.self)
        #expect(withoutInput.queries.access == expected)
        expected.addResourceRead(Input.self)
        #expect(withInput.queries.access == expected)
        #expect(withInput.queries.access.isCompatible(with: expected))
        var writer = SystemAccessSet()
        writer.addResourceWrite(Input.self)
        #expect(!withInput.queries.access.isCompatible(with: writer))
        #expect(withoutInput.queries.access.isCompatible(with: writer))
    }

    @Test func missingRequiredInputReportsDiagnosticAndOptionalInputIsUnavailable() async throws {
        InputResourceProbe.registerComponent()
        let plugin = try AdaScriptPlugin(source: """
        @system(id: "missing-input")
        class MissingInput {
            @res var required: Input;
            @res(optional: true) var optional: Input;
            @query(InputResourceProbe) var probes;
            func update(context) {
                for (var row in probes) {
                    if (!optional.available() && !required.available()) {
                        row.inputResourceProbe.value += 1;
                    }
                    row.inputResourceProbe.value += optional.getActionStrength("Jump");
                }
            }
        }
        """, name: "MissingInput")
        let world = World()
        let entity = world.spawn { InputResourceProbe(value: 0) }
        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)
        #expect(plugin.diagnostics == ["Required resource 'Input' is not available"])
        #expect(world.get(InputResourceProbe.self, from: entity.id)?.value == 1)
    }

    @Test func refreshesEveryCallbackExpiresRetainedInputAndKeepsWorldsIsolated() async throws {
        InputResourceProbe.registerComponent()
        let plugin = try AdaScriptPlugin(source: """
        @system(id: "input-reader")
        class InputReader {
            @res var input: Input;
            @query(InputResourceProbe) var probes;
            var previous;
            func update(context) {
                for (var row in probes) {
                    if (previous != null && previous.available()) { row.inputResourceProbe.value += 1000; }
                    if (input.isActionJustPressed("Jump")) { row.inputResourceProbe.value += 10; }
                    if (input.isActionJustReleased("Jump")) { row.inputResourceProbe.value += 100; }
                    row.inputResourceProbe.value += input.getActionStrength("Jump");
                }
                previous = input;
            }
        }
        """, name: "InputReader")
        let world = World()
        let app = AppWorlds(main: world)
        InputPlugin(actions: [InputAction(name: "Jump", bindings: [.key(.space)])]).setup(in: app)
        plugin.setup(in: app)
        let entity = world.spawn { InputResourceProbe(value: 0) }
        for status in [KeyEvent.Status.down, nil, .up, nil] {
            if let status {
                world.getRefResource(Input.self).wrappedValue.receiveEvent(KeyEvent(
                    window: .empty, keyCode: .space, modifiers: [], status: status, time: 0, isRepeated: false
                ))
            }
            await world.runScheduler(.preUpdate)
            await world.runScheduler(.update)
            await world.runScheduler(.postUpdate)
        }
        #expect(world.get(InputResourceProbe.self, from: entity.id)?.value == 112)

        let other = World()
        let otherApp = AppWorlds(main: other)
        InputPlugin(actions: []).setup(in: otherApp)
        plugin.setup(in: otherApp)
        let otherEntity = other.spawn { InputResourceProbe(value: 0) }
        await other.runScheduler(.update)
        #expect(other.get(InputResourceProbe.self, from: otherEntity.id)?.value == 0)
        #expect(plugin.diagnostics.isEmpty)
    }
}

@Component
private struct InputResourceProbe {
    var value: Double
}
