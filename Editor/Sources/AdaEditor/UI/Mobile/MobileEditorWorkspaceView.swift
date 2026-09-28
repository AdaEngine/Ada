#if os(iOS)
@_spi(AdaEngine) import AdaEngine
import AdaUtils
import Darwin

struct MobileEditorWorkspaceView: View {
    @Environment(\.theme) private var theme
    let project: MobileEditorProject
    @Binding var selection: MobileEditorWorkspaceTab
    @Binding var promptDraft: String
    @Binding var changeRequest: String
    @Binding var isMarkingScene: Bool
    let pendingAttachmentNames: [String]
    let chatEvents: [EditorAgentEvent]
    let agentStatus: String?
    let isAgentRunning: Bool
    let agentActivityState: EditorAgentActivityState
    let agentActivityID: String?
    let playArtifact: EditorAdaScriptProjectBuildArtifact?
    let preparePlay: () -> Void
    let onOpenFile: (String) -> Void
    let submitPrompt: () -> Void
    let showReview: () -> Void
    let goBack: () -> Void
    let pickFiles: () -> Void
    let pickPhotos: () -> Void

    var body: some View {
        ZStack(anchor: .bottom) {
            activeContent
            LiquidGlassTabBar(selectedTab: selection, onSelect: selectTab)
                .padding(.bottom, 20)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .mask(RectangleShape())
        .background(theme.editorColors.background)
        .overlay {
            EditorAgentActivityOverlay(state: agentActivityState, activityID: agentActivityID)
        }
    }

    @ViewBuilder
    private var activeContent: some View {
        switch selection {
        case .build:
            MobileEditorBuildScreen(
                project: project,
                promptDraft: _promptDraft,
                attachmentNames: pendingAttachmentNames,
                chatEvents: chatEvents,
                agentStatus: agentStatus,
                isAgentRunning: isAgentRunning,
                submit: submitPrompt,
                showTemplates: goBack,
                pickFiles: pickFiles,
                pickPhotos: pickPhotos
            )
        case .files:
            MobileEditorFilesScreen(project: project, onOpenFile: onOpenFile)
        case .play:
            if project.isExample {
                MobileEditorPreviewScreen(
                    changeRequest: _changeRequest,
                    isMarkingScene: _isMarkingScene,
                    showReview: showReview
                )
            } else if let playArtifact, let runtimeView = try? EditorAdaScriptProjectRuntimeView(artifact: playArtifact) {
                ZStack {
                    runtimeView
                    if playArtifact.report.systemCount == 0,
                       (playArtifact.sceneModel?.entities.count ?? 0) <= 1 {
                        Text("Create your first scene in Build")
                            .font(MobileEditorFont.font(size: 15))
                            .foregroundColor(theme.editorColors.muted)
                            .allowsHitTesting(false)
                    }
                }
            } else {
                MobileEditorPlayEmptyScreen(message: agentStatus) {
                    selection = .build
                }
            }
        }
    }

    private func selectTab(_ tab: MobileEditorWorkspaceTab) {
        if tab == .play, selection != .play {
            preparePlay()
        }
        selection = tab
    }
}

private struct LiquidGlassTabBar: View {
    @Environment(\.theme) private var theme
    let selectedTab: MobileEditorWorkspaceTab
    let onSelect: (MobileEditorWorkspaceTab) -> Void
    @State private var isDragging = false
    @State private var dragOffset: Float = 0
    @State private var edgePull: Float = 0
    @State private var dragOriginIndex = 0
    @State private var selectorRelease = 0
    @State private var glassPhase: Float = 0
    @State private var lensPhase: Float = 0
    @State private var glassGeneration = 0
    @State private var selectorVelocity: Float = 0
    @State private var lastDragSample: (position: Float, time: ContinuousClock.Instant)?
    @State private var lastVelocitySample: ContinuousClock.Instant?
    @State private var velocityDecayTask: Task<Void, Never>?

