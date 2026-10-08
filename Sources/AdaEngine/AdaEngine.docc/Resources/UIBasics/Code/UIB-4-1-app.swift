import AdaEngine

@main
struct UIBasicsApp: App {
    var body: some AppScene {
        WindowGroup {
            ContentView()
        }
        .windowMode(.windowed)
        .windowTitle("UI Basics")
    }
}
