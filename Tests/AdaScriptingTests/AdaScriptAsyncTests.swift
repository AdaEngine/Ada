@_spi(Internal) import AdaApp
import AdaAssets
import AdaECS
@testable import AdaScripting
import Foundation
import Testing

@Suite("AdaScript asynchronous tasks", .serialized)
struct AdaScriptAsyncTests {
    @Test("Game timers advance only with scheduler time")
    func gameTimerUsesDeltaTime() {
        let host = AdaScriptAsyncHost()
        host.ownerProvider = { "world:test:system:timer" }
        let timer = host.sleep(1)
        host.advanceGameTime(by: 0.4, forWorld: "world:test")
        #expect(!timer.isDone())
        host.advanceGameTime(by: 0, forWorld: "world:test")
        #expect(!timer.isDone())
        host.advanceGameTime(by: 0.6, forWorld: "world:test")
        #expect(timer.isDone())
        #expect(timer.result().isSuccess())
        #expect(host.sleep(-1).result().errorCode() == "invalidDuration")
        let cancelled = host.sleep(100)
        #expect(cancelled.cancel())
        #expect(cancelled.result().errorCode() == "cancelled")
        host.ownerProvider = { "world:other:system:timer" }
        let otherWorldTimer = host.sleep(0.2)
        host.advanceGameTime(by: 1, forWorld: "world:test")
        #expect(!otherWorldTimer.isDone())
        host.advanceGameTime(by: 0.2, forWorld: "world:other")
        #expect(otherWorldTimer.result().isSuccess())
        #expect(AdaScriptAsyncHost().sleep(1).result().errorCode() == "missingGameClock")
    }

    @Test("Real-time timers complete without a world update")
    func realTimeTimerCompletes() async throws {
        let timer = AdaScriptAsyncHost().sleepRealTime(0.01)
        try await Task.sleep(for: .milliseconds(30))
        #expect(timer.result().isSuccess())
    }

    @Test("A background save rejects paths outside writable roots")
    func rejectsSavePathTraversal() {
        let result = AdaScriptAsyncHost().writeText("@user://../escape.txt", "unsafe").result()
        #expect(!result.isSuccess())
        #expect(result.errorCode() == "invalidPath")
    }