    private let tabWidth: Float = 76
    private let tabSpacing: Float = 2
    private let selectorInset: Float = 5
    private let activeLensWidth: Float = 104
    private let activeLensHeight: Float = 90
    private let edgeWidthStretch: Float = 0.14
    private let edgePullLimit: Float = 32
    private let tabs: [MobileEditorWorkspaceTab] = [.build, .files, .play]

    private var barWidth: Float {
        selectorInset * 2 + Float(tabs.count) * tabWidth + Float(max(0, tabs.count - 1)) * tabSpacing
    }

    private var selectedIndex: Int {
        tabs.firstIndex(of: selectedTab) ?? 0
    }

    private var selectorCenterX: Float {
        let index = isDragging ? dragOriginIndex : selectedIndex
        return selectorInset + Float(index) * (tabWidth + tabSpacing) + tabWidth * 0.5 + (isDragging ? dragOffset : 0)
    }

    private var edgeStretch: Float {
        min(abs(edgePull) / 36, 1) * glassPhase
    }

    private var edgeStretchOffset: Float {
        let lensWidth = tabWidth + (activeLensWidth - tabWidth) * lensPhase
        let extraWidth = lensWidth * edgeWidthStretch * edgeStretch
        return (edgePull < 0 ? -1 : 1) * extraWidth * 0.5 + edgePull * 0.10
    }

    private var selectorCompression: Float {
        min(max((selectorVelocity - 250) / 1_250, 0), 1)
    }

    private var activeLensGlass: Glass {
        Glass.clear
            .blurRadius(1)
            .glassTintStrength(0.12)
            .edgeShadowStrength(0.20)
            .glassThickness(48)
            .refractiveIndex(1.28)
            .dispersionStrength(0.90)
            .fresnelIntensity(0.98)
            .glareIntensity(0.92)
            .tint(Color.white.opacity(0.04))
            .interactive(false)
    }

    private func selectorGlass(at phase: Float) -> Glass {
        let idle = Glass.regular
        let active = activeLensGlass
        func mix(_ start: Float, _ end: Float) -> Float { start + (end - start) * phase }

        var glass = idle
        glass.blurRadius = mix(idle.blurRadius, active.blurRadius)
        glass.glassTintStrength = mix(idle.glassTintStrength, active.glassTintStrength)
        glass.edgeShadowStrength = mix(idle.edgeShadowStrength, active.edgeShadowStrength)
        glass.cornerRoundnessExponent = mix(idle.cornerRoundnessExponent, active.cornerRoundnessExponent)
        glass.glassThickness = mix(idle.glassThickness, active.glassThickness)
        glass.refractiveIndex = mix(idle.refractiveIndex, active.refractiveIndex)
        glass.dispersionStrength = mix(idle.dispersionStrength, active.dispersionStrength)
        glass.fresnelDistanceRange = mix(idle.fresnelDistanceRange, active.fresnelDistanceRange)
        glass.fresnelIntensity = mix(idle.fresnelIntensity, active.fresnelIntensity)
        glass.fresnelEdgeSharpness = mix(idle.fresnelEdgeSharpness, active.fresnelEdgeSharpness)
        glass.glareDistanceRange = mix(idle.glareDistanceRange, active.glareDistanceRange)
        glass.glareAngleConvergence = mix(idle.glareAngleConvergence, active.glareAngleConvergence)
        glass.glareOppositeSideBias = mix(idle.glareOppositeSideBias, active.glareOppositeSideBias)
        glass.glareIntensity = mix(idle.glareIntensity, active.glareIntensity)
        glass.glareEdgeSharpness = mix(idle.glareEdgeSharpness, active.glareEdgeSharpness)
        glass.glareDirectionOffset = mix(idle.glareDirectionOffset, active.glareDirectionOffset)
        glass.tintColor = Color.white.opacity(mix(0.035, 0.04))
        return glass.interactive(false)
    }

