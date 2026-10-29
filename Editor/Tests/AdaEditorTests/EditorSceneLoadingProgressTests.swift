import AdaEngine
import AdaScripting
import Foundation
import Synchronization
import Testing

@MainActor
@Suite("Scene loading progress", .serialized)
struct EditorSceneLoadingProgressTests {
    @Test("AdaScript can read loading progress, stage and failure")
    func scriptProgressQueries() async throws {
        let world = World()
        let app = AppWorlds(main: world)
        ScenePlugin(includesModel3D: false).setup(in: app)
        let navigator = try #require(world.getResource(SceneNavigator.self))
        let plugin = try AdaScriptPlugin(source: """
            @component(id: "progress.probe") struct Probe {
                @export var fraction = 0.0;
                @export var stage = "";
                @export var error = "";
            }
            @system(id: "progress.reader") class Reader {
                @query(Probe) var probes;
                func update(context) {
                    for (var row in probes) {
                        row.probe.fraction = context.world.sceneLoadingProgress();
                        row.probe.stage = context.world.sceneLoadingStage();
                        row.probe.error = context.world.sceneLoadingError();
                    }
                }
            }
            """, name: "Progress queries")
        plugin.setup(in: app)
        defer { plugin.destroy(for: app) }
        let descriptor = try #require(world.runtimeComponentDescriptor(named: "Probe"))
        let entity = world.spawn {}
        world.insertRuntimeComponent(descriptor.makeDefault(), for: entity.id)
        navigator.setSceneLoader { _, report in
            report(.init(fraction: 0.42, stage: "assets"))
            throw FixtureError()
        }
        navigator.requestReplaceScene(with: "Broken")
        for _ in 0..<100 where navigator.lastError == nil { try await Task.sleep(for: .milliseconds(5)) }
        await world.runScheduler(.update)
        let probe = try #require(world.getRuntimeComponent(descriptor.componentID, from: entity.id))
        func value(_ key: String) throws -> ReflectedFieldValue { probe.values[try #require(descriptor.fields.firstIndex { $0.key == key })] }
        #expect(try value("fraction") == .double(0.42))
        #expect(try value("stage") == .string("failed"))
        #expect(try value("error") != .string(""))
        #expect(plugin.diagnostics.isEmpty, "\(plugin.diagnostics)")
    }

    @Test("Progress is monotonic and completes only after a frame installs the scene")
    func completionAtFrameBoundary() async throws {
        let world = World()
        ScenePlugin(includesModel3D: false).setup(in: AppWorlds(main: world))
        let navigator = try #require(world.getResource(SceneNavigator.self))
        navigator.setSceneLoader { _, report in
            report(.init(fraction: 0.4, stage: "assets"))
            report(.init(fraction: 0.1, stage: "reading"))
            report(.init(fraction: .nan, stage: "assets"))
            try await Task.sleep(for: .milliseconds(100))
            return await MainActor.run { Scene(name: "Loaded") }
        }
        navigator.requestReplaceScene(with: "Loaded")
        for _ in 0..<100 where navigator.loadingProgress.fraction == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(navigator.loadingProgress.fraction == 0.4)
        #expect(navigator.loadingProgress.stage == "assets")
        for _ in 0..<100 where navigator.loadingProgress.fraction < 0.99 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(navigator.loadingProgress.fraction == 0.99)
        #expect(navigator.currentScenePath == nil)
        await world.runScheduler(.postUpdate)
        #expect(navigator.loadingProgress.fraction == 1)
        #expect(navigator.loadingProgress.stage == "ready")
        #expect(navigator.currentScenePath == "Loaded")
    }

    @Test("An old callback cannot advance a newer request; errors retain the active scene")
    func supersededCallbacksAndFailure() async throws {
        let world = World()
        ScenePlugin(includesModel3D: false).setup(in: AppWorlds(main: world))
        let navigator = try #require(world.getResource(SceneNavigator.self))
        navigator.installInitialScene(Scene(name: "Safehouse"), make: { Scene(name: "Safehouse") })
        let callbacks = Mutex<[@Sendable (SceneNavigator.LoadingProgress) -> Void]>([])
        navigator.setSceneLoader { path, report in
            callbacks.withLock { $0.append(report) }
            if path == "Broken" { throw FixtureError() }
            try await Task.sleep(for: .milliseconds(150))
            return await MainActor.run { Scene(name: path) }
        }
        navigator.requestReplaceScene(with: "Old")
        for _ in 0..<100 where callbacks.withLock({ $0.isEmpty }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let old = try #require(callbacks.withLock { $0.first })
        navigator.requestReplaceScene(with: "Broken")
        for _ in 0..<100 where navigator.lastError == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        old(.init(fraction: 0.9, stage: "assets"))
        #expect(navigator.loadingProgress.fraction == 0)
        #expect(navigator.loadingProgress.stage == "failed")
        #expect(navigator.lastError != nil)
        #expect(world.getEntityByName("Scene: Safehouse") != nil)
        try await Task.sleep(for: .milliseconds(170))
        await world.runScheduler(.postUpdate)
        #expect(world.getEntityByName("Scene: Safehouse") != nil)
    }

    private struct FixtureError: Error {}
}
