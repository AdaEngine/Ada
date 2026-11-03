import AdaEngine
import Foundation
import SponzaCamera

/// Opt-in measurements of actual SceneView publication, with no image readback in the interval.
@MainActor
final class SponzaDemoProfiler {
    struct Measurement: Codable {
        var view: String
        var shadows: Bool
        var round: Int
        var width: Int
        var height: Int
        var publishedIntervalsMilliseconds: [Double]
        var graphRecords: [RenderGraphFrameRecord]
        var motion: String?
        var cameraUpdates: Int?
        var preset: String?
        var localLightCount: Int?
        var lightStatistics: [String: Render3DLightStatistics.Snapshot]?
        var pathTracing: [String: PathTracing3DStatus]?
        var pathFramesBefore: [String: Int]?
        var pathSettings: PathTracing3D?
        var meshlets: [String: Meshlet3DCount]?
        var meshletGPUIndexCount: Int?
        var meshletLODPixelError: Float?
        var shadowCascadeResolution: Int?
        var localShadowResolution: Int?
        var shadowDistance: Float?
    }

    let output: URL
    let usesFixedViewport = ProcessInfo.processInfo.environment["ADAENGINE_SPONZA_PROFILE_STUTTER"] != "1"
    private(set) var isRunning = false
    var recording = false
    var last: ContinuousClock.Instant?
    var intervals: [Double] = []
    var size = [0, 0]
    var sizeChanged = false
    var motion = SponzaCameraMotion.stationary
    var motionOrigin = Transform()
    var motionStart: ContinuousClock.Instant?
    var cameraUpdates = 0

    init(output: URL) { self.output = output }

    func cameraPose() -> Transform? {
        guard motion != .stationary, let motionStart else { return nil }
        let elapsed = motionStart.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        return motion.pose(from: motionOrigin, seconds: seconds)
    }

    func didMoveCamera() {
        if recording { cameraUpdates += 1 }
    }

    func didPresent(width: Int, height: Int) {
        guard recording else { return }
        if size[0] > 0, size != [width, height] { sizeChanged = true }
        let now = ContinuousClock.now
        if let last {
            PerformanceStallProbe.end("SceneView.PublishGap", since: last, count: width * height)
            let elapsed = last.duration(to: now).components
            intervals.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
        }
        last = now
        size = [width, height]
    }