    var body: some View {
        ZStack(anchor: .leading) {
            CapsuleShape()
                .fill(theme.editorColors.surface)
                .frame(width: barWidth, height: 68)
                .glassEffect(.regular.tint(Color.white.opacity(0.035)), in: .capsule)
                .overlay {
                    CapsuleShape().stroke(theme.editorColors.border, lineWidth: 1)
                        .allowsHitTesting(false)
                }
                .allowsHitTesting(false)

            HStack(spacing: tabSpacing) {
                ForEach(tabs.indices, id: \.self) { index in
                    tab(tabs[index], index: index)
                }
            }
            .padding(selectorInset)

            floatingSelector

            HStack(spacing: tabSpacing) {
                ForEach(tabs.indices, id: \.self) { index in
                    tabLabel(tabs[index], index: index)
                        .frame(width: tabWidth, height: 58)
                }
            }
            .padding(selectorInset)
            .opacity(1 - glassPhase)
            .allowsHitTesting(false)
        }
        .frame(width: barWidth, height: 68)
        .onChange(of: selectedIndex) { oldIndex, newIndex in
            // The position animation starts fastest, then eases into the selected tab.
            let distance = Float(abs(newIndex - oldIndex)) * (tabWidth + tabSpacing)
            let generation = glassGeneration
            Task { @MainActor in
                // AdaUI delivers onChange during reconciliation; defer state mutation.
                await Task.yield()
                guard generation == glassGeneration else { return }
                recordSelectorVelocity(distance * 4.7 / 0.32)
            }
        }
        .onDisappear {
            glassGeneration &+= 1
            velocityDecayTask?.cancel()
            velocityDecayTask = nil
            selectorVelocity = 0
            lastDragSample = nil
            lastVelocitySample = nil
        }
    }

    private func tabColor(for index: Int) -> Color {
        index == selectedIndex ? theme.editorColors.text : theme.editorColors.muted
    }

    private var floatingSelector: some View {
        ZStack {
            CapsuleShape()
                .fill(theme.editorColors.border.opacity(0.65 * (1 - glassPhase)))
            CapsuleShape()
                .fill(Color.white.opacity(0.03 * glassPhase))
        }
        .frame(width: activeLensWidth, height: activeLensHeight)
        .glassEffect(selectorGlass(at: glassPhase), in: .capsule)
        .scaleEffect(Vector2(
            x: (tabWidth + (activeLensWidth - tabWidth) * lensPhase) / activeLensWidth
                * (1 + edgeWidthStretch * edgeStretch) * (1 - 0.20 * selectorCompression),
            y: (58 + (activeLensHeight - 58) * lensPhase) / activeLensHeight
                * (1 - 0.06 * edgeStretch) * (1 - 0.10 * selectorCompression)
        ))
        .animation(Animation.easeInOut(duration: 0.08), value: selectorCompression)
        .offset(x: selectorCenterX + edgeStretchOffset - activeLensWidth * 0.5)
        .animation(Animation(MobileTabBounce()), value: selectedIndex)
        .animation(Animation(MobileTabBounce()), value: selectorRelease)
        .allowsHitTesting(false)
    }

    private func transitionGlass(to target: Float) {
        let startGlass = glassPhase
        let startLens = lensPhase
        glassGeneration &+= 1
        let generation = glassGeneration
        Task { @MainActor in
            for step in 1...11 {
                try? await Task.sleep(for: .milliseconds(16))
                guard glassGeneration == generation else { return }
                let fraction = Float(step) / 11
                let remaining = 1 - fraction
                let glassProgress = 1 - remaining * remaining * remaining
                let springProgress = 1 - Darwin.expf(-3 * fraction)
                    * (Darwin.cosf(6 * fraction) + 0.5 * Darwin.sinf(6 * fraction))
                glassPhase = startGlass + (target - startGlass) * glassProgress
                lensPhase = startLens + (target - startLens) * springProgress
            }
            glassPhase = target
            lensPhase = target
        }
    }

