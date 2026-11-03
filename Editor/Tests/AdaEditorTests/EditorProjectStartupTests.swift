@_spi(AdaEngine) import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@Suite("Project startup", .serialized)
@MainActor
struct EditorProjectStartupTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "ProjectStartupBenchmark")))
        }
    }

    @Test("Measure startup preparation using a real large project")
    func realStartupBenchmark() throws {
        guard let path = ProcessInfo.processInfo.environment["ADAEDITOR_STARTUP_BENCHMARK"] else { return }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        EditorComponentRegistry.registerBuiltIns()
        let started = ContinuousClock.now
        let metadata = try ProjectSystem.loadProject(at: root)
        let metadataLoaded = ContinuousClock.now
        let items = EditorViewModel.buildProjectTreeItems(at: root, fileManager: .default)
        let filesLoaded = ContinuousClock.now
        let scripts = metadata.build.system.isAdaScript ? try EditorScriptableObjectCatalogLoader.load(project: metadata, at: root) : nil
        let scriptsLoaded = ContinuousClock.now
        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        let report: [String: Any] = [
            "metadataSeconds": seconds(started.duration(to: metadataLoaded)),
            "fileIndexSeconds": seconds(metadataLoaded.duration(to: filesLoaded)),
            "scriptCatalogSeconds": seconds(filesLoaded.duration(to: scriptsLoaded)),
            "totalSeconds": seconds(started.duration(to: scriptsLoaded)),
            "fileCount": items.count,
            "scriptCount": scripts?.playRuntime.sources.count ?? 0,
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if let output = ProcessInfo.processInfo.environment["ADAEDITOR_STARTUP_BENCHMARK_REPORT"] {
            try data.write(to: URL(fileURLWithPath: output))
        }
        #expect(!items.isEmpty)
    }

    @Test("Measure UI responsiveness while preparing a real project")
    func realResponsiveStartupBenchmark() async throws {
        guard let path = ProcessInfo.processInfo.environment["ADAEDITOR_STARTUP_BENCHMARK"] else { return }
        let project = EditorProjectReference(name: "Startup benchmark", path: path)
        var maximumGap: Duration = .zero
        var samples = 0
        let heartbeat = Task { @MainActor in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                let now = ContinuousClock.now
                maximumGap = max(maximumGap, previous.duration(to: now))
                samples += 1
                previous = now
            }
        }
        defer { heartbeat.cancel() }
        let start = ContinuousClock.now
        let data = try await EditorProjectStartupLoader.prepare(project: project)
        let elapsed = start.duration(to: .now)
        heartbeat.cancel()
        await heartbeat.value
        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        let report: [String: Any] = [
            "totalPreparationSeconds": seconds(elapsed), "maximumMainActorGapSeconds": seconds(maximumGap),
            "heartbeatSamples": samples, "fileCount": data.items.count,
            "scriptCount": data.scriptSupport?.playRuntime.sources.count ?? 0,
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
        if let output = ProcessInfo.processInfo.environment["ADAEDITOR_STARTUP_RESPONSIVENESS_REPORT"] {
            try json.write(to: URL(fileURLWithPath: output))
        }
        #expect(!data.items.isEmpty)
        #expect(samples > 0)
    }
}
