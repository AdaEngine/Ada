//
//  WindowManager.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/29/22.
//

import AdaECS
@_spi(Internal) import AdaInput
import AdaRender
import AdaUtils
import Foundation
import Math

/// Base protocol describes platform specific window.
@MainActor
public protocol SystemWindow {
    /// Whether the native window is maximized.
    var isMaximized: Bool { get }

    /// Updates client regions that must receive input instead of dragging the title bar.
    func updateTitleBarInputRegions(_ regions: [Rect], maximizeButton: Rect?)

    /// Performs a native caption action, preserving the platform's close lifecycle.
    func performCaptionAction(_ action: WindowCaptionAction)

    /// Window title.
    var title: String { get set }

    /// Window size.
    var size: Size { get set }

    /// Window position on screen.
    var position: Point { get set }

    /// Screen position of the content coordinate origin, in logical units.
    var contentPosition: Point { get }
}

extension SystemWindow {
    public var contentPosition: Point { position }
    public var isMaximized: Bool { false }
    public func updateTitleBarInputRegions(_ regions: [Rect], maximizeButton: Rect?) {}
    public func performCaptionAction(_ action: WindowCaptionAction) {}
}

public enum WindowCaptionAction: Sendable, Equatable {
    case minimize, toggleMaximize, close
}

/// Base class using to manage windows in application. All created window should be registred there.
/// Application has only one window manager per instance.
@MainActor
open class UIWindowManager: InputPointerDriver {
    public private(set) static var shared: UIWindowManager!

    /// Returns all windows registred in current process.
    public internal(set) var windows: SparseSet<UIWindow.ID, UIWindow> = [:]

    /// Contains active window if available.
    public private(set) var activeWindow: UIWindow?

    @_spi(Internal)
    public var inputRef: Ref<Input>? {
        didSet { inputRef?.wrappedValue.attachPointerDriver(self) }
    }
    private var pointerOwner: UUID?
    private var pointerWindow: UIWindow.ID?

    func pointerIsCaptured(in window: UIWindow.ID) -> Bool {
        pointerWindow == window && pointerOwner != nil && getMouseMode() == .captured
    }

    public func requestMouseMode(_ mode: Input.MouseMode, owner: UUID, window: RID?) {
        guard let window, window != .empty, activeWindow?.id == window else { return }
        pointerOwner = owner
        pointerWindow = window
        setMouseMode(mode)
    }

    public func releaseMouseMode(owner: UUID) {
        guard pointerOwner == owner else { return }
        setMouseMode(.visible)
        pointerOwner = nil
        pointerWindow = nil
    }

    public func mouseMode(owner: UUID) -> Input.MouseMode {
        guard pointerOwner == owner else { return .visible }
        return getMouseMode()
    }

    public init() {}

    open func menuBuilder(for _: UIWindow) -> UIMenuBuilder? {
        return nil
    }

    /// Create platform window and register app window inside the manager.
    /// - Warning: You should call this method when override this method!
    open func createWindow(for window: UIWindow) {
        self.windows[window.id] = window
        window.windowDidReady()
    }

    /// Show window and make it focused.
    open func showWindow(_: UIWindow, isFocused _: Bool) {
        fatalErrorMethodNotImplemented()
    }

    /// Close window.
    open func closeWindow(_: UIWindow) {
        fatalErrorMethodNotImplemented()
    }

    /// Set window mode for window.
    open func setWindowMode(_: UIWindow, mode _: UIWindow.Mode) {
        fatalErrorMethodNotImplemented()
    }

    /// Set minimum size for window.
    open func setMinimumSize(_: Size, for _: UIWindow) {
        fatalErrorMethodNotImplemented()
    }

    /// Resize window.
    open func resizeWindow(_: UIWindow, size _: Size) {
        fatalErrorMethodNotImplemented()
    }

    /// Get screen instance for window.
    open func getScreen(for _: UIWindow) -> Screen? {
        Screen.main
    }

    open func setActiveWindow(_ window: UIWindow) {
        guard self.activeWindow !== window else {
            return
        }

        if let activeWindow {
            resignActiveWindow(activeWindow)
        }

        self.activeWindow = window
        window.isActive = true
        window.windowDidBecameActive()
    }

    /// Clears the active window when the platform reports that it lost focus.
    open func resignActiveWindow(_ window: UIWindow) {
        guard self.activeWindow === window else {
            return
        }

        window.isActive = false
        if pointerWindow == window.id, let pointerOwner { releaseMouseMode(owner: pointerOwner) }
        self.activeWindow = nil
        ContextMenuPresentationCenter.dismissForDeactivation?(window)
        window.windowDidResignActive()
    }

    open func setCursorShape(_: Input.CursorShape) {
        fatalErrorMethodNotImplemented()
    }

    open func getCursorShape() -> Input.CursorShape {
        fatalErrorMethodNotImplemented()
    }

    open func setCursorImage(for _: Input.CursorShape, texture _: Texture2D?, hotspot _: Vector2) {
        fatalErrorMethodNotImplemented()
    }

    open func setMouseMode(_: Input.MouseMode) {
        fatalErrorMethodNotImplemented()
    }

    open func getMouseMode() -> Input.MouseMode {
        fatalErrorMethodNotImplemented()
    }

    open func updateCursor() {
        fatalErrorMethodNotImplemented()
    }

    open func textInputFocusDidChange(_: Bool) {}

    public final func removeWindow(_ window: UIWindow, setActiveAnotherIfNeeded: Bool = true) {
        if pointerWindow == window.id, let pointerOwner { releaseMouseMode(owner: pointerOwner) }
        guard let window = self.windows[window.id] else {
            assertionFailure("We don't have window in windows stack. That strange problem.")
            return
        }

        // Destory window from render window
        do {
            guard let renderEngine = unsafe RenderEngine.shared else {
                assertionFailure("RenderEngine is not initialized.")
                return
            }
            try renderEngine.destroyWindow(window.id)
        } catch {
            assertionFailure(error.localizedDescription)
            return
        }
        window.runtimeCameraEntity?.removeFromWorld()
        window.runtimeCameraEntity = nil
        self.windows.remove(for: window.id)
        window.windowDidDisappear()

        // Check if we don't have any windows we should shutdown and quit engine process
        guard !self.windows.isEmpty else {
            return
        }

        if setActiveAnotherIfNeeded {
            // Set last window as active
            // TODO: (Vlad) I think we should have any order
            guard let newUIWindow = self.windows.values.last?.value else {
                return
            }
            self.setActiveWindow(newUIWindow)
        }
    }
}

extension UIWindowManager {
    @_spi(Internal)
    public static func setShared(_ manager: UIWindowManager) {
        self.shared = manager
    }
}
