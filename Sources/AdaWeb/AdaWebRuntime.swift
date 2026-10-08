//
//  AdaWebRuntime.swift
//  AdaEngine
//

import Foundation

#if WASM && canImport(JavaScriptKit)
    import JavaScriptEventLoop
    import JavaScriptKit
#endif

/// Browser runtime helpers for AdaEngine Web exports.
///
/// Games normally do not need to call this directly when they use
/// ``AdaPlatform/AppPlatformPlugin``. The export template keeps this product
/// available so app targets can explicitly opt into browser-only utilities
/// without depending on AdaPlatform internals.
public enum AdaWebRuntime {
    /// Returns true when the process is running in a browser-hosted WebAssembly environment.
    public static var isBrowserHosted: Bool {
        #if WASM && canImport(JavaScriptKit)
            JSObject.global.window.object != nil && JSObject.global.document.object != nil
        #else
            false
        #endif
    }

    /// Installs the JavaScript event-loop backed Swift concurrency executor.
    ///
    /// The browser application runtime calls this before starting AdaEngine's
    /// async main loop. This method is public for tests and custom entrypoints.
    public static func installConcurrencyExecutor() {
        #if WASM && canImport(JavaScriptEventLoop)
            JavaScriptEventLoop.installGlobalExecutor()
        #endif
    }

    /// The default canvas root element id used by generated export templates.
    public static let defaultCanvasRootElementID = "ada-canvas-root"
}