    private func tabLabel(_ kind: MobileEditorWorkspaceTab, index: Int) -> some View {
        LiquidGlassTabLabel(
            symbol: kind.symbol,
            title: kind.title,
            color: tabColor(for: index),
            isSelected: index == selectedIndex
        )
    }

    @ViewBuilder
    private func tab(_ kind: MobileEditorWorkspaceTab, index: Int) -> some View {
        if index == selectedIndex {
            tabLabel(kind, index: index)
                .frame(width: tabWidth, height: 58)
                .gesture(
                    LongPressGesture(minimumDuration: 0.22)
                        .onEnded { beginDrag(from: index) }
                        .simultaneously(with:
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in updateDrag(value, from: index) }
                                .onEnded { value in finishDrag(value, from: index) }
                        )
                )
                .accessibilityIdentifier("AdaEditor.Mobile.Tab.\(kind.title)")
        } else {
            Button {
                onSelect(kind)
            } label: {
                tabLabel(kind, index: index)
                    .frame(width: tabWidth, height: 58)
            }
            .buttonStyle(DefaultButtonStyle())
            .accessibilityIdentifier("AdaEditor.Mobile.Tab.\(kind.title)")
        }
    }

    private func beginDrag(from index: Int) {
        guard !isDragging else { return }
        dragOriginIndex = index
        dragOffset = 0
        edgePull = 0
        isDragging = true
        lastDragSample = (selectorCenterX + edgeStretchOffset, .now)
        transitionGlass(to: 1)
    }

    private func updateDrag(_ value: DragGesture.Value, from index: Int) {
        if !isDragging {
            guard index == selectedIndex, abs(value.translation.width) > 3 else { return }
            beginDrag(from: index)
        }
        guard dragOriginIndex == index else { return }

        let step = tabWidth + tabSpacing
        let minimumOffset = -Float(dragOriginIndex) * step
        let maximumOffset = Float(tabs.count - 1 - dragOriginIndex) * step
        dragOffset = min(maximumOffset, max(minimumOffset, value.translation.width))
        let overflow = value.translation.width - dragOffset
        edgePull = overflow * edgePullLimit / (edgePullLimit + abs(overflow))

        let now = ContinuousClock.now
        let position = selectorCenterX + edgeStretchOffset
        if let sample = lastDragSample {
            let elapsed = sample.time.duration(to: now).components
            let seconds = Float(elapsed.seconds) + Float(elapsed.attoseconds) * 1e-18
            guard seconds >= 0.004 else { return }
            let speed = abs(position - sample.position) / seconds
            recordSelectorVelocity(selectorVelocity * 0.25 + speed * 0.75)
        }
        lastDragSample = (position, now)
    }

    private func recordSelectorVelocity(_ speed: Float) {
        selectorVelocity = min(speed, 3_000)
        lastVelocitySample = .now
        guard velocityDecayTask == nil else { return }

        velocityDecayTask = Task { @MainActor in
            var previousTick = ContinuousClock.now
            while !Task.isCancelled, selectorVelocity > 1 {
                do {
                    try await Task.sleep(for: .milliseconds(16))
                } catch {
                    return
                }
                let now = ContinuousClock.now
                if let sample = lastVelocitySample, sample.duration(to: now) >= .milliseconds(40) {
                    let elapsed = previousTick.duration(to: now).components
                    let seconds = Float(elapsed.seconds) + Float(elapsed.attoseconds) * 1e-18
                    selectorVelocity *= Darwin.expf(-14 * seconds)
                }
                previousTick = now
            }
            selectorVelocity = 0
            velocityDecayTask = nil
        }
    }