    func run(session: SponzaSession, app: AppWorlds) async throws {
        guard let render = app.getSubworldBuilder(by: .renderWorld), let diagnostics = render.getResource(RenderGraphDiagnostics.self) else { return }
        isRunning = true
        defer { isRunning = false; recording = false; motionStart = nil }
        if !usesFixedViewport {
            try await runStutter(session: session, app: app, diagnostics: diagnostics)
            return
        }
        // Keep historical profiles comparable; the new LOD profile explicitly records its quality settings.
        session.meshletLODError = 0
        session.highResolutionShadows = false
        if ProcessInfo.processInfo.environment["ADAENGINE_SPONZA_PROFILE_MESHLETS"] == "1"
            || ProcessInfo.processInfo.environment["ADAENGINE_SPONZA_PROFILE_MESHLET_LOD"] == "1" {
            try await runMeshlets(session: session, app: app, diagnostics: diagnostics)
            return
        }
        session.meshletMode = .disabled
        session.meshletMapEnabled = false
        if let lighting = ProcessInfo.processInfo.environment["ADAENGINE_SPONZA_PROFILE_LIGHTING"],
            ["1", "lodRaster", "pathTracing"].contains(lighting) {
            try await runLighting(session: session, app: app, diagnostics: diagnostics)
            return
        }
        try await app.withWorldAccess {
            session.dlssEnabled = false
            session.flyingLightEnabled = false
            session.apply(preset: .fullRaster, lights: 0)
        }
        var measurements: [Measurement] = []
        let requestedMotion = ProcessInfo.processInfo.environment["ADAENGINE_SPONZA_PROFILE_MOTION"]
        let selectedMotion = requestedMotion.flatMap(SponzaCameraMotion.init(rawValue:))
        let motionRun = requestedMotion == "1" || selectedMotion != nil
        let motions = selectedMotion.map { [$0] } ?? SponzaCameraMotion.allCases
        let scenarios = motionRun ? motions.map { (2, $0) } : [0, 2, 3].map { ($0, .stationary) }
        for (view, mode) in scenarios {
            for round in 0..<3 {
                for shadows in round.isMultiple(of: 2) ? [true, false] : [false, true] {
                    try await app.withWorldAccess {
                        session.move(to: view)
                        motion = mode
                        motionOrigin = session.flight.transform
                        motionStart = .now
                        if let camera = session.camera, var environment = camera.components[Environment3D.self] {
                            environment.shadows.isEnabled = shadows
                            camera.components[Environment3D.self] = environment
                        }
                        diagnostics.configure(isEnabled: true, capacity: 64)
                        diagnostics.clear()
                    }
                    session.status = "Измеряем сцену…"
                    try await Task.sleep(for: .seconds(1))
                    intervals.removeAll(keepingCapacity: true)
                    intervals.reserveCapacity(1024)
                    last = nil
                    cameraUpdates = 0
                    recording = true
                    try await Task.sleep(for: .seconds(motionRun ? 6 : 2))
                    recording = false
                    let records = try await app.withWorldAccess { diagnostics.records }
                    let name = ["atrium", "corridor", "gallery", "outside"][view]
                    measurements.append(Measurement(view: name, shadows: shadows, round: round,
                        width: size[0], height: size[1], publishedIntervalsMilliseconds: intervals, graphRecords: records,
                        motion: mode.rawValue, cameraUpdates: cameraUpdates, preset: session.preset.rawValue,
                        localLightCount: session.lightCount))
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try encoder.encode(measurements).write(to: output, options: .atomic)
                }
            }
        }
        try await app.withWorldAccess {
            diagnostics.configure(isEnabled: false)
            if let camera = session.camera, var environment = camera.components[Environment3D.self] {
                environment.shadows.isEnabled = true
                camera.components[Environment3D.self] = environment
            }
            session.move(to: 3)
        }
        session.status = "Sponza + Ivy · полная сцена / отдельный PT LOD"
        FileHandle.standardOutput.write(Data("SPONZA_PROFILE_READY \(output.path)\n".utf8))
    }

