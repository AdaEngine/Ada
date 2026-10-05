#if os(Android)
    import AdaEngine
    import AdaPlatform
    import Foundation

    @_cdecl("ada_android_start")
    public func androidDemoStart() {
        AndroidRuntime.start { AndroidDemo() }
    }

    struct AndroidDemo: App {
        var body: some AppScene {
            WindowGroup(
                content: { AndroidDemoView() },
                assetBundle: AndroidResourceBundle.bundle(named: "AdaEngine_AndroidDemo")
            )
        }
    }

    private struct AndroidDemoView: View {
        @State private var taps = 0
        var body: some View {
            VStack(spacing: 24) {
                Text("AdaEngine on Android").foregroundColor(.white)
                Text("Native Swift • Android Surface • Touch").foregroundColor(.white)
                Text("Taps: \(taps)").foregroundColor(.white)
                Button(action: {
                    taps += 1
                    AndroidRuntime.log("AndroidDemo taps=\(taps)")
                }) {
                    Text("Tap +1").foregroundColor(.white)
                }
            }
        }
    }

#else
    public enum AndroidDemoUnsupportedHost {}
#endif
