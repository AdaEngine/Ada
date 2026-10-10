@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@Suite("Editor top toolbar")
struct EditorTopToolbarTests {
    @Test("credit counter stays clear of centered search", arguments: [Float(1_024), 1_280, 1_728])
    @MainActor
    func creditCounterDoesNotOverlapSearch(width: Float) throws {
        prepareRendererIfNeeded()
        let size = Size(width: width, height: AdaEngineStyleLayoutSpec.topToolbarHeight)
        let container = UIContainerView(
            rootView: EditorTopToolbar(
                project: EditorProjectReference(name: "Example", path: "/tmp/Example"),
                isProjectSwitcherPresented: false,
                isRunDestinationMenuPresented: false,
                viewModel: EditorToolbarViewModel(),
                runDestination: .macOS,
                isRunEnabled: true,
                isStopEnabled: false,
                onToggleRunDestinationMenu: {},
                onToggleProjectSwitcher: {},
                onRun: {},
                onStop: {},
                onDebug: {},
                interface: EditorInterfaceState(projectPath: "/tmp/ToolbarLayoutTest")
            )
            .environment(\.metrics, AdaEngineStyleLayoutMetrics(size: size))
        )
        container.frame = Rect(origin: .zero, size: size)
        container.bounds.size = size
        container.layoutIfNeeded()

        let search = try container.uiNode(matching: .accessibilityIdentifier(EditorTopToolbar.searchAccessibilityIdentifier))
        let credits = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Cloud.AICredits.Counter"))
        let interface = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.InterfaceMode"))
        #expect(abs(search.absoluteFrame.midX - width / 2) < 0.5)
        #expect(search.absoluteFrame.width >= 120)
        #expect(search.absoluteFrame.maxX + 8 <= credits.absoluteFrame.minX)
        #expect(interface.absoluteFrame.maxX + 8 <= search.absoluteFrame.minX)
    }

    @Test("run destination uses a dropdown menu")
    @MainActor
    func runDestinationMenuSelectsDestination() throws {
        prepareRendererIfNeeded()
        var selectedDestination: EditorRunDestination?
        let size = Size(width: 640, height: 320)
        let container = UIContainerView(
            rootView: EditorRunDestinationOverlay(
                isPresented: true,
                selectedDestination: .macOS,
                toolbarHeight: AdaEngineStyleLayoutSpec.topToolbarHeight,
                onDismiss: {},
                onSelect: { selectedDestination = $0 }
            )
        )
        container.frame = Rect(origin: .zero, size: size)
        container.bounds.size = size
        container.layoutIfNeeded()

        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.RunDestination.iPadOS"))

        #expect(selectedDestination == .iPadOS)
    }

    @Test("run and stop are compact icon controls")
    @MainActor
    func runAndStopUseCompactIconFrames() throws {
        prepareRendererIfNeeded()
        let size = Size(width: 1_280, height: AdaEngineStyleLayoutSpec.topToolbarHeight)
        let metrics = AdaEngineStyleLayoutMetrics(size: size)
        let container = UIContainerView(
            rootView: EditorTopToolbar(
                project: EditorProjectReference(name: "Example", path: "/tmp/Example"),
                isProjectSwitcherPresented: false,
                isRunDestinationMenuPresented: false,
                viewModel: EditorToolbarViewModel(),
                runDestination: .iPadOS,
                isRunEnabled: true,
                isStopEnabled: false,
                onToggleRunDestinationMenu: {},
                onToggleProjectSwitcher: {},
                onRun: {},
                onStop: {}
            )
            .environment(\.metrics, metrics)
        )
        container.frame = Rect(origin: .zero, size: size)
        container.bounds.size = size
        container.layoutIfNeeded()

        let destination = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.RunDestination.Button"))
        let run = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Toolbar.Run"))
        let stop = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Toolbar.Stop"))
        let projectSwitcher = try container.uiNode(matching: .accessibilityIdentifier(EditorTopToolbar.projectSwitcherAccessibilityIdentifier))
        let projectIcon = try container.uiNode(matching: .accessibilityIdentifier(EditorTopToolbar.projectSwitcherIconAccessibilityIdentifier))

        #expect(destination.absoluteFrame.width == metrics.toolbarRunDestinationWidth)
        #expect(run.absoluteFrame.width == 30)
        #expect(stop.absoluteFrame.width == 30)
        #expect(projectIcon.absoluteFrame.minX - projectSwitcher.absoluteFrame.minX <= 12)
        #expect(!AdaEngineStyleContent.topToolbarLabels.contains("Hot Reload"))
    }

    #if os(macOS)
        @Test("available updates fit beside the run controls")
        @MainActor
        func updateButtonFitsToolbar() throws {
            prepareRendererIfNeeded()
            EditorUpdateCenter.shared.start()
            NotificationCenter.default.post(name: EditorUpdateBridge.stateChanged, object: nil, userInfo: ["version": "2.0"])
            defer { NotificationCenter.default.post(name: EditorUpdateBridge.stateChanged, object: nil) }
            let size = Size(width: 1_280, height: AdaEngineStyleLayoutSpec.topToolbarHeight)
            let container = UIContainerView(
                rootView: EditorTopToolbar(
                    project: nil,
                    isProjectSwitcherPresented: false,
                    isRunDestinationMenuPresented: false,
                    viewModel: EditorToolbarViewModel(),
                    runDestination: .macOS,
                    isRunEnabled: true,
                    isStopEnabled: false,
                    onToggleRunDestinationMenu: {},
                    onToggleProjectSwitcher: {},
                    onRun: {},
                    onStop: {}
                )
                .environment(\.metrics, AdaEngineStyleLayoutMetrics(size: size))
            )
            container.frame = Rect(origin: .zero, size: size)
            container.bounds.size = size
            container.layoutIfNeeded()
            let update = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Update"))
            let destination = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.RunDestination.Button"))
            #expect(update.absoluteFrame.width > 40)
            #expect(update.absoluteFrame.height == 28)
            #expect(update.absoluteFrame.maxX <= destination.absoluteFrame.minX)
        }
    #endif

    #if os(macOS)
    @Test("Android device and AVD rows have distinct frames and select their own destinations")
    @MainActor
    func androidRowsDoNotOverlap() throws {
        prepareRendererIfNeeded()
        let avd = EditorAndroidTarget(id: "avd:Pixel", name: "Pixel", kind: .emulator, serial: nil, avd: "Pixel", state: "stopped")
        let phone = EditorAndroidTarget(id: "device:USB1", name: "Phone", kind: .device, serial: "USB1", avd: nil, state: "device")
        var selected: String?
        let container = UIContainerView(rootView: EditorRunDestinationMenu(selectedDestination: .android, onSelect: { _ in },
            androidTargets: [avd, phone], onSelectAndroid: { selected = $0.id }))
        container.frame = Rect(x: 0, y: 0, width: 308, height: 500)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let first = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Android.Target.avd:Pixel"))
        let second = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Android.Target.device:USB1"))
        #expect(first.absoluteFrame.maxY <= second.absoluteFrame.minY)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Android.Target.avd:Pixel"))
        #expect(selected == avd.id)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Android.Target.device:USB1"))
        #expect(selected == phone.id)
    }
    #endif

    @MainActor
    private func prepareRendererIfNeeded() {
        guard unsafe RenderEngine.shared == nil else {
            return
        }
        unsafe RenderEngine.configurations.preferredBackend = .headless
        let app = AppWorlds(main: World(name: "EditorTopToolbarTests"))
        RenderWorldPlugin().setup(in: app)
    }
}
