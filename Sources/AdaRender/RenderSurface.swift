//
//  RenderSurface.swift
//  AdaEngine
//
//  Created by v.prusakov on 9/10/21.
//

import AdaUtils

#if WASM && canImport(JavaScriptKit)
    import JavaScriptKit
#endif

/// A protocol that defines a render surface.
/// Wrap platform specific view to render surface.
@MainActor
public protocol RenderSurface {
    var scaleFactor: Float { get }
    var prefferedPixelFormat: PixelFormat { get }
}

#if WASM && canImport(JavaScriptKit)
    @MainActor
    public protocol BrowserCanvasRenderSurface: RenderSurface {
        var canvas: JSObject { get }
    }
#endif

#if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    import MetalKit
    #if canImport(AppKit)
        import AppKit
    #endif

    extension MTKView: RenderSurface {
        public var scaleFactor: Float {
            #if canImport(AppKit)
                return unsafe Float(appKitBackingScaleFactor(for: self.window))
            #elseif canImport(UIKit)
                return Float(self.window?.screen.scale ?? UIScreen.main.scale)
            #else
                return 1
            #endif
        }

        public var prefferedPixelFormat: PixelFormat {
            self.colorPixelFormat.toPixelFormat()
        }
    }

    #if canImport(AppKit)
        @MainActor
        private func appKitBackingScaleFactor(for window: NSWindow?) -> CGFloat {
            guard let window else {
                return NSScreen.main?.backingScaleFactor ?? NSScreen.screens.first?.backingScaleFactor ?? 1
            }

            return window.screen?.backingScaleFactor
                ?? appKitScreen(containing: window.frame)?.backingScaleFactor
                ?? window.backingScaleFactor
        }

        private func appKitScreen(containing windowFrame: NSRect) -> NSScreen? {
            let screens = NSScreen.screens
            guard !screens.isEmpty else {
                return nil
            }

            let bestMatch =
                screens
                .map { screen in (screen, screen.frame.intersectionArea(with: windowFrame)) }
                .max { lhs, rhs in lhs.1 < rhs.1 }

            guard let bestMatch, bestMatch.1 > 0 else {
                return nil
            }

            return bestMatch.0
        }

        extension NSRect {
            func intersectionArea(with rect: NSRect) -> CGFloat {
                let intersection = self.intersection(rect)
                guard !intersection.isNull, !intersection.isEmpty else {
                    return 0
                }

                return intersection.width * intersection.height
            }
        }
    #endif

#endif

#if os(Windows)
    import WinSDK

    /// Windows-specific render surface implementation.
    /// This wraps a Win32 window handle for use with the rendering system.
    @safe
    public final class WindowsSurface: RenderSurface {
        public let windowId: WindowID
        public let windowHwnd: UnsafeMutableRawPointer

        public var scaleFactor: Float {
            let hwnd = windowHwnd.assumingMemoryBound(to: HWND__.self)
            let dpi = unsafe GetDpiForWindow(hwnd)
            guard dpi > 0 else {
                return 1
            }
            return max(Float(dpi) / 96.0, 1)
        }
        public var prefferedPixelFormat: PixelFormat { .bgra8 }

        public init(windowId: WindowID, windowHwnd: UnsafeMutableRawPointer) {
            self.windowId = windowId
            unsafe self.windowHwnd = unsafe windowHwnd
        }
    }
#endif
