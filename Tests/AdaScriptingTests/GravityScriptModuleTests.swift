@testable import AdaApp
import AdaECS
import AdaScripting
import Foundation
import Testing

@Suite("Multi-file Gravity modules", .serialized)
struct GravityScriptModuleTests {
    @Test("Compiler errors retain their diagnostic text for the editor")
    func compilationErrorDescription() {
        let error = AdaScriptError.compilation(["Main.ada:5:30: Unknown identifier 'components'"])
        #expect(error.localizedDescription == "Main.ada:5:30: Unknown identifier 'components'")
    }

    @Test("Compiler reports an undefined spawn argument with its source location")
    func undefinedSpawnArgument() {
        do {
            _ = try AdaScriptPlugin(
                sources: [AdaScriptSource(
                    path: "Main.ada",
                    source: """
                        @system(scheduler: "update", id: "game.main")
                        class MainSystem {
                            func update(context: AdaSystemContext) {
                                context.world.spawn(components)
                            }
                        }
                        """
                )],
                name: "UndefinedSpawnArgument"
            )
            Issue.record("Expected an AdaScript compilation error")
        } catch let error as AdaScriptError {
            #expect(error.localizedDescription.contains("components"))
            #expect(error.localizedDescription.contains("Main.ada:4:"))
        } catch {
            Issue.record("Expected AdaScriptError, got \(error)")
        }
    }

    @Test("Runs imported helpers and multiple system roots in one module")
    @MainActor
    func runsMultiFileModule() async throws {
        ModulePosition.registerComponent()
        ModuleCounter.registerComponent()

        let plugin = try AdaScriptPlugin(
            sources: Self.multiFileSources,
            name: "MultiFileTest"
        )

        let world = World(name: "Multi-file Gravity module")
        let entity = world.spawn {
            ModulePosition(value: 1)
            ModuleCounter(value: 10)
        }
        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)

        #expect(plugin.diagnostics.isEmpty)
        #expect(world.get(ModulePosition.self, from: entity.id)?.value == 4)
        #expect(world.get(ModuleCounter.self, from: entity.id)?.value == 12)
    }

    @Test("Reports the complete reachable import cycle")
    func reportsImportCycle() {
        #expect {
            try AdaScriptPlugin(
                sources: [
                    AdaScriptSource(
                        path: "A.ada",
                        source: """
                        import { helper } from "./B";

                        @system
                        class CycleSystem {
                            func update(context) {}
                        }
                        """
                    ),
                    AdaScriptSource(
                        path: "B.ada",
                        source: """
                        import { CycleSystem } from "./A";
                        func helper() {}
                        """
                    )
                ],
                name: "Cycle"
            )
        } throws: { error in
            (error as? AdaScriptError) == .importCycle(["A.ada", "B.ada", "A.ada"])
        }
    }

    @Test("Rejects imports that escape the target source map")
    func rejectsEscapingImport() {
        #expect(throws: AdaScriptError.self) {
            try AdaScriptPlugin(
                sources: [
                    AdaScriptSource(
                        path: "Systems/Unsafe.ada",
                        source: """
                        import { Secret } from "../../Secret";

                        @system
                        class UnsafeSystem {
                            func update(context) {}
                        }
                        """
                    )
                ],
                name: "Unsafe"
            )
        }
    }

    @Test("Rejects duplicate canonical source paths")
    func rejectsDuplicateSourcePaths() {
        #expect {
            try AdaScriptPlugin(
                sources: [
                    AdaScriptSource(path: "Shared/../Main.ada", source: ""),
                    AdaScriptSource(path: "Main.ada", source: "")
                ],
                name: "Duplicate"
            )
        } throws: { error in
            (error as? AdaScriptError) == .duplicateSourcePath("Main.ada")
        }
    }

    @Test("Preserves the imported source identity in compiler diagnostics")
    func preservesImportedSourceIdentity() {
        #expect {
            try AdaScriptPlugin(
                sources: [
                    AdaScriptSource(
                        path: "Main.ada",
                        source: """
                        import { broken } from "./Shared/Broken";

                        @system
                        class DiagnosticSystem {
                            func update(context) {}
                        }
                        """
                    ),
                    AdaScriptSource(path: "Shared/Broken.ada", source: "func broken( {")
                ],
                name: "Diagnostics"
            )
        } throws: { error in
            guard let scriptError = error as? AdaScriptError,
                  case .compilation(let diagnostics) = scriptError else { return false }
            return diagnostics.contains { $0.hasPrefix("Shared/Broken.ada:") }
        }
    }

    @Test("Rejects namespace imports until namespace isolation is implemented")
    func rejectsNamespaceImports() {
        #expect(throws: AdaScriptError.self) {
            try AdaScriptPlugin(
                sources: [
                    AdaScriptSource(
                        path: "Main.ada",
                        source: """
                        import * as Shared from "./Shared";

                        @system
                        class NamespaceSystem {
                            func update(context) {}
                        }
                        """
                    ),
                    AdaScriptSource(path: "Shared.ada", source: "func helper() {}")
                ],
                name: "Namespace"
            )
        }
    }

    private static let multiFileSources = [
        AdaScriptSource(
            path: "Shared/Steps.ada",
            source: """
            func importedStep() {
                return 3;
            }
            """
        ),
        AdaScriptSource(
            path: "Systems/Movement.ada",
            source: """
            import {
                importedStep
            } from "../Shared/Steps";

            @system(id: "module.movement")
            class ModuleMovementSystem {
                @query(ModulePosition)
                var entities;

                func update(context) {
                    for (var entity in entities) {
                        entity.modulePosition.value += importedStep();
                    }
                }
            }
            """
        ),
        AdaScriptSource(
            path: "Systems/Counter.ada",
            source: """
            @system(id: "module.counter")
            class ModuleCounterSystem {
                @query(ModuleCounter)
                var entities;

                func update(context) {
                    for (var entity in entities) {
                        entity.moduleCounter.value += 2;
                    }
                }
            }
            """
        ),
        AdaScriptSource(path: "Unused/Broken.ada", source: "func broken( {")
    ]
}

@Component
private struct ModulePosition {
    var value: Double
}

@Component
private struct ModuleCounter {
    var value: Double
}
