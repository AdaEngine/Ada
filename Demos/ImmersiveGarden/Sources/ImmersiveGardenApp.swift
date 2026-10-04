import AdaEngine
import AdaEngineEmbeddable
import CompositorServices
import SwiftUI

@main
struct ImmersiveGardenApp: SwiftUI.App {
    @SwiftUI.State private var model = GardenWorkspace()
    @SwiftUI.State private var style: ImmersionStyle = .full

    var body: some SwiftUI.Scene {
        SwiftUI.WindowGroup(id: "tools") {
            GardenTools(model: model)
        }
        .defaultSize(width: 360, height: 460)

        ImmersiveSpace(id: "garden") {
            CompositorLayer(configuration: ImmersiveLayerConfiguration()) { layer in
                Task { @MainActor in await model.run(layer: layer) }
            }
        }
        .immersionStyle(selection: $style, in: .full)
        .upperLimbVisibility(.visible)
    }
}

private struct GardenTools: SwiftUI.View {
    @SwiftUI.Bindable var model: GardenWorkspace
    @SwiftUI.Environment(\.openImmersiveSpace) private var openSpace
    @SwiftUI.Environment(\.dismissImmersiveSpace) private var dismissSpace
    @SwiftUI.Environment(\.scenePhase) private var scenePhase

    var body: some SwiftUI.View {
        AdaUIHost(assetBundle: .main, onError: { model.message = "Panel failed: \($0)" }) {
            GardenAdaTools(
                model: model,
                enter: { Task { @MainActor in await enterGarden() } },
                leave: {
                    Task { @MainActor in
                        model.stop()
                        await dismissSpace()
                    }
                }
            )
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--enter-garden") {
                await enterGarden()
            }
        }
        .onChange(of: model.needsDismissal) { _, requested in
            guard requested else {
                return
            }
            Task { @MainActor in
                await dismissSpace()
                model.needsDismissal = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { model.stop() }
        }
    }

    @MainActor
    private func enterGarden() async {
        guard !model.isOpening, !model.isImmersed else {
            return
        }
        model.isOpening = true
        switch await openSpace(id: "garden") {
        case .opened: break
        case .userCancelled:
            model.isOpening = false
            model.message = "Opening cancelled."
        case .error:
            model.isOpening = false
            model.message = "The immersive space could not be opened."
        @unknown default:
            model.isOpening = false
            model.message = "The immersive space is unavailable."
        }
    }
}
