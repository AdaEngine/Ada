import AdaEngine
import AdaMCPCore
import Foundation
import MCP

struct EditorPerformancePanel: View {
    let model: EditorPerformanceModel
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 12) {
                    toolbar
                    if let error = model.errorMessage {
                        HStack {
                            Text(error).foregroundColor(theme.editorColors.purple)
                            action("Retry") {
                                model.errorMessage = nil
                                model.refresh()
                            }
                        }
                    }
                    if model.target != nil {
                        if geometry.size.width >= 700 {
                            HStack(spacing: 12) {
                                rateChart
                                timeChart
                                memoryChart
                                entityChart
                            }
                        } else {
                            rateChart
                            timeChart
                            memoryChart
                            entityChart
                        }
                        if !model.physicsSnapshots.isEmpty {
                            physicsProfiles
                        }
                        if let capture = model.capture?.objectValue {
                            captureSummary(capture)
                            hotspots("ECS systems · capture", values: captureRows(capture, key: "systemHotspots"))
                            hotspots("Render nodes · CPU · capture", values: captureRows(capture, key: "renderNodeHotspots"))
                        } else {
                            hotspots("ECS systems · latest sample", values: liveRows(model.systems))
                            hotspots("Render nodes · CPU · latest sample", values: liveRows(model.renderNodes))
                        }
                    } else {
                        Text("Run a scene or an AdaScript project inside AdaEditor to begin.")
                            .foregroundColor(theme.editorColors.muted)
                    }
                }
                .font(.system(size: 12))
                .padding(12)
                .frame(width: max(0, geometry.size.width - 4), alignment: .topLeading)
            }
        }
        .accessibilityIdentifier("AdaEditor.Performance")
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(model.target?.title ?? "Performance")
                    .foregroundColor(theme.editorColors.text)
                    .contextMenu(opensOnPrimaryAction: true) {
                        ForEach(model.targets) { target in
                            ContextMenuOption(target.title + (target.isRunning ? "" : " · Stopped"), isSelected: target.id == model.target?.id) {
                                model.selectTarget(target.id)
                            }
                        }
                    }
                Spacer()
                Text(model.status).foregroundColor(theme.editorColors.muted)
            }
            HStack(spacing: 8) {
                if model.activeCapture != nil {
                    action("Stop recording") { model.stopRecording() }
                    Text("Recording…").foregroundColor(theme.editorColors.purple)
                } else if model.target?.isRunning == true {
                    action("Record 5 s") { model.record() }
                }
                Text(model.selectedCaptureID == nil ? "Live ▾" : "Capture ▾")
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(theme.editorColors.surface)
                    .contextMenu(opensOnPrimaryAction: true) {
                        ContextMenuOption("Live", isSelected: model.selectedCaptureID == nil) { model.selectCapture(nil) }
                        ForEach(Array(model.captures.indices), id: \.self) { index in
                            let value = model.captures[index].objectValue
                            let id = value?["id"]?.stringValue ?? ""
                            ContextMenuOption("\(index + 1). \(value?["startedAt"]?.stringValue ?? id)", isSelected: model.selectedCaptureID == id) {
                                model.selectCapture(id)
                            }
                        }
                    }
                if model.capture?.objectValue?["trace"] != nil {
                    action("Export JSON") { model.exportCapture() }
                }
                Spacer()
            }
        }
    }

    private var rateChart: some View {
        chart("Game updates / s", value: number(model.latest?.updatesPerSecond), key: { $0.updatesPerSecond })
    }
    private var timeChart: some View {
        chart(
            "CPU update · ms",
            value: "\(number(model.latest?.update?.meanMs)) · p95 \(number(model.latest?.update?.p95Ms))",
            key: { $0.update?.meanMs },
            secondary: { $0.update?.p95Ms }
        )
    }
    private var memoryChart: some View {
        chart(
            "AdaEditor process · MiB",
            value: number(model.latest?.processMemoryBytes.map { Double($0) / 1_048_576 }),
            key: { $0.processMemoryBytes.map { Double($0) / 1_048_576 } }
        )
    }
    private var entityChart: some View {
        chart("Game entities", value: model.latest?.entityCount.map(String.init) ?? "No data", key: { $0.entityCount.map(Double.init) })
    }

    private var physicsProfiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Physics")
                .foregroundColor(theme.editorColors.text)
            ForEach(model.physicsSnapshots) { snapshot in
                physicsProfile(snapshot)
            }
        }
    }

    private func physicsProfile(_ snapshot: PhysicsPerformanceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(snapshot.dimension == .twoD ? "Box2D" : "Box3D")
                    .foregroundColor(theme.editorColors.text)
                Text("step \(number(snapshot.step?.currentMilliseconds)) ms")
                    .foregroundColor(theme.editorColors.blue)
                Spacer()
                Text("\(snapshot.phases.count) phases · \(snapshot.stepCount) steps")
                    .foregroundColor(theme.editorColors.muted)
            }
            Text(physicsCounters(snapshot.counters))
                .foregroundColor(theme.editorColors.muted)
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 5) {
                    physicsHeader
                    ForEach(visiblePhysicsPhases(snapshot)) { phase in
                        physicsRow(phase, stepMilliseconds: snapshot.step?.currentMilliseconds ?? 0)
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface))
        .accessibilityIdentifier("AdaEditor.Performance.Physics.\(snapshot.dimension.rawValue)")
    }

    private var physicsHeader: some View {
        HStack(spacing: 8) {
            Text("Phase").frame(width: 190, alignment: .leading)
            ForEach(["Now ms", "Avg ms", "Max ms"], id: \.self) { label in
                Text(label).frame(width: 72, alignment: .trailing)
            }
            Text("% step").frame(width: 132, alignment: .leading)
        }
        .foregroundColor(theme.editorColors.muted)
    }

    private func physicsRow(_ sample: PhysicsPerformancePhaseSample, stepMilliseconds: Double) -> some View {
        let ratio = stepMilliseconds > 0 ? min(1, sample.currentMilliseconds / stepMilliseconds) : 0
        return HStack(spacing: 8) {
            Text(sample.phase.title)
                .foregroundColor(physicsColor(sample.phase))
                .frame(width: 190, alignment: .leading)
            Text(number(sample.currentMilliseconds)).frame(width: 72, alignment: .trailing)
            Text(number(sample.averageMilliseconds)).frame(width: 72, alignment: .trailing)
            Text(number(sample.maximumMilliseconds)).frame(width: 72, alignment: .trailing)
            ZStack(anchor: .leading) {
                RoundedRectangleShape(cornerRadius: 2)
                    .fill(theme.editorColors.surfaceElevated)
                    .frame(width: 132, height: 12)
                RoundedRectangleShape(cornerRadius: 2)
                    .fill(physicsColor(sample.phase).opacity(0.75))
                    .frame(width: Float(ratio) * 132, height: 12)
            }
        }
        .foregroundColor(theme.editorColors.text)
    }

    private func visiblePhysicsPhases(_ snapshot: PhysicsPerformanceSnapshot) -> [PhysicsPerformancePhaseSample] {
        snapshot.phases.filter {
            $0.currentMilliseconds > 0 || [.step, .pairs, .collide, .solve].contains($0.phase)
        }
    }

    private func physicsColor(_ phase: PhysicsPerformancePhase) -> Color {
        switch phase {
        case .step: theme.editorColors.blue
        case .pairs: theme.editorColors.text
        case .collide: theme.editorColors.purple
        case .solve: .green
        default: theme.editorColors.muted
        }
    }

    private func physicsCounters(_ counters: PhysicsPerformanceCounters) -> String {
        "Bodies \(counters.bodyCount) · Shapes \(counters.shapeCount) · Contacts \(counters.contactCount) · Islands \(counters.islandCount) · Tasks \(counters.taskCount)"
    }

    private func chart(
        _ title: String,
        value: String,
        key: @escaping (AdaMCPPerformanceSample) -> Double?,
        secondary: ((AdaMCPPerformanceSample) -> Double?)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).foregroundColor(theme.editorColors.muted)
            Text(value).foregroundColor(theme.editorColors.text)
            EditorPerformanceChart(
                samples: model.samples,
                value: key,
                secondary: secondary,
                color: theme.editorColors.blue,
                secondaryColor: theme.editorColors.purple
            )
            .frame(height: 46)
        }
        .padding(8)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface))
    }

    private func captureSummary(_ capture: [String: Value]) -> some View {
        let summary = capture["summary"]?.objectValue
        let times = summary?["frameTime"]?.objectValue
        let manifest = capture["manifest"]?.objectValue
        return VStack(alignment: .leading, spacing: 5) {
            Text("Capture · \(number(manifest?["durationMs"]?.doubleValue.map { $0 / 1000 })) s · \(summary?["frameCount"]?.intValue ?? 0) updates")
            Text("Update rate \(number(summary?["updateRateHz"]?.doubleValue)) / s · CPU mean \(number(times?["meanMs"]?.doubleValue)) ms · p95 \(number(times?["p95Ms"]?.doubleValue)) ms")
            if let error = manifest?["error"]?.stringValue {
                Text(error).foregroundColor(theme.editorColors.purple)
            }
        }
        .foregroundColor(theme.editorColors.text)
    }

    private struct Row: Identifiable {
        var id: String { name }
        let name: String
        let count: Int
        let mean: Double
        let p95: Double
        let max: Double
        let total: Double
        var sampled = false
    }
    private func liveRows(_ values: [AdaMCPPerformanceHotspot]) -> [Row] {
        values.map {
            .init(
                name: $0.name,
                count: $0.statistics.count,
                mean: $0.statistics.meanMs,
                p95: $0.statistics.p95Ms,
                max: $0.statistics.maxMs,
                total: $0.statistics.totalMs,
                sampled: $0.statistics.sampledPercentile
            )
        }
    }
    private func captureRows(_ capture: [String: Value], key: String) -> [Row] {
        let summary: [String: Value] = capture["summary"]?.objectValue ?? [:]
        let values: [Value] = summary[key]?.arrayValue ?? []
        return values.compactMap { value -> Row? in
            guard let row = value.objectValue, let name = row["name"]?.stringValue else {
                return nil
            }
            let count = row["count"]?.intValue ?? 0
            let mean = row["meanMs"]?.doubleValue ?? 0
            let p95 = row["p95Ms"]?.doubleValue ?? 0
            let maximum = row["maxMs"]?.doubleValue ?? 0
            let total = row["totalMs"]?.doubleValue ?? 0
            return Row(name: name, count: count, mean: mean, p95: p95, max: maximum, total: total)
        }
    }

    private func hotspots(_ title: String, values: [Row]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).foregroundColor(theme.editorColors.text)
            if values.isEmpty {
                Text("No data").foregroundColor(theme.editorColors.muted)
            }
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 5) {
                    hotspotHeader
                    ForEach(values) { row in
                        hotspotRow(row)
                    }
                }
            }
        }
    }
    private var hotspotHeader: some View {
        HStack(spacing: 8) {
            Text("Name").frame(width: 240, alignment: .leading)
            ForEach(["Calls", "Mean ms", "p95 ms", "Max ms", "Total ms"], id: \.self) { label in
                Text(label).frame(width: 78, alignment: .trailing)
            }
        }
        .foregroundColor(theme.editorColors.muted)
    }
    private func hotspotRow(_ row: Row) -> some View {
        HStack(spacing: 8) {
            Text(row.name).lineLimit(1).frame(width: 240, alignment: .leading)
            HStack(spacing: 8) {
                Text(String(row.count)).frame(width: 78, alignment: .trailing)
                Text(number(row.mean)).frame(width: 78, alignment: .trailing)
                Text((row.sampled ? "≈" : "") + number(row.p95)).frame(width: 78, alignment: .trailing)
                Text(number(row.max)).frame(width: 78, alignment: .trailing)
                Text(number(row.total)).frame(width: 78, alignment: .trailing)
            }
        }
        .foregroundColor(theme.editorColors.text)
    }
    private func number(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "No data" }
    private func action(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).foregroundColor(theme.editorColors.blue).padding(.horizontal, 8).frame(height: 26)
                .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.blue.opacity(0.12)))
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.Performance.\(title)")
    }
}

