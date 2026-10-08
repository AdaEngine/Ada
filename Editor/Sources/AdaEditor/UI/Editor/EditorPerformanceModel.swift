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
    enum DisplayMode: String, CaseIterable { case overview = "Overview", timeline = "Timeline" }
    enum Presentation: Hashable { case panel, workspace }
    var displayMode: DisplayMode = .overview
    var isExpanded = false
    var recordingDelaySeconds: Double = 0
    var recordingDurationSeconds = 5
    private(set) var scheduledTargetID: String?
    private(set) var scheduledStart: Date?
    private(set) var timeline: EditorPerformanceTimeline?
    @ObservationIgnored private var recordingTask: Task<Void, Never>?
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
    @ObservationIgnored private var presentations: Set<Presentation> = []

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

    func appear(presentation: Presentation = .panel) {
        presentations.insert(presentation)
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
    func disappear(presentation: Presentation = .panel) {
        presentations.remove(presentation)
        guard presentations.isEmpty else { return }
        isVisible = false
        task?.cancel()
        task = nil
        lease = nil
        leasedTargetID = nil
    }
    func selectTarget(_ id: String) {
        cancelScheduledRecording()
        selectedTargetID = id
        selectedCaptureID = nil
        capture = nil
        timeline = nil
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
            timeline = nil
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
                capture = nil
                timeline = nil
            }
            captures = updated
            if let selectedCaptureID, !captures.contains(where: { $0.objectValue?["id"]?.stringValue == selectedCaptureID }) {
                self.selectedCaptureID = nil
                capture = nil
                timeline = nil
            }
            if let selectedCaptureID, capture == nil {
                capture = try profiler.capturePayload(id: selectedCaptureID)
                timeline = EditorPerformanceTimeline(trace: capture?.objectValue?["trace"])
            }
            if let scheduledTargetID, profiler.performance.target(scheduledTargetID)?.isRunning != true {
                cancelScheduledRecording()
                errorMessage = "Scheduled game stopped before recording began."
            }
        } catch { errorMessage = error.localizedDescription }
    }
    var scheduledStatus: String? {
        guard let scheduledStart else { return nil }
        return "Starts in \(max(0, Int(ceil(scheduledStart.timeIntervalSinceNow)))) s"
    }

    func record() {
        guard let profiler, let target, target.isRunning, scheduledTargetID == nil else { return }
        guard recordingDelaySeconds.isFinite, (0...300).contains(recordingDelaySeconds),
              (1...120).contains(recordingDurationSeconds) else {
            errorMessage = "Choose a delay of 0–300 s and a duration of 1–120 s."
            return
        }
        let durationMs = recordingDurationSeconds * 1000
        errorMessage = nil
        if recordingDelaySeconds == 0 {
            startRecording(profiler: profiler, targetID: target.id, durationMs: durationMs)
            return
        }
        let delay = recordingDelaySeconds
        scheduledTargetID = target.id
        scheduledStart = Date().addingTimeInterval(delay)
        recordingTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.scheduledTargetID = nil
            self.scheduledStart = nil
            self.recordingTask = nil
            self.startRecording(profiler: profiler, targetID: target.id, durationMs: durationMs)
        }
    }

    func cancelScheduledRecording() {
        recordingTask?.cancel()
        recordingTask = nil
        scheduledTargetID = nil
        scheduledStart = nil
    }

    private func startRecording(profiler: AdaMCPProfiler, targetID: String, durationMs: Int) {
        guard profiler.performance.target(targetID)?.isRunning == true else {
            errorMessage = "Scheduled game stopped before recording began."
            return
        }
        do {
            _ = try profiler.startCapture(arguments: ["targetId": .string(targetID), "durationMs": .int(durationMs)])
            selectedCaptureID = nil
            capture = nil
            timeline = nil
            displayMode = .timeline
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
        timeline = nil
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
