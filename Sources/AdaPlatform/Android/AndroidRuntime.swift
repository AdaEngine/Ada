#if os(Android)
    import AdaApp
    import CAndroid
    import Foundation

    /// Starts an AdaEngine app inside Android's NativeActivity.
    ///
    /// Export `ada_android_start` from a dynamic Swift library and call this method
    /// with an app factory. The native host installs the Swift custom main executor on the
    /// Android main looper before invoking the entry point.
    @MainActor
    public enum AndroidRuntime {
        private static var task: Task<Void, Never>?

        /// Writes a native Android logcat message under the AdaEngine tag.
        public nonisolated static func log(_ message: String) {
            unsafe message.withCString { unsafe ada_android_log($0) }
        }

        public nonisolated static func start<A: App>(_ factory: @escaping @MainActor @Sendable () -> A) {
            Task { @MainActor in
                guard task == nil else { return }
                task = Task { @MainActor in
                    do {
                        try await AppRuntime.run(factory())
                    } catch {
                        log("Android app failed: \(error)")
                        unsafe ada_android_finish()
                    }
                }
            }
        }

    }

    @_cdecl("ada_android_frame")
    func androidFrame(_ time: Int64) {
        Task { @MainActor in
            (Application.shared as? AndroidApplication)?.frame(time)
        }
    }

    @_cdecl("ada_android_surface_changed")
    func androidSurfaceChanged(_ width: Int32, _ height: Int32, _ scale: Float) {
        Task { @MainActor in
            (Application.shared as? AndroidApplication)?.resize(width: width, height: height, scale: scale)
        }
    }

    @_cdecl("ada_android_surface_lost")
    func androidSurfaceLost() {
        Task { @MainActor in
            (Application.shared as? AndroidApplication)?.detachSurface()
        }
    }

    @_cdecl("ada_android_state")
    func androidState(_ state: Int32) {
        Task { @MainActor in
            guard let app = Application.shared as? AndroidApplication else { return }
            // Android may recreate NativeActivity inside the same process. Keep
            // the single app context suspended and resume it with the new surface.
            app.setResumed(state == 1)
        }
    }

    @_cdecl("ada_android_touch")
    func androidTouch(_ id: Int32, _ phase: Int32, _ x: Float, _ y: Float) {
        Task { @MainActor in
            (Application.shared as? AndroidApplication)?.touch(id: id, phase: phase, x: x, y: y)
        }
    }
#endif
