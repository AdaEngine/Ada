#if os(Android)
    import CAndroid
    import Foundation

    /// Resolves SwiftPM resources packaged by `Tools/Android/android.py`.
    /// The native host extracts assets before starting the Swift app, so existing
    /// Foundation file and Bundle APIs can use shaders, fonts and game resources.
    public enum AndroidResourceBundle {
        public static func bundle(named name: String) -> Bundle {
            guard let path = unsafe ada_android_files_path() else {
                preconditionFailure("Android resources require the AdaEngine NativeActivity host")
            }
            let root = unsafe URL(fileURLWithPath: String(cString: path)).appendingPathComponent("resources")
            for suffix in ["resources", "bundle"] {
                if let bundle = Bundle(url: root.appendingPathComponent("\(name).\(suffix)")) { return bundle }
            }
            preconditionFailure("Android resource bundle \(name) was not packaged in the APK")
        }
    }
#endif