    private func finishDrag(_ value: DragGesture.Value, from index: Int) {
        updateDrag(value, from: index)
        if isDragging, dragOriginIndex == index {
            let step = tabWidth + tabSpacing
            let targetIndex = min(tabs.count - 1, max(0, index + Int((dragOffset / step).rounded())))
            isDragging = false
            dragOffset = 0
            edgePull = 0
            lastDragSample = nil
            transitionGlass(to: 0)
            selectorRelease += 1
            onSelect(tabs[targetIndex])
            return
        }

        // A tab change can rebuild the style during touch delivery. Its old gesture
        // may then receive the same release again; only a stationary release is a tap.
        guard abs(value.translation.width) < 8, abs(value.translation.height) < 8 else { return }
        onSelect(tabs[index])
    }
}

private struct LiquidGlassTabLabel: View {
    let symbol: String
    let title: String
    let color: Color
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 3) {
            Text(symbol)
                .font(AdaEditorMaterialSymbolFont.font(size: 22))
                .frame(width: 22, height: 22)
            Text(title)
                .font(MobileEditorFont.font(size: 11))
        }
        .foregroundColor(color)
        .scaleEffect(Vector2(x: isSelected ? 1.12 : 1, y: isSelected ? 1.12 : 1))
        .animation(Animation(MobileTabBounce()), value: isSelected)
    }
}

private extension MobileEditorWorkspaceTab {
    var title: String {
        switch self {
        case .build: "Build"
        case .files: "Files"
        case .play: "Play"
        }
    }

    var symbol: String {
        switch self {
        case .build: "\u{E86F}"
        case .files: "\u{E2C7}"
        case .play: "\u{E037}"
        }
    }

}

private struct MobileTabBounce: CustomAnimation {
    private let duration: AdaUtils.TimeInterval = 0.32

    var finiteDuration: AdaUtils.TimeInterval? { duration }

    func animate<Value: VectorArithmetic>(
        _ value: Value,
        time: AdaUtils.TimeInterval,
        context: inout AnimationContext<Value>
    ) -> Value? {
        guard time < duration else { return nil }

        let progress = time / duration
        let shifted = progress - 1
        let shiftedSquared = shifted * shifted
        let cubicOvershoot = 2.70158 * shiftedSquared * shifted
        let quadraticOvershoot = 1.70158 * shiftedSquared
        let easedProgress = 1 + cubicOvershoot + quadraticOvershoot
        return value.scaled(by: Double(easedProgress))
    }
}

private struct MobileEditorDotGrid: Shape {
    typealias AnimatableData = EmptyAnimatableData

    func path(in rect: Rect) -> Path {
        var path = Path()
        let spacing: Float = 22
        var x: Float = 10
        while x < rect.width {
            var y: Float = 10
            while y < rect.height {
                path.addEllipse(in: Rect(x: x, y: y, width: 1.2, height: 1.2))
                y += spacing
            }
            x += spacing
        }
        return path
    }
}

private struct MobileEditorIdeaHalo: Shape {
    typealias AnimatableData = EmptyAnimatableData

    func path(in rect: Rect) -> Path {
        var path = Path()
        for index in 0..<1_400 {
            let x = Float((index * 239) % 1_397) / 1_397
            let y = Float((index * 577) % 1_391) / 1_391
            let dx = (x - 0.5) * 1.3
            let dy = (y - 0.5) * 1.8
            let distance = dx * dx + dy * dy
            guard distance > 0.04, distance < 0.38 else { continue }
            path.addEllipse(in: Rect(x: x * rect.width, y: y * rect.height, width: 0.75, height: 0.75))
        }
        return path
    }
}

struct MobileEditorBuildScreen: View {
    @Environment(\.theme) private var theme
    let project: MobileEditorProject
    @Binding var promptDraft: String
    let attachmentNames: [String]
    let chatEvents: [EditorAgentEvent]
    let agentStatus: String?
    let isAgentRunning: Bool
    let submit: () -> Void
    let showTemplates: () -> Void
    let pickFiles: () -> Void
    let pickPhotos: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if chatEvents.isEmpty {
                Spacer()

                ZStack {
                    Text("What would you like\nto create today?")
                        .font(MobileEditorFont.font(size: 27))
                        .foregroundColor(theme.editorColors.text)
                        .multilineTextAlignment(.center)
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 170)

                Spacer()
            } else {
                EditorAgentTranscript(events: chatEvents, sessionID: project.id.uuidString)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            }

