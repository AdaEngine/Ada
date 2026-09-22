import AdaEngine
import MedievalArenaGame

@main
struct MedievalArenaApp: App {
    private let launch = ArenaLaunchOptions.current

    var body: some AppScene {
        DefaultAppWindow(assetBundle: ArenaResources.bundle)
            .addPlugins(MedievalArenaPlugin(launch: launch))
            .windowMode(.windowed)
            .windowTitle("Medieval Arena · \(launch.role == .host ? "Host" : "Peer")")
            .windowResizable(true)
            .minimumSize(width: 960, height: 640)
    }
}
