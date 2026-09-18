import AdaEngine
import AdaMCPCore
import Foundation
import MCP
import Observation

@MainActor
final class EditorGamePerformanceSession {
    private(set) var targetID: String?
    private weak var profiler: AdaMCPProfiler?

    func attach(_ app: AppWorlds, title: String) {
        stop()
        guard let resource = AppWorldsSession.current?.main.getResource(AdaMCPProfilerResource.self) else {
            return
        }
        profiler = resource.profiler
        targetID = resource.profiler.performance.register(title: title)
        app.main.insertResource(PhysicsPerformanceMetrics())
        app.profilingTargetID = targetID
        if let targetID {
            EditorPhysicsPerformanceRegistry.shared.register(app, targetID: targetID)
        }
    }

    func stop() {
        guard let targetID else {
            return
        }
        EditorPhysicsPerformanceRegistry.shared.stop(targetID: targetID)
        do { try profiler?.stopTarget(targetID) } catch {
            RuntimeLogStore.shared.append(level: "error", label: "Performance", message: "Performance capture failed: \(error.localizedDescription)")
        }
        self.targetID = nil
    }
}

@MainActor
private final class EditorPhysicsPerformanceRegistry {
    private final class Entry {
        weak var app: AppWorlds?
        var lastSnapshots: [PhysicsPerformanceSnapshot]

        init(app: AppWorlds) {
            self.app = app
            self.lastSnapshots = []
        }
    }

    static let shared = EditorPhysicsPerformanceRegistry()
    private var entries: [String: Entry] = [:]
    private var stoppedTargetIDs: [String] = []

    func register(_ app: AppWorlds, targetID: String) {
        entries[targetID] = Entry(app: app)
        stoppedTargetIDs.removeAll { $0 == targetID }
    }

    func snapshots(targetID: String?) -> [PhysicsPerformanceSnapshot] {
        guard let targetID, let entry = entries[targetID] else {
            return []
        }
        if let snapshots = entry.app?.main.getResource(PhysicsPerformanceMetrics.self)?.snapshots,
            !snapshots.isEmpty {
            entry.lastSnapshots = snapshots
        }
        return entry.lastSnapshots
    }

    func stop(targetID: String) {
        guard let entry = entries[targetID] else {
            return
        }
        if let snapshots = entry.app?.main.getResource(PhysicsPerformanceMetrics.self)?.snapshots,
            !snapshots.isEmpty {
            entry.lastSnapshots = snapshots
        }
        entry.app = nil
        stoppedTargetIDs.append(targetID)
        while stoppedTargetIDs.count > 8 {
            entries[stoppedTargetIDs.removeFirst()] = nil
        }
    }
}

@Observable
@MainActor
final class EditorPerformanceModel {
    var targets: [AdaMCPPerformanceTarget] = []
    var target: AdaMCPPerformanceTarget?
    var selectedTargetID: String?
    var selectedCaptureID: String?
    var captures: [Value] = []
    var activeCapture: Value?
    var capture: Value?
    var physicsSnapshots: [PhysicsPerformanceSnapshot] = []
    var errorMessage: String?
    var isVisible = false
    @ObservationIgnored private var profiler: AdaMCPProfiler?
    @ObservationIgnored private var lease: AdaMCPTraceLease?
    @ObservationIgnored private var leasedTargetID: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    var samples: [AdaMCPPerformanceSample] { target?.samples ?? [] }
    var latest: AdaMCPPerformanceSample? { samples.last }
    var status: String {
        if profiler == nil {
            return "Profiler unavailable"
        }
        if target == nil {
            return "Run a scene to measure performance"
        }
        if target?.isRunning == false {
            return "Stopped"
        }
        return lease == nil ? "No data" : "Live · 4 Hz"
    }
    var systems: [AdaMCPPerformanceHotspot] { latest?.systems ?? [] }
    var renderNodes: [AdaMCPPerformanceHotspot] { latest?.renderNodes ?? [] }

    func appear() {
        guard !isVisible else {
            return
        }
        isVisible = true
        refresh()
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                self?.refresh()
            }
        }
    }
    func disappear() {
        isVisible = false
        task?.cancel()
        task = nil
        lease = nil
        leasedTargetID = nil
    }
    func selectTarget(_ id: String) {
        selectedTargetID = id
        selectedCaptureID = nil
        capture = nil
        refresh()
    }
    func refresh() {
        profiler = AppWorldsSession.current?.main.getResource(AdaMCPProfilerResource.self)?.profiler
        guard let profiler else {
            return
        }
        targets = profiler.performance.sessions
        // Follow new runs automatically until the user explicitly chooses a session.
        let id = selectedTargetID ?? targets.last?.id
        if target?.id != id {
            selectedCaptureID = nil
            capture = nil
        }
        target = id.flatMap { profiler.performance.target($0) }
        physicsSnapshots = EditorPhysicsPerformanceRegistry.shared.snapshots(targetID: id)
        if leasedTargetID != id || target?.isRunning != true || !isVisible {
            lease = nil
            leasedTargetID = nil
        }
        do {
            if isVisible, lease == nil, let target, target.isRunning {
                lease = try profiler.performance.subscribe(targetID: target.id)
                leasedTargetID = target.id
            }
            let list = try profiler.captureListPayload().objectValue
            activeCapture = list?["activeCapture"] == .null ? nil : list?["activeCapture"]
            let updated = list?["captures"]?.arrayValue ?? []
            if updated.last?.objectValue?["id"] != captures.last?.objectValue?["id"],
                let last = updated.last?.objectValue,
                last["targetId"]?.stringValue == target?.id {
                selectedCaptureID = last["id"]?.stringValue
            }
            captures = updated
            if let selectedCaptureID, !captures.contains(where: { $0.objectValue?["id"]?.stringValue == selectedCaptureID }) {
                self.selectedCaptureID = nil
                capture = nil
            }
            if let selectedCaptureID {
                capture = try profiler.capturePayload(id: selectedCaptureID)
            }
        } catch { errorMessage = error.localizedDescription }
    }
    func record() {
        guard let profiler, let target else {
            return
        }
        do {
            errorMessage = nil
            _ = try profiler.startCapture(arguments: ["targetId": .string(target.id), "durationMs": .int(5000)])
            selectedCaptureID = nil
            capture = nil
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }
    func stopRecording() {
        guard let profiler else {
            return
        }
        do {
            errorMessage = nil
            let result = try profiler.stopCapture(arguments: [:])
            selectedCaptureID = result.objectValue?["manifest"]?.objectValue?["id"]?.stringValue
            refresh()
        } catch { errorMessage = error.localizedDescription }
    }
    func selectCapture(_ id: String?) {
        selectedCaptureID = id
        capture = nil
        refresh()
    }
    func exportCapture() {
        guard let trace = capture?.objectValue?["trace"], let selectedCaptureID else {
            return
        }
        do {
            let data = try JSONEncoder().encode(trace)
            EditorPerformanceExport.save(data, name: "performance-\(selectedCaptureID).json") { [weak self] error in
                self?.errorMessage = error
            }
        } catch { errorMessage = error.localizedDescription }
    }
}
