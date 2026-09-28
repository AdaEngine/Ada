import AdaAnimation
import AdaText
import AdaUtils
import Foundation
import Math

/// A liquid-glass tab bar with a floating selector that follows the selected tab.
///
/// Apply this style to a `TabView` with `.tabViewStyle(LiquidGlassTabBarStyle())`.
/// The built-in `DefaultTabViewStyle` remains the default when no style is specified.
@MainActor
public struct LiquidGlassTabBarStyle: TabViewStyle {
    public var backgroundColor: Color
    public var borderColor: Color
    public var selectedColor: Color
    public var unselectedColor: Color
    public var symbols: [String: String]
    public var symbolFont: Font
    public var labelFont: Font

    public init(
        backgroundColor: Color = Color(red: 0.12, green: 0.12, blue: 0.12),
        borderColor: Color = Color.white.opacity(0.12),
        selectedColor: Color = .white,
        unselectedColor: Color = Color.white.opacity(0.58),
        symbols: [String: String] = [:],
        symbolFont: Font = .system(size: 22),
        labelFont: Font = .system(size: 11)
    ) {
        self.backgroundColor = backgroundColor
        self.borderColor = borderColor
        self.selectedColor = selectedColor
        self.unselectedColor = unselectedColor
        self.symbols = symbols
        self.symbolFont = symbolFont
        self.labelFont = labelFont
    }

    public func makeBody(configuration: Configuration) -> some View {
        LiquidGlassTabBar(configuration: configuration, style: self)
    }
}

@MainActor
private struct LiquidGlassTabBar: View {
    @Environment(\.keyboardSafeAreaInset) private var keyboardSafeAreaInset
    let configuration: TabViewStyleConfiguration
    let style: LiquidGlassTabBarStyle
    @State private var isDragging = false
    @State private var dragOffset: Float = 0
    @State private var edgePull: Float = 0
    @State private var dragOriginIndex = 0
    @State private var selectorRelease = 0
    @State private var glassPhase: Float = 0
    @State private var lensPhase: Float = 0
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

    private var tabs: [TabViewStyleConfiguration.Tab] { configuration.tabs.filter { $0.placement == .bar } }
    private var floatingTabs: [TabViewStyleConfiguration.Tab] { configuration.tabs.filter { $0.placement == .floating } }
    private var hasSelectedBarTab: Bool { tabs.contains { $0.isSelected } }
    private var selectedIndex: Int { tabs.firstIndex { $0.isSelected } ?? 0 }
    private var barWidth: Float {
        selectorInset * 2 + Float(tabs.count) * tabWidth + Float(max(0, tabs.count - 1)) * tabSpacing
    }
    private var selectorCenterX: Float {
        let index = isDragging ? dragOriginIndex : selectedIndex
        return selectorInset + Float(index) * (tabWidth + tabSpacing) + tabWidth * 0.5 + (isDragging ? dragOffset : 0)
    }
    private var edgeStretch: Float { min(abs(edgePull) / 36, 1) * glassPhase }
    private var selectorCompression: Float { min(max((selectorVelocity - 250) / 1_250, 0), 1) }
    private var edgeStretchOffset: Float {
        let lensWidth = tabWidth + (activeLensWidth - tabWidth) * lensPhase
        let extraWidth = lensWidth * edgeWidthStretch * edgeStretch
        return (edgePull < 0 ? -1 : 1) * extraWidth * 0.5 + edgePull * 0.10
    }

