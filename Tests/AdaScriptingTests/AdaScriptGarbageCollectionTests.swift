import AdaApp
import AdaECS
import AdaInput
import AdaScripting
import Testing

@MainActor
@Suite(.serialized)
struct AdaScriptGarbageCollectionTests {
    @Test("Nested calls collect abandoned values without clearing live arguments or captures")
    func reusedNestedRegisterWindows() throws {
        let seedLocals = (0..<24).map { "var local\($0) = [\($0)];" }.joined(separator: "\n")
        let consumeLocals = (0..<24).map { "var local\($0) = \($0);" }.joined(separator: "\n")
        let plugin = try AdaScriptPlugin(
            sources: [AdaScriptSource(path: "RegisterReuse.ada", source: """
            func seedRegisters(depth) {
                \(seedLocals)
                if (depth > 0) return seedRegisters(depth - 1);
                return local23[0];
            }
            func consume(keep, captured) {
                // Collect before locals overwrite registers reused from seedRegisters.
                System.gcThreshold = 1;
                \(consumeLocals)
                return keep[0] + captured() + local23;
            }
            @test func registerReuse() {
                var keep = [19];
                var capture = [7];
                var captured = func() { return capture[0]; };
                for (var iteration in 0..<100) {
                    // Recursion also grows the stack while capture's upvalue is open.
                    seedRegisters(12);
                    // The returned frame is no longer a root, so its lists can be reclaimed.
                    System.gcThreshold = 1;
                    expectEqual(consume(keep, captured), 49);
                    expectEqual(keep[0], 19);
                    expectEqual(captured(), 7);
                }
            }
            """)],
            name: "RegisterReuse",
            includeTests: true
        )
        let result = try #require(plugin.runTests().first)
        #expect(result.outcome == .passed, "\(result.diagnostics)")
    }

    @Test("Dynamically selected native constructors and getters preserve their locals")
    func dynamicNativeRegisterWindows() throws {
        let locals = (0..<24).map { "var local\($0) = \($0);" }.joined(separator: "\n")
        let plugin = try AdaScriptPlugin(
            sources: [AdaScriptSource(path: "DynamicRegisters.ada", source: """
            class RegisterBox {
                var result;
                func init(input) {
                    var retained = input;
                    \(locals)
                    result = retained[0] + local23;
                }
                var computed {
                    get {
                        var retained = [19];
                        \(locals)
                        return retained[0] + local23;
                    }
                }
            }
            @test func dynamicRegisters() {
                var box = RegisterBox([19]);
                expectEqual(box.result, 42);
                expectEqual(box.computed, 42);
            }
            """)],
            name: "DynamicRegisterReuse",
            includeTests: true
        )
        let result = try #require(plugin.runTests().first)
        #expect(result.outcome == .passed, "\(result.diagnostics)")
    }

    @Test("Repeated external callbacks collect discarded locals and retain stored values")
    func reusedOuterRegisterWindow() async throws {
        CollectionProbe.registerComponent()
        let locals = (0..<24).map { "var local\($0) = [\($0)];" }.joined(separator: "\n")
        let plugin = try AdaScriptPlugin(source: """
        @system class OuterCollectionSystem {
            @query(CollectionProbe) var probes;
            var retained = [19];
            func update(context) {
                System.gcThreshold = 1;
                \(locals)
                for (var row in probes) {
                    row.collectionProbe.value += retained[0] + local23[0];
                }
            }
        }
        """, name: "OuterRegisterReuse")
        let world = World()
        let app = AppWorlds(main: world)
        plugin.setup(in: app)
        defer { plugin.destroy(for: app) }
        let entity = world.spawn { CollectionProbe() }
        for _ in 0..<1_000 {
            await world.runScheduler(.update)
        }
        #expect(world.get(CollectionProbe.self, from: entity.id)?.value == 42_000)
        #expect(plugin.diagnostics.isEmpty, "\(plugin.diagnostics)")
    }

    @Test
    func callbackBindingsSurviveFrequentCollection() async throws {
        CollectionProbe.registerComponent()
        let plugin = try AdaScriptPlugin(source: """
        var tick = 0;
        @system(id: "collection-probe")
        class CollectionSystem {
            @query(CollectionProbe) var probes;
            @query(CollectionProbe) var otherProbes;
            @res var input: Input;
            func update(context) {
                tick += 1;
                // Vary allocation pressure so collections cross different binding boundaries.
                for (var index in 0..<(tick % 31)) { var temporary = [index, tick]; }
                for (var row in probes) {
                    row.collectionProbe.value += 1;
                    // Native System getters temporarily suspend collection themselves.
                    row.collectionProbe.collectorEnabled = System.gcEnabled >= 0;
                    row.collectionProbe.inputAvailable = input.available();
                }
                for (var row in otherProbes) { row.collectionProbe.value += 1; }
            }
        }
        """, name: "CollectionProbe")
        let world = World()
        let app = AppWorlds(main: world)
        InputPlugin(actions: []).setup(in: app)
        plugin.setup(in: app)
        let entity = world.spawn { CollectionProbe() }
        for _ in 0..<50_000 {
            await world.runScheduler(.update)
        }
        let result = try #require(world.get(CollectionProbe.self, from: entity.id))
        #expect(result.value == 100_000)
        #expect(result.collectorEnabled)
        #expect(result.inputAvailable)
        #expect(plugin.diagnostics.isEmpty)
    }
}

@Component
private struct CollectionProbe {
    var value: Int = 0
    var collectorEnabled: Bool = false
    var inputAvailable: Bool = false
}