private struct EditorPerformanceChart: View {
    let samples: [AdaMCPPerformanceSample]
    let value: (AdaMCPPerformanceSample) -> Double?
    let secondary: ((AdaMCPPerformanceSample) -> Double?)?
    let color: Color
    let secondaryColor: Color

    var body: some View {
        Canvas { context, size in
            let end = samples.last?.timestamp ?? 0
            let maximum = max(1, samples.compactMap(value).max() ?? 0, samples.compactMap { secondary?($0) }.max() ?? 0)
            func path(_ read: (AdaMCPPerformanceSample) -> Double?) -> Path {
                var path = Path()
                var previous: Double?
                for sample in samples {
                    guard let value = read(sample), value.isFinite else {
                        previous = nil
                        continue
                    }
                    let point = Vector2(
                        Float((sample.timestamp - end + 60) / 60) * size.width,
                        size.height - Float(value / maximum) * (size.height - 2)
                    )
                    if let previous, sample.timestamp - previous < 0.75 {
                        path.addLine(to: point)
                    } else {
                        path.move(to: point)
                    }
                    previous = sample.timestamp
                }
                return path
            }
            context.stroke(path(value), with: color, style: StrokeStyle(lineWidth: 1.5))
            if let secondary {
                context.stroke(path(secondary), with: secondaryColor, style: StrokeStyle(lineWidth: 1))
            }
        }
    }
}