    private func runLighting(session: SponzaSession, app: AppWorlds, diagnostics: RenderGraphDiagnostics) async throws {
        let render = app.getSubworldBuilder(by: .renderWorld)
        guard let tracing = render?.getResource(Render3DPathTracingStatistics.self),
            let lights = render?.getResource(Render3DLightStatistics.self) else { throw CocoaError(.featureUnsupported) }
        let selected = ProcessInfo.processInfo.environment["ADAENGINE_SPONZA_PROFILE_MOTION"].flatMap(SponzaCameraMotion.init(rawValue:)) ?? .rotation
        session.pathHighQuality = false
        session.dlssEnabled = false
        session.flyingLightEnabled = false
        var measurements: [Measurement] = []
        // Group modes so the cold CPU BVH/texture atlas is built once, outside measured intervals.
        let requested = ProcessInfo.processInfo.environment["ADAENGINE_SPONZA_PROFILE_LIGHTING"]
        let presets = requested.flatMap(SponzaRenderPreset.init(rawValue:)).map { [$0] } ?? [.lodRaster, .pathTracing]
        for preset in presets {
            for round in 0..<3 {
                for count in round.isMultiple(of: 2) ? [0, 4, 12] : [12, 4, 0] {
                    motionStart = nil
                    try await app.withWorldAccess {
                        session.move(to: 2)
                        session.apply(preset: preset, lights: count)
                    }
                    if preset == .pathTracing {
                        let deadline = ContinuousClock.now + .seconds(180)
                        while true {
                            let states = tracing.snapshots.values
                            if let failure = states.compactMap(\.failure).first {
                                throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: failure])
                            }
                            if !states.isEmpty && states.allSatisfy({ $0.encodedFrames > 0 && $0.triangles > 0 && $0.lights == count + 1 }) { break }
                            guard ContinuousClock.now < deadline else { throw CocoaError(.executableRuntimeMismatch) }
                            try await Task.sleep(for: .milliseconds(50))
                        }
                    }
                    try await app.withWorldAccess {
                        motion = selected
                        motionOrigin = session.flight.transform
                        motionStart = .now
                        diagnostics.configure(isEnabled: true, capacity: 64)
                        diagnostics.clear()
                    }
                    session.status = "Замер света: \(preset.rawValue) · \(count) источников"
                    try await Task.sleep(for: .seconds(1))
                    let before = tracing.snapshots.mapValues(\.encodedFrames)
                    intervals.removeAll(keepingCapacity: true)
                    last = nil
                    cameraUpdates = 0
                    recording = true
                    try await Task.sleep(for: .seconds(6))
                    recording = false
                    let states = tracing.snapshots
                    guard !intervals.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
                    if preset == .pathTracing {
                        guard !states.isEmpty && states.allSatisfy({ key, value in
                            value.failure == nil && value.encodedFrames > (before[key] ?? 0) && value.lights == count + 1
                        }) else {
                            struct Failure: Encodable {
                                var before: [String: Int]
                                var after: [String: PathTracing3DStatus]
                            }
                            let data = try JSONEncoder().encode(Failure(before: before, after: states))
                            try data.write(to: output.appendingPathExtension("failure.json"), options: .atomic)
                            let reason = "PT frame progress validation failed: \(String(decoding: data, as: UTF8.self))"
                            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: reason])
                        }
                    }
                    let records = try await app.withWorldAccess { diagnostics.records }
                    measurements.append(Measurement(view: "gallery", shadows: true, round: round,
                        width: size[0], height: size[1], publishedIntervalsMilliseconds: intervals, graphRecords: records,
                        motion: selected.rawValue, cameraUpdates: cameraUpdates, preset: preset.rawValue, localLightCount: count,
                        lightStatistics: lights.snapshots, pathTracing: states, pathFramesBefore: before,
                        pathSettings: session.camera?.components[Environment3D.self]?.pathTracing))
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try encoder.encode(measurements).write(to: output, options: .atomic)
                }
            }
        }
        motionStart = nil
        try await app.withWorldAccess {
            diagnostics.configure(isEnabled: false)
            session.pathHighQuality = true
            session.dlssEnabled = true
            session.apply(preset: .pathTracing, lights: 12)
            session.move(to: 2)
        }
        session.status = "Sponza + Ivy · полная сцена / отдельный PT LOD"
        FileHandle.standardOutput.write(Data("SPONZA_PROFILE_READY \(output.path)\n".utf8))
    }

    private func runMeshlets(session: SponzaSession, app: AppWorlds, diagnostics: RenderGraphDiagnostics) async throws {
        let render = app.getSubworldBuilder(by: .renderWorld)
        guard let statistics = render?.getResource(Render3DMeshletStatistics.self) else { throw CocoaError(.featureUnsupported) }
        session.dlssEnabled = false
        session.meshletMapEnabled = false
        session.flyingLightEnabled = false
        session.hiZ = false
        let lodRun = ProcessInfo.processInfo.environment["ADAENGINE_SPONZA_PROFILE_MESHLET_LOD"] == "1"
        session.highResolutionShadows = lodRun
        var measurements: [Measurement] = []
        var measuredSize: [Int]?
        // The outside overview primes all eligible geometry uploads and material variants before timing.
        try await app.withWorldAccess {
            session.meshletMode = .gpu
            session.meshletLODError = lodRun ? 2 : 0
            session.apply(preset: .fullRaster, lights: 0)
            session.move(to: 3)
        }
        session.status = "Прогрев полной геометрии и GPU мешлетов…"
        try await Task.sleep(for: .seconds(3))
        try await app.withWorldAccess {
            session.move(to: 2)
            motion = .rotation
            motionOrigin = session.flight.transform
            motionStart = .now
        }
        // A complete turn warms the partially clipped parts that actually enter the compute path.
        try await Task.sleep(for: .seconds(6))
        for view in [2, 3] {
            for round in 0..<3 {
                let cases: [(mode: MeshletVisibilityMode3D, error: Float)] = lodRun
                    ? [(.gpu, 0), (.gpu, 2), (.gpu, 8)] : [(.disabled, 0), (.cpuReference, 0), (.gpu, 0)]
                for sample in round.isMultiple(of: 2) ? cases : Array(cases.reversed()) {
                    let mode = sample.mode
                    try await app.withWorldAccess {
                        session.meshletMode = mode
                        session.meshletLODError = sample.error
                        session.apply(preset: .fullRaster, lights: 0)
                        session.move(to: view)
                        motion = view == 2 ? .rotation : .stationary
                        motionOrigin = session.flight.transform
                        motionStart = .now
                        diagnostics.configure(isEnabled: true, capacity: 32)
                        diagnostics.clear()
                    }
                    session.status = "Замер мешлетов · \(mode.rawValue) · LOD \(Int(sample.error)) px · \(view == 2 ? "галерея" : "снаружи") · \(round + 1)/3"
                    try await Task.sleep(for: .seconds(1))
                    intervals.removeAll(keepingCapacity: true)
                    last = nil
                    cameraUpdates = 0
                    size = [0, 0]
                    sizeChanged = false
                    recording = true
                    try await Task.sleep(for: .seconds(4))
                    recording = false
                    guard !intervals.isEmpty, !sizeChanged, measuredSize == nil || measuredSize == size else {
                        throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Benchmark requires a constant render size and published frames"])
                    }
                    measuredSize = size
                    // Freeze frame updates only after timing, so statistics and arguments describe one completed frame.
                    let captured = try await app.withExclusiveWorldAccess {
                        let snapshot = statistics.snapshots
                        let actualGPUOrFullyVisible = snapshot.values.contains {
                            $0.gpuDraws > 0 || ($0.candidateMeshlets > 0 && $0.fullyVisibleItems > 0 && $0.fullyVisibleItems == $0.eligibleItems
                                && $0.fallbackReasons["processorUnavailableOrBudget"] == nil)
                        }
                        if mode == .gpu && !actualGPUOrFullyVisible {
                            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "No actual GPU meshlet draws in benchmark"])
                        }
                        if lodRun && sample.error > 0 && !snapshot.values.contains(where: { $0.lodGPUItems > 0 }) {
                            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "No actual adaptive LOD draws in benchmark"])
                        }
                        var submittedIndices: Int?
                        // Explicit benchmark readback AFTER the measured interval; never in ordinary frames.
                        if mode == .gpu, let camera = session.camera,
                            let output = render?.getResource(Meshlet3DState.self)?.output(for: camera.id) {
                            let bytes = try await output.arguments.readData()
                            var total = 0
                            for draw in 0..<output.drawCount {
                                let offset = draw * MemoryLayout<IndexedIndirectArguments>.stride
                                guard offset + 4 <= bytes.count else { throw CocoaError(.fileReadCorruptFile) }
                                let word = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
                                total += Int(word)
                            }
                            submittedIndices = total
                        }
                        return (snapshot, submittedIndices, diagnostics.records)
                    }
                    measurements.append(Measurement(view: view == 2 ? "gallery" : "outside", shadows: true, round: round,
                        width: size[0], height: size[1], publishedIntervalsMilliseconds: intervals, graphRecords: captured.2,
                        motion: motion.rawValue, cameraUpdates: cameraUpdates, preset: session.preset.rawValue, localLightCount: 0,
                        meshlets: captured.0, meshletGPUIndexCount: captured.1, meshletLODPixelError: sample.error,
                        shadowCascadeResolution: session.highResolutionShadows ? 2048 : 1024,
                        localShadowResolution: session.highResolutionShadows ? 1024 : 512,
                        shadowDistance: session.highResolutionShadows ? 80 : 30))
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try encoder.encode(measurements).write(to: output, options: .atomic)
                }
            }
        }
        motionStart = nil
        try await app.withWorldAccess {
            diagnostics.configure(isEnabled: false)
            session.meshletMode = .gpu
            session.meshletLODError = lodRun ? 2 : 0
            session.meshletMapEnabled = true
            session.apply(preset: .fullRaster, lights: 0)
            session.move(to: 2)
        }
        session.status = "Sponza + Ivy · мешлеты\(lodRun ? " + LOD" : "") · полный raster asset"
        FileHandle.standardOutput.write(Data("SPONZA_PROFILE_READY \(output.path)\n".utf8))
    }
}
