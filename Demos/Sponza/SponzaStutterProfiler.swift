import AdaEngine
import Foundation
import SponzaCamera

extension SponzaDemoProfiler {
    struct StutterPhase: Codable {
        var name: String
        var input: String
        var width: Int
        var height: Int
        var sizeChanged: Bool
        var publishedIntervalsMilliseconds: [Double]
        var graphRecords: [RenderGraphFrameRecord]
        var meshlets: [String: Meshlet3DCount]
    }

    func runStutter(session: SponzaSession, app: AppWorlds, diagnostics: RenderGraphDiagnostics) async throws {
        let render = app.getSubworldBuilder(by: .renderWorld)
        let statistics = render?.getResource(Render3DMeshletStatistics.self)
        var captured: [StutterPhase] = []
        session.status = "Sponza + Ivy · запись задержек кадров"
        let cases: [(String, SponzaCameraMotion, Double)] = [
            ("stationary", .stationary, 6), ("rotation-first", .rotation, 12), ("rotation-repeat", .rotation, 12),
            ("translation", .translation, 12), ("LOD-off", .rotation, 6), ("LOD-on", .rotation, 6),
            ("DLSS-off", .rotation, 6), ("DLSS-on", .rotation, 6),
            ("shadows-baseline", .stationary, 4), ("shadows-high", .stationary, 4),
            ("lights-off", .stationary, 4), ("lights-on", .stationary, 4)
        ]
        for (name, movement, seconds) in cases {
            try await app.withWorldAccess {
                motionStart = nil
                session.meshletMode = .gpu
                session.meshletLODError = name == "LOD-off" ? 0 : 2
                session.meshletMapEnabled = false
                session.flyingLightEnabled = false
                session.dlssEnabled = name != "DLSS-off"
                session.highResolutionShadows = name != "shadows-baseline"
                session.apply(preset: .fullRaster, lights: name == "lights-off" ? 0 : 12)
                session.move(to: 2)
                motion = movement
                motionOrigin = session.flight.transform
                motionStart = .now
                diagnostics.configure(isEnabled: true, capacity: 4096)
                diagnostics.clear()
            }
            intervals.removeAll(keepingCapacity: true)
            last = nil
            size = [0, 0]
            sizeChanged = false
            cameraUpdates = 0
            PerformanceStallProbe.mark("begin:\(name)")
            recording = true
            try await Task.sleep(for: .seconds(seconds))
            recording = false
            PerformanceStallProbe.mark("end:\(name)")
            let data = try await app.withExclusiveWorldAccess { (diagnostics.records, statistics?.snapshots ?? [:]) }
            captured.append(.init(name: name, input: movement.rawValue, width: size[0], height: size[1], sizeChanged: sizeChanged,
                                  publishedIntervalsMilliseconds: intervals, graphRecords: data.0, meshlets: data.1))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(captured).write(to: output, options: .atomic)
        }
        try await app.withWorldAccess {
            diagnostics.configure(isEnabled: false)
            motionStart = nil
            session.move(to: 2)
        }
        session.status = "Sponza + Ivy · запись задержек завершена"
        print("SPONZA_STUTTER_READY \(output.path)")
    }
}