    @ViewBuilder
    var body: some View {
        switch configuration.position {
        case .top:
            ZStack(anchor: .top) {
                configuration.content
                tabBar.padding(.top, 20)
            }
        case .bottom, .left, .right:
            ZStack(anchor: .bottom) {
                configuration.content
                tabBar.padding(.bottom, 20)
                    .offset(y: keyboardSafeAreaInset)
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 12) {
            if !tabs.isEmpty {
                mainTabBar
            }
            ForEach(floatingTabs) { tab in
                floatingTab(tab)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func floatingTab(_ tab: TabViewStyleConfiguration.Tab) -> some View {
        Button(action: tab.action) {
            ZStack {
                if let label = tab.label, let symbol = style.symbols[label] {
                    Text(symbol).font(style.symbolFont).frame(width: 28, height: 28)
                } else if let image = tab.image {
                    image.frame(width: 28, height: 28)
                } else if let label = tab.label {
                    Text(label).font(style.labelFont)
                }
            }
            .foregroundColor(tab.isSelected ? style.selectedColor : style.unselectedColor)
            .frame(width: 68, height: 68)
            .background(Circle().fill(style.backgroundColor))
            .glassEffect(.regular.tint(Color.white.opacity(tab.isSelected ? 0.12 : 0.035)), in: .circle)
            .overlay {
                Circle().stroke(style.borderColor, lineWidth: 1).allowsHitTesting(false)
            }
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaUI.TabView.Floating.\(tab.id)")
    }

    private var mainTabBar: some View {
        ZStack(anchor: .leading) {
            CapsuleShape()
                .fill(style.backgroundColor)
                .frame(width: barWidth, height: 68)
                .glassEffect(.regular.tint(Color.white.opacity(0.035)), in: .capsule)
                .overlay {
                    CapsuleShape().stroke(style.borderColor, lineWidth: 1).allowsHitTesting(false)
                }
                .allowsHitTesting(false)

            HStack(spacing: tabSpacing) {
                ForEach(tabs.indices, id: \.self) { index in
                    tab(at: index)
                }
            }
            .padding(selectorInset)

            if hasSelectedBarTab {
                floatingSelector
            }

            HStack(spacing: tabSpacing) {
                ForEach(tabs.indices, id: \.self) { index in
                    tabLabel(at: index)
                        .frame(width: tabWidth, height: 58)
                }
            }
            .padding(selectorInset)
            .opacity(1 - glassPhase)
            .allowsHitTesting(false)
        }
        .frame(width: barWidth, height: 68)
        .onChange(of: selectedIndex) { oldIndex, newIndex in
            let distance = Float(abs(newIndex - oldIndex)) * (tabWidth + tabSpacing)
            Task { @MainActor in
                await Task.yield()
                recordSelectorVelocity(distance * 4.7 / 0.32)
            }
        }
        .onDisappear {
            velocityDecayTask?.cancel()
            velocityDecayTask = nil
            selectorVelocity = 0
            lastDragSample = nil
            lastVelocitySample = nil
        }
    }

    private var floatingSelector: some View {
        ZStack {
            CapsuleShape().fill(style.borderColor.opacity(0.65 * (1 - glassPhase)))
            CapsuleShape().fill(Color.white.opacity(0.03 * glassPhase))
        }
        .frame(width: activeLensWidth, height: activeLensHeight)
        .glassEffect(selectorGlass, in: .capsule)
        .scaleEffect(Vector2(
            x: (tabWidth + (activeLensWidth - tabWidth) * lensPhase) / activeLensWidth
                * (1 + edgeWidthStretch * edgeStretch) * (1 - 0.20 * selectorCompression),
            y: (58 + (activeLensHeight - 58) * lensPhase) / activeLensHeight
                * (1 - 0.06 * edgeStretch) * (1 - 0.10 * selectorCompression)
        ))
        .animation(Animation.easeInOut(duration: 0.08), value: selectorCompression)
        .offset(x: selectorCenterX + edgeStretchOffset - activeLensWidth * 0.5)
        .animation(Animation(LiquidGlassTabBarBounce()), value: selectedIndex)
        .animation(Animation(LiquidGlassTabBarBounce()), value: selectorRelease)
        .allowsHitTesting(false)
    }

    private var activeLensGlass: Glass {
        var glass = Glass.clear
        glass.blurRadius = 1
        glass.glassTintStrength = 0.12
        glass.edgeShadowStrength = 0.20
        glass.glassThickness = 48
        glass.refractiveIndex = 1.28
        glass.dispersionStrength = 0.90
        glass.fresnelIntensity = 0.98
        glass.glareIntensity = 0.92
        glass.tintColor = Color.white.opacity(0.04)
        return glass.interactive(false)
    }

    private var selectorGlass: Glass {
        let idle = Glass.regular
        let active = activeLensGlass
        func mix(_ start: Float, _ end: Float) -> Float { start + (end - start) * glassPhase }

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

    private func tabLabel(at index: Int) -> some View {
        let tab = tabs[index]
        return VStack(spacing: 3) {
            if let label = tab.label, let symbol = style.symbols[label] {
                Text(symbol).font(style.symbolFont).frame(width: 22, height: 22)
            }
            if let image = tab.image {
                image.frame(width: 22, height: 22)
            }
            if let label = tab.label {
                Text(label).font(style.labelFont)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundColor(tab.isSelected ? style.selectedColor : style.unselectedColor)
        .scaleEffect(Vector2(x: tab.isSelected ? 1.12 : 1, y: tab.isSelected ? 1.12 : 1))
        .animation(Animation(LiquidGlassTabBarBounce()), value: tab.isSelected)
    }

    @ViewBuilder
    private func tab(at index: Int) -> some View {
        if index == selectedIndex {
            tabLabel(at: index)
                .frame(width: tabWidth, height: 58)
                .gesture(
                    LongPressGesture(minimumDuration: 0.22)
                        .onEnded { _ in beginDrag(from: index) }
                        .simultaneously(with: DragGesture(minimumDistance: 0)
                            .onChanged { updateDrag($0, from: index) }
                            .onEnded { finishDrag($0, from: index) })
                )
        } else {
            Button {
                tabs[index].action()
            } label: {
                tabLabel(at: index).frame(width: tabWidth, height: 58)
            }
            .buttonStyle(DefaultButtonStyle())
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
            tabs[targetIndex].action()
            return
        }

        guard abs(value.translation.width) < 8, abs(value.translation.height) < 8 else { return }
        tabs[index].action()
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
                    selectorVelocity *= Float(exp(-14 * Double(seconds)))
                }
                previousTick = now
            }
            selectorVelocity = 0
            velocityDecayTask = nil
        }
    }

    private func transitionGlass(to target: Float) {
        withAnimation(Animation(LiquidGlassTabBarBounce())) {
            glassPhase = target
            lensPhase = target
        }
    }
}

private struct LiquidGlassTabBarBounce: CustomAnimation {
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
        return value.scaled(by: Double(1 + cubicOvershoot + quadraticOvershoot))
    }
}
