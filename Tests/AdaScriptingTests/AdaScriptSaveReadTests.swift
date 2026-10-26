@_spi(Internal) import AdaApp
import AdaAssets
import AdaECS
@testable import AdaScripting
import Foundation
import Synchronization
import Testing

@MainActor
@Suite(.serialized)
struct AdaScriptSaveReadTests {
    @Test func scriptReadsWrittenMissingAndEmptySaves() async throws {
        try await withRoots { root in
            AsyncPosition.registerComponent()
            let plugin = try AdaScriptPlugin(source: #"""
            var started = false;
            var status = 0;
            async func exercise() {
                var missing = await Saves.readAsync("@user://missing.json");
                var text = "{\"version\":1,\"item\":\"образец\"}";
                var written = await Saves.writeAsync("@user://stash.json", text);
                var loaded = await Saves.readAsync("@user://stash.json");
                var cleared = await Saves.writeAsync("@cache://empty.json", "");
                var empty = await Saves.readAsync("@cache://empty.json");
                status = -1;
                if (missing.isSuccess() && !missing.exists() && missing.value() == "" &&
                    written.committed() && !written.exists() && loaded.isSuccess() && loaded.exists() && loaded.value() == text &&
                    cleared.committed() && empty.isSuccess() && empty.exists() && empty.value() == "") status = 1;
            }
            @system class ReadSaveSystem {
                @query(AsyncPosition) var positions;
                func update(context) {
                    if (!started) { started = true; Tasks.start(exercise()); }
                    for (var row in positions) { row.asyncPosition.value = status; }
                }
            }
            """#)
            let world = World()
            let app = AppWorlds(main: world)
            let entity = world.spawn { AsyncPosition(value: 0) }
            plugin.setup(in: app)
            for _ in 0..<100 where world.get(AsyncPosition.self, from: entity.id)?.value == 0 {
                await world.runScheduler(.update)
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(world.get(AsyncPosition.self, from: entity.id)?.value == 1)
            #expect(plugin.diagnostics.isEmpty, "\(plugin.diagnostics)")
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("User/stash.json").path))
        }
    }

    @Test(arguments: ["@user://../outside", "@cache://../outside", "@res://secret", "/tmp/secret", "file:///tmp/secret"])
    func rejectsPathsOutsideSaveRoots(_ path: String) async throws {
        try await withRoots { _ in
            let result = AdaScriptAsyncHost().readText(path).result()
            #expect(!result.isSuccess() && !result.exists())
            #expect(result.errorCode() == "invalidPath")
        }
    }

    @Test func rejectsInvalidEncodingOversizedAndUnreadableSaves() async throws {
        try await withRoots { root in
            let user = root.appendingPathComponent("User")
            try Data([0xFF]).write(to: user.appendingPathComponent("invalid"))
            try Data(repeating: 120, count: 4 * 1_024 * 1_024 + 1).write(to: user.appendingPathComponent("large"))
            try FileManager.default.createDirectory(at: user.appendingPathComponent("directory"), withIntermediateDirectories: true)
            for (name, code) in [("invalid", "invalidUTF8"), ("large", "fileTooLarge"), ("directory", "readFailed")] {
                let result = try await waitForOperation(AdaScriptAsyncHost().readText("@user://" + name))
                #expect(!result.isSuccess() && !result.exists())
                #expect(result.errorCode() == code)
            }
        }
    }

    #if !os(Windows)
    @Test func checksFinalAndParentSymlinksButAllowsContainedLinks() async throws {
        try await withRoots { root in
            let user = root.appendingPathComponent("User")
            let outside = root.appendingPathComponent("Outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data("private".utf8).write(to: outside.appendingPathComponent("secret"))
            try Data("safe".utf8).write(to: user.appendingPathComponent("inside"))
            for (name, target) in [("leaf", outside.appendingPathComponent("secret")), ("parent", outside), ("local", user.appendingPathComponent("inside"))] {
                try FileManager.default.createSymbolicLink(at: user.appendingPathComponent(name), withDestinationURL: target)
            }
            for path in ["@user://leaf", "@user://parent/secret"] {
                #expect(AdaScriptAsyncHost().readText(path).result().errorCode() == "invalidPath")
            }
            let local = try await waitForOperation(AdaScriptAsyncHost().readText("@user://local"))
            #expect(local.isSuccess() && local.exists() && local.value() == "safe")
        }
    }
    #endif

    @Test func concurrentScopesResolveTheirOwnSaveBeforeWorkersRun() async throws {
        try await withRoots { first in
            try Data("first".utf8).write(to: first.appendingPathComponent("User/save"))
            let firstRead = AdaScriptAsyncHost().readText("@user://save")
            try await withRoots { second in
                try Data("second".utf8).write(to: second.appendingPathComponent("User/save"))
                let secondRead = AdaScriptAsyncHost().readText("@user://save")
                #expect(try await waitForOperation(firstRead).value() == "first")
                #expect(try await waitForOperation(secondRead).value() == "second")
            }
        }
    }

    @Test func cancellationAndCompletionWakeTheOwnerOnce() async throws {
        try await withRoots { root in
            try Data(repeating: 120, count: 4 * 1_024 * 1_024).write(to: root.appendingPathComponent("User/save"))
            let wakes = Mutex(0)
            let host = AdaScriptAsyncHost()
            host.onWake = { wakes.withLock { $0 += 1 } }
            let operation = host.readText("@user://save")
            let cancelled = operation.cancel()
            let result = try await waitForOperation(operation)
            #expect(cancelled ? result.errorCode() == "cancelled" : result.isSuccess())
            try await Task.sleep(for: .milliseconds(20))
            #expect(wakes.withLock { $0 } == 1)
        }
    }

    private func withRoots(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AdaSaveRead-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("User"), withIntermediateDirectories: true)
        try await AppWorldsExecutionContext.$currentID.withValue(UUID()) {
            await AssetsManager.setProjectDirectories(ProjectDirectories(
                source: root,
                assetsDirectory: root.appendingPathComponent("Assets"),
                userDataDirectory: root.appendingPathComponent("User"),
                cacheDirectory: root.appendingPathComponent("Cache")
            ))
            try await body(root)
        }
    }
}
