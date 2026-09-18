@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@Suite("Editor top toolbar")
struct EditorTopToolbarTests {
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