    @Test("A save cannot follow a directory link outside the user root")
    @MainActor
    func rejectsSymlinkEscape() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdaScriptAsyncLink-\(UUID().uuidString)", isDirectory: true)
        let user = root.appendingPathComponent("User", isDirectory: true)
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: user.appendingPathComponent("Link"), withDestinationURL: outside)
        await AppWorldsExecutionContext.$currentID.withValue(UUID()) {
        await AssetsManager.setProjectDirectories(
            ProjectDirectories(source: root, assetsDirectory: root.appendingPathComponent("Assets"), userDataDirectory: user, cacheDirectory: root.appendingPathComponent("Cache"))
        )
        let result = AdaScriptAsyncHost().writeText("@user://Link/escape.txt", "unsafe").result()
        #expect(result.errorCode() == "invalidPath")
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("escape.txt").path))
        }
    }

    @Test("An async declaration coexists with a system")
    @MainActor
    func compilesAsyncDeclaration() throws {
        AsyncPosition.registerComponent()
        _ = try AdaScriptPlugin(source: """
        async func value() { return 3; }
        var started = false;
        @system class EmptySystem {
            @query(AsyncPosition) var positions;
            func update(context) {}
        }
        """)
    }

    @Test("Imported async calls require await, while unused sources stay independent")
    func checksOnlyReachableAsyncFunctions() throws {
        #expect(throws: AdaScriptError.self) {
            try AdaScriptPlugin(sources: [
                AdaScriptSource(path: "Main.ada", source: """
                import { work } from "./Helper";
                @system class S { func update(context) { work(); } }
                """),
                AdaScriptSource(path: "Helper.ada", source: "async func work() { return 1; }")
            ], name: "ImportedAsync")
        }
        _ = try AdaScriptPlugin(sources: [
            AdaScriptSource(path: "Main.ada", source: """
            func work() { return 1; }
            @system class S { func update(context) { work(); } }
            """),
            AdaScriptSource(path: "Unused.ada", source: "async func work() { return 2; }")
        ], name: "UnreachableAsync")
    }

    @Test("An async function yields without stopping ECS updates")
    @MainActor
    func resumesAcrossUpdates() async throws {
        AsyncPosition.registerComponent()
        let plugin = try AdaScriptPlugin(source: """
        var phase = 0;
        var started = false;

        async func advance() {
            phase = 1;
            await Tasks.nextFrame();
            phase = 2;
        }

        @system(scheduler: "update")
        class AsyncSystem {
            @query(AsyncPosition)
            var positions;
            func update(context) {
                if (!started) {
                    Tasks.start(advance());
                    started = true;
                }
                for (var row in positions) {
                    row.asyncPosition.value = phase;
                }
            }
        }
        """)
        let world = World(name: "AdaScript async test")
        let entity = world.spawn { AsyncPosition(value: -1) }
        plugin.setup(in: AppWorlds(main: world))

        await world.runScheduler(.update)
        #expect(world.get(AsyncPosition.self, from: entity.id)?.value == 0)
        await world.runScheduler(.update)
        #expect(world.get(AsyncPosition.self, from: entity.id)?.value == 1)
        await world.runScheduler(.update)
        await world.runScheduler(.update)
        #expect(world.get(AsyncPosition.self, from: entity.id)?.value == 2)
        #expect(plugin.diagnostics.isEmpty)
    }

    @Test("Nested async calls return a value after suspension")
    @MainActor
    func awaitsChildResult() async throws {
        AsyncPosition.registerComponent()
        let plugin = try AdaScriptPlugin(source: """
        var started = false;
        var result = 0;
        async func child() {
            await Tasks.nextFrame();
            return 7;
        }
        async func parent() { result = await child(); }
        @system class ParentSystem {
            @query(AsyncPosition) var positions;
            func update(context) {
                if (!started) { started = true; Tasks.start(parent()); }
                for (var row in positions) { row.asyncPosition.value = result; }
            }
        }
        """)
        let world = World(name: "AdaScript nested async")
        let entity = world.spawn { AsyncPosition(value: 0) }
        plugin.setup(in: AppWorlds(main: world))
        for _ in 0..<10 { await world.runScheduler(.update) }
        #expect(world.get(AsyncPosition.self, from: entity.id)?.value == 7)
        #expect(plugin.diagnostics.isEmpty)
    }

    @Test("A promise resumes its waiter after a later update")
    @MainActor
    func waitsForConfirmation() async throws {
        AsyncPosition.registerComponent()
        let plugin = try AdaScriptPlugin(source: """
        var started = false;
        var count = 0;
        var answer = Tasks.promise();

        async func ask() {
            var confirmed = await answer;
            if (confirmed) { count = 7; } else { count = -7; }
        }

        @system class ConfirmationSystem {
            @query(AsyncPosition) var positions;
            func update(context) {
                if (!started) {
                    started = true;
                    Tasks.start(ask());
                } else if (count == 0) {
                    answer.complete(true);
                }
                for (var row in positions) { row.asyncPosition.value = count; }
            }
        }
        """)
        let world = World(name: "AdaScript confirmation test")
        let entity = world.spawn { AsyncPosition(value: 0) }
        plugin.setup(in: AppWorlds(main: world))
        for _ in 0..<5 { await world.runScheduler(.update) }
        #expect(world.get(AsyncPosition.self, from: entity.id)?.value == 7)
        #expect(plugin.diagnostics.isEmpty)
    }

    @Test("A save writes atomically without stopping updates")
    @MainActor
    func writesTextInBackground() async throws {
        AsyncPosition.registerComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdaScriptAsyncSave-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await AppWorldsExecutionContext.$currentID.withValue(UUID()) {
        await AssetsManager.setProjectDirectories(
            ProjectDirectories(
                source: root,
                assetsDirectory: root.appendingPathComponent("Assets", isDirectory: true),
                userDataDirectory: root.appendingPathComponent("User", isDirectory: true),
                cacheDirectory: root.appendingPathComponent("Cache", isDirectory: true)
            )
        )
        let plugin = try AdaScriptPlugin(source: """
        var started = false;
        var saveStatus = 0;
        async func save() {
            var result = await Saves.writeAsync("@user://Save/data.txt", "saved in background");
            if (result.isSuccess() && result.committed()) {
                saveStatus = 1;
            } else {
                saveStatus = -1;
            }
        }
        @system class SaveSystem {
            @query(AsyncPosition) var positions;
            func update(context) {
                if (!started) { started = true; Tasks.start(save()); }
                for (var row in positions) { row.asyncPosition.value = saveStatus; }
            }
        }
        """)
        let world = World(name: "AdaScript background save")
        let entity = world.spawn { AsyncPosition(value: 0) }
        plugin.setup(in: AppWorlds(main: world))
        let destination = root.appendingPathComponent("User/Save/data.txt")
        for _ in 0..<30 where world.get(AsyncPosition.self, from: entity.id)?.value == 0 {
            await world.runScheduler(.update)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(world.get(AsyncPosition.self, from: entity.id)?.value == 1)
        let content = try String(contentsOf: destination, encoding: .utf8)
        #expect(content == "saved in background", Comment(rawValue: "Actual save: \(content)"))
        #expect(plugin.diagnostics.isEmpty)
        }
    }

    @Test("A stream writes large data in bounded chunks and replaces atomically")
    @MainActor
    func streamsLargeSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdaScriptAsyncStream-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await AppWorldsExecutionContext.$currentID.withValue(UUID()) {
            let user = root.appendingPathComponent("User", isDirectory: true)
            await AssetsManager.setProjectDirectories(
                ProjectDirectories(source: root, assetsDirectory: root.appendingPathComponent("Assets"), userDataDirectory: user, cacheDirectory: root.appendingPathComponent("Cache"))
            )
            let destination = user.appendingPathComponent("Saves/large.txt")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "old".write(to: destination, atomically: true, encoding: .utf8)
            let writer = AdaScriptAsyncHost().beginSave("@user://Saves/large.txt")
            let chunk = String(repeating: "x", count: 262_144)
            for _ in 0..<16 {
                let result = try await waitForOperation(writer.append(chunk))
                #expect(result.isSuccess())
            }
            let committed = try await waitForOperation(writer.finish())
            #expect(committed.isSuccess() && committed.committed())
            let data = try Data(contentsOf: destination)
            #expect(data.count == 4_194_304)
            #expect(data.first == 120 && data.last == 120)
        }
    }

    @Test("AdaScript can await a streamed save")
    @MainActor
    func streamsSaveFromScript() async throws {
        AsyncPosition.registerComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdaScriptAsyncScriptStream-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await AppWorldsExecutionContext.$currentID.withValue(UUID()) {
            await AssetsManager.setProjectDirectories(
                ProjectDirectories(
                    source: root,
                    assetsDirectory: root.appendingPathComponent("Assets"),
                    userDataDirectory: root.appendingPathComponent("User"),
                    cacheDirectory: root.appendingPathComponent("Cache")
                )
            )
            let plugin = try AdaScriptPlugin(source: """
            var started = false;
            var saveStatus = 0;
            async func save() {
                var writer = Saves.begin("@user://Saves/stream.txt");
                var first = await writer.appendAsync("hello ");
                var second = await writer.appendAsync("world");
                var last = await writer.finishAsync();
                if (first.isSuccess() && second.isSuccess() && last.committed()) { saveStatus = 1; }
                else { saveStatus = -1; }
            }
            @system class SaveSystem {
                @query(AsyncPosition) var positions;
                func update(context) {
                    if (!started) { started = true; Tasks.start(save()); }
                    for (var row in positions) { row.asyncPosition.value = saveStatus; }
                }
            }
            """)
            let world = World(name: "AdaScript streamed save")
            let entity = world.spawn { AsyncPosition(value: 0) }
            plugin.setup(in: AppWorlds(main: world))
            for _ in 0..<40 where world.get(AsyncPosition.self, from: entity.id)?.value == 0 {
                await world.runScheduler(.update)
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(world.get(AsyncPosition.self, from: entity.id)?.value == 1)
            let text = try String(contentsOf: root.appendingPathComponent("User/Saves/stream.txt"), encoding: .utf8)
            #expect(text == "hello world")
            #expect(plugin.diagnostics.isEmpty)
        }
    }

    @Test("Cancelling a streamed save retains the previous file")
    @MainActor
    func cancelsStreamWithoutCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdaScriptAsyncStreamCancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await AppWorldsExecutionContext.$currentID.withValue(UUID()) {
            let user = root.appendingPathComponent("User", isDirectory: true)
            await AssetsManager.setProjectDirectories(
                ProjectDirectories(source: root, assetsDirectory: root.appendingPathComponent("Assets"), userDataDirectory: user, cacheDirectory: root.appendingPathComponent("Cache"))
            )
            let destination = user.appendingPathComponent("Saves/data.txt")
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "previous".write(to: destination, atomically: true, encoding: .utf8)
            let writer = AdaScriptAsyncHost().beginSave("@user://Saves/data.txt")
            #expect(try await waitForOperation(writer.append("new data")).isSuccess())
            writer.cancel()
            #expect(writer.append("late chunk").result().errorCode() == "cancelled")
            try await Task.sleep(for: .milliseconds(20))
            #expect(try String(contentsOf: destination, encoding: .utf8) == "previous")
        }
    }

    @Test("An asset loads asynchronously while systems keep updating")
    @MainActor
    func loadsAssetInBackground() async throws {
        AsyncPosition.registerComponent()
        AssetsManager.registerAssetType(AsyncTextAsset.self)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdaScriptAsyncLoad-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await AppWorldsExecutionContext.$currentID.withValue(UUID()) {
        await AssetsManager.setProjectDirectories(
            ProjectDirectories(
                source: root,
                assetsDirectory: root.appendingPathComponent("Assets", isDirectory: true),
                userDataDirectory: root.appendingPathComponent("User", isDirectory: true),
                cacheDirectory: root.appendingPathComponent("Cache", isDirectory: true)
            )
        )
        try await AssetsManager.save(AsyncTextAsset(value: "shop catalog"), at: "@res://Catalog/shop.asynctext")
        let plugin = try AdaScriptPlugin(source: """
        var started = false;
        var loadStatus = 0;
        async func loadShop() {
            var result = await Assets.loadAsync("@res://Catalog/shop.asynctext");
            if (result.isSuccess()) {
                var saved = await Assets.saveAsync(result.value(), "@user://Copied/shop.asynctext");
                if (saved.isSuccess()) { loadStatus = 1; } else { loadStatus = -2; }
            } else { loadStatus = -1; }
        }
        @system class ShopSystem {
            @query(AsyncPosition) var positions;
            func update(context) {
                if (!started) { started = true; Tasks.start(loadShop()); }
                for (var row in positions) { row.asyncPosition.value = loadStatus; }
            }
        }
        """)
        let world = World(name: "AdaScript async shop load")
        let entity = world.spawn { AsyncPosition(value: 0) }
        plugin.setup(in: AppWorlds(main: world))
        for _ in 0..<4 { await world.runScheduler(.update) }
        #expect(world.get(AsyncPosition.self, from: entity.id)?.value == 0)
        for _ in 0..<30 where world.get(AsyncPosition.self, from: entity.id)?.value == 0 {
            await world.runScheduler(.update)
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(world.get(AsyncPosition.self, from: entity.id)?.value == 1)
        #expect(plugin.diagnostics.isEmpty)
        let copied = try await AssetsManager.load(AsyncTextAsset.self, at: "@user://Copied/shop.asynctext")
        #expect(copied.asset.value == "shop catalog")
        }
    }

    @Test("A UI action resumes after confirmation without blocking the view")
    @MainActor
    func resumesViewActionAfterConfirmation() async throws {
        let sources = [
            AdaScriptSource(path: "Confirmation.ada", source: """
            @view class ConfirmationView {
                var label = "idle";
                var answer = Tasks.promise();

                async func requestConfirmation() {
                    label = "waiting";
                    var confirmed = await answer;
                    if (confirmed) { label = "confirmed"; }
                    else { label = "cancelled"; }
                }

                func ask() { Tasks.start(self.requestConfirmation()); }
                func confirm() { answer.complete(true); }
                func body() { Text(label); }
            }
            """)
        ]
        let runtime = try AdaScriptViewModuleRuntime(sources: sources, views: AdaScriptViewScanner.declarations(in: sources))
        let storage = try runtime.makeStorage(identifier: "ConfirmationView")
        try storage.updateEnvironment([:])
        try storage.perform(action: "ask")
        for _ in 0..<30 {
            await Task.yield()
            try storage.updateEnvironment([:])
            if case .text("waiting") = storage.model?.content { break }
        }
        guard case .text("waiting") = storage.model?.content else {
            Issue.record("Confirmation coroutine did not suspend")
            return
        }
        try storage.perform(action: "confirm")
        try storage.perform(action: "confirm")
        for _ in 0..<30 {
            await Task.yield()
            try storage.updateEnvironment([:])
            if case .text("confirmed") = storage.model?.content { break }
        }
        guard case .text("confirmed") = storage.model?.content else {
            Issue.record("Confirmation coroutine did not resume")
            return
        }
    }

    @Test("Disposing a view cancels its suspended tasks")
    @MainActor
    func cancelsViewOwnedTasks() async throws {
        let sources = [
            AdaScriptSource(path: "Pending.ada", source: """
            @view class PendingView {
                var answer = Tasks.promise();
                async func waitForever() { await answer; }
                func ask() { Tasks.start(self.waitForever()); }
                func body() { Text("Pending"); }
            }
            """)
        ]
        let runtime = try AdaScriptViewModuleRuntime(sources: sources, views: AdaScriptViewScanner.declarations(in: sources))
        var storage: AdaScriptViewStorage? = try runtime.makeStorage(identifier: "PendingView")
        try storage?.updateEnvironment([:])
        try storage?.perform(action: "ask")
        #expect(runtime.activeTaskCount > 0)
        weak var weakStorage = storage
        storage = nil
        for _ in 0..<10 where weakStorage != nil { await Task.yield() }
        #expect(weakStorage == nil)
        #expect(runtime.activeTaskCount == 0)
    }

    @Test("Retiring a view generation discards its coroutine")
    @MainActor
    func cancelsRetiredViewTasks() throws {
        let sources = [
            AdaScriptSource(path: "Reload.ada", source: """
            @view class ReloadView {
                var pending = Tasks.promise();
                async func wait() { await pending; }
                func begin() { Tasks.start(self.wait()); }
                func body() { Text("Active"); }
            }
            """)
        ]
        let runtime = try AdaScriptViewModuleRuntime(sources: sources, views: AdaScriptViewScanner.declarations(in: sources))
        let storage = try runtime.makeStorage(identifier: "ReloadView")
        try storage.updateEnvironment([:])
        try storage.perform(action: "begin")
        #expect(runtime.activeTaskCount == 1)
        runtime.retire()
        #expect(runtime.activeTaskCount == 0)
        #expect(throws: AdaScriptError.self) { try storage.perform(action: "begin") }
    }

    @Test("A query row cannot be used after suspension")
    @MainActor
    func rejectsBorrowedRowAfterAwait() async throws {
        AsyncPosition.registerComponent()
        let plugin = try AdaScriptPlugin(source: """
        var started = false;
        async func writeLater(row) {
            await Tasks.nextFrame();
            row.asyncPosition.value = 9;
        }
        @system class BorrowSystem {
            @query(AsyncPosition) var positions;
            func update(context) {
                if (!started) {
                    started = true;
                    for (var row in positions) { Tasks.start(writeLater(row)); }
                }
            }
        }
        """)
        let world = World(name: "AdaScript borrowed row test")
        let entity = world.spawn { AsyncPosition(value: 3) }
        plugin.setup(in: AppWorlds(main: world))
        for _ in 0..<5 { await world.runScheduler(.update) }
        #expect(world.get(AsyncPosition.self, from: entity.id)?.value == 3)
        #expect(plugin.diagnostics.contains(where: { $0.contains("no longer valid") }))
    }

    @Test("Destroying a world cancels its pending AdaScript tasks")
    @MainActor
    func cancelsWorldOwnedTasks() async throws {
        let plugin = try AdaScriptPlugin(source: """
        var started = false;
        var signal = Tasks.promise();
        async func waitForSignal() { await signal; }
        @system class PendingSystem {
            func update(context) {
                if (!started) { started = true; Tasks.start(waitForSignal()); }
            }
        }
        """)
        let world = World(name: "AdaScript cancelled world")
        let app = AppWorlds(main: world)
        plugin.setup(in: app)
        await world.runScheduler(.update)
        #expect(plugin.activeAsyncTaskCount == 1)
        plugin.destroy(for: app)
        #expect(plugin.activeAsyncTaskCount == 0)
    }

    @Test("A failed coroutine quarantines its VM with a task diagnostic")
    @MainActor
    func reportsCoroutineFailure() async throws {
        AsyncPosition.registerComponent()
        let plugin = try AdaScriptPlugin(source: """
        var started = false;
        var marker = 0;
        async func fail() { Fiber.abort("expected coroutine failure"); }
        async func succeed() { marker = 1; }
        @system class FailureSystem {
            @query(AsyncPosition) var positions;
            func update(context) {
                if (!started) {
                    started = true;
                    Tasks.start(fail());
                    Tasks.start(succeed());
                }
                for (var row in positions) { row.asyncPosition.value = marker; }
            }
        }
        """)
        let world = World(name: "AdaScript failed coroutine")
        let entity = world.spawn { AsyncPosition(value: 0) }
        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)
        await world.runScheduler(.update)
        await world.runScheduler(.update)
        #expect(plugin.diagnostics.contains(where: { $0.contains("expected coroutine failure") }))
        #expect(plugin.diagnostics.contains(where: { $0.contains("ADASCRIPT_VM_ABORTED") && $0.contains("trace=") }))
        #expect(world.get(AsyncPosition.self, from: entity.id)?.value == 0)
    }
}
