@testable import AdaApp
import AdaECS
import AdaScriptCompilerCore
import AdaScripting
import Testing

@Suite("AdaScript standard library", .serialized)
struct AdaScriptStandardLibraryTests {
    @Test("Math lowering leaves strings and comments intact")
    func mathLowering() {
        let source = """
        // Math.dot(left, right)
        var text = "Math.clamp(value, 0, 1)";
        var value = Math.clamp(2, 0, 1);
        var length = Math
            .length([3, 4]);
        """
        let lowered = AdaScriptMathLowerer.lower(source: source)
        #expect(lowered.contains("// Math.dot(left, right)"))
        #expect(lowered.contains("\"Math.clamp(value, 0, 1)\""))
        #expect(lowered.contains("__adaMathClamp(2, 0, 1)"))
        #expect(lowered.contains("__adaMathLength\n"))
        #expect(source.filter { $0 == "\n" }.count == lowered.filter { $0 == "\n" }.count)
    }

    @Test("Free System functions and Math helpers execute in a system")
    @MainActor
    func functionsExecute() async throws {
        let plugin = try AdaScriptPlugin(
            source: """
            @system(id: "standard.library")
            class StandardLibrarySystem {
                func update(context) {
                    print("AdaScript", " standard library");
                    put("");
                    assert(nanotime() > 0);
                    assert(Math.clamp(12, 0, 10) == 10);
                    assert(Math.clamp(-2, 0, 10) == 0);
                    assert(Math.saturate(1.5) == 1);

                    var x = [3.0, 4.0, 0.0];
                    var y = [0.0, 0.0, 1.0];
                    assert(Math.addVector(x, y)[2] == 1);
                    assert(Math.subtractVector(x, y)[2] == -1);
                    assert(Math.scaleVector(x, 2)[0] == 6);
                    assert(Math.dot(x, y) == 0);
                    assert(Math.length(x) == 5);
                    assert(Math.distance(x, [0.0, 0.0, 0.0]) == 5);
                    assert(Math.normalize(x)[0] == 0.6);
                    assert(Math.cross(x, y)[0] == 4);
                    assert(Math.lerpVector(x, [5.0, 6.0, 2.0], 0.5)[2] == 1);
                    assert(Math.clampVector(x, [0.0, 0.0, 0.0], [2.0, 5.0, 1.0])[0] == 2);

                    var identity = Math.identityMatrix(3);
                    assert(identity[0][0] == 1 && identity[0][1] == 0);
                    assert(Math.transformVector(identity, x)[1] == 4);
                    assert(Math.transposeMatrix([[1, 2, 3], [4, 5, 6]])[2][1] == 6);
                    var product = Math.multiplyMatrix([[1, 2], [3, 4]], [[5, 6], [7, 8]]);
                    assert(product[0][0] == 19 && product[1][1] == 50);

                    // These are available as free functions even when not called here.
                    if (false) { input(); exit(); }
                }
            }
            """,
            name: "StandardLibrary"
        )
        let world = World(name: "AdaScript standard library")
        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)
        #expect(plugin.diagnostics.isEmpty)
    }

    @Test("A failed assertion reports a VM diagnostic")
    @MainActor
    func assertionReportsDiagnostic() async throws {
        let plugin = try AdaScriptPlugin(
            source: """
            @system(id: "assertion.failure")
            class FailureSystem {
                func update(context) { assert(false, "expected failure"); }
            }
            """,
            name: "AssertionFailure"
        )
        let world = World(name: "Assertion failure")
        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)
        #expect(plugin.diagnostics.contains { $0.contains("expected failure") })
    }
}