            EditorAgentComposerSurface(
                cornerRadius: 28,
                horizontalInset: 16,
                topInset: 13,
                bottomInset: 11,
                usesGlass: false
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    EditorAgentPromptEditor(
                        text: _promptDraft,
                        placeholder: project.prompt == nil ? "Create a game…" : "Describe your next change…",
                        promptIdentifier: "AdaEditor.Mobile.BuildPrompt"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !attachmentNames.isEmpty {
                        Text(attachmentNames.joined(separator: ", "))
                            .font(MobileEditorFont.font(size: 10))
                            .foregroundColor(theme.editorColors.muted)
                            .lineLimit(1)
                    }

                    HStack {
                        Button(action: pickFiles) {
                            Text("\u{E145}")
                                .font(AdaEditorMaterialSymbolFont.font(size: 32))
                                .foregroundColor(theme.editorColors.text)
                                .frame(width: 48, height: 48)
                        }
                        .buttonStyle(DefaultButtonStyle())
                        .accessibilityIdentifier("AdaEditor.Mobile.AddFiles")

                        Button(action: pickPhotos) {
                            Text("\u{E3F4}")
                                .font(AdaEditorMaterialSymbolFont.font(size: 22))
                                .foregroundColor(theme.editorColors.text)
                                .frame(width: 44, height: 48)
                        }
                        .buttonStyle(DefaultButtonStyle())
                        .accessibilityIdentifier("AdaEditor.Mobile.AddPhotos")

                        Spacer()

                        Button(action: submit) {
                            Text("\u{E163}")
                                .font(AdaEditorMaterialSymbolFont.font(size: 22))
                                .foregroundColor(theme.editorColors.text)
                                .frame(width: 48, height: 48)
                        }
                        .buttonStyle(DefaultButtonStyle())
                        .disabled((promptDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachmentNames.isEmpty) || isAgentRunning)
                        .accessibilityIdentifier("AdaEditor.Mobile.BuildSubmit")
                    }
                }
            }
            .frame(maxWidth: .infinity)

            if chatEvents.isEmpty {
                Button(action: showTemplates) {
                    Text("View templates")
                        .font(MobileEditorFont.font(size: 13))
                        .foregroundColor(theme.editorColors.text)
                        .padding(.horizontal, 16)
                        .frame(height: 32)
                        .background(CapsuleShape().fill(theme.editorColors.surface))
                        .overlay {
                            CapsuleShape().stroke(theme.editorColors.border, lineWidth: 1)
                                .allowsHitTesting(false)
                        }
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.Mobile.ViewTemplates")
                .padding(.top, 28)
            }

            if let agentStatus {
                Text(agentStatus)
                    .font(MobileEditorFont.font(size: 12))
                    .foregroundColor(theme.editorColors.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 16)
            }
            if chatEvents.isEmpty {
                Spacer()
            } else {
                Color.clear.frame(height: 70)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 84)
//        .background {
//            MobileEditorDotGrid()
//                .fill(Color.white.opacity(0.12))
//                .allowsHitTesting(false)
//        }
    }
}

struct MobileEditorPlayEmptyScreen: View {
    @Environment(\.theme) private var theme
    let message: String?
    let showBuild: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 21) {
            MobileEditorSectionHeading(eyebrow: "Play", title: "Your game will appear here")
            Text(message ?? "Build a valid AdaScript project to see it here.")
                .font(MobileEditorFont.font(size: 15))
                .foregroundColor(theme.editorColors.muted)
            MobileEditorPrimaryButton(title: "Go to Build", action: showBuild)
        }
        .padding(.horizontal, 22)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.editorColors.background)
    }
}
#endif
