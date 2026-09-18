//
//  MacOSWindowManager.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/29/22.
//

#if MACOS
    import AdaApp
    import AdaInput
    import AdaRender
    @_spi(Internal) import AdaUI
    import AdaUtils
    import AppKit
    import Math

    final class MacOSWindowManager: UIWindowManager {
        private lazy var windowEventHandler = NSWindowDelegateObject(windowManager: self)
        private unowned let screenManager: MacOSScreenManager

        init(_ screenManager: MacOSScreenManager) {
            self.screenManager = screenManager
            super.init()
        }

        private var menus: [UIWindow.ID: MacOSUIMenuBuilder] = [:]
        private var windowsPendingInitialCenter: Set<UIWindow.ID> = []
        private var windowsSynchronizingFromSystem: Set<UIWindow.ID> = []
        private var trafficLightDefaultOrigins: [ObjectIdentifier: [NSWindow.ButtonType: NSPoint]] = [:]
        private var trafficLightAppliedOrigins: [ObjectIdentifier: [NSWindow.ButtonType: NSPoint]] = [:]

        override func createWindow(for window: UIWindow) {
            let minSize = window.configuration.minimumSize

            let frame = window.frame
            let size = frame.size == .zero ? minSize : frame.size

            let contentRect = CGRect(
                x: CGFloat(frame.origin.x),
                y: CGFloat(frame.origin.y),
                width: CGFloat(size.width),
                height: CGFloat(size.height)
            )

            let rootContentView = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
            rootContentView.autoresizesSubviews = true
            rootContentView.wantsLayer = true
            rootContentView.layer?.backgroundColor = backgroundColor(for: window.configuration.background).cgColor

            let metalContainerView: NSView
            if let visualEffectView = visualEffectView(for: window.configuration.backgroundEffect, frame: rootContentView.bounds) {
                rootContentView.addSubview(visualEffectView)
                metalContainerView = visualEffectView
            } else {
                metalContainerView = rootContentView
            }

            /// Register view in engine
            let metalView = MetalView(
                windowId: window.id,
                frame: NSRect(origin: .zero, size: contentRect.size)
            )
            metalView.allowsTransparency = window.configuration.background.isTransparent
            metalView.allowsMousePassthrough = window.configuration.allowsMousePassthrough
            metalView.windowManager = self
            metalView.autoresizingMask = [.width, .height]
            metalContainerView.addSubview(metalView)

            var styleMask: NSWindow.StyleMask =
                switch window.configuration.chrome {
                case .standard:
                    [.titled, .closable, .resizable, .miniaturizable]
                case .borderless:
                    [.borderless]
                }
            if !window.configuration.isResizable {
                styleMask.remove(.resizable)
            }
            if window.configuration.titleBar.background == .transparent, window.configuration.chrome == .standard {
                styleMask.insert(.fullSizeContentView)
            }

            let systemWindow = NSWindow(
                contentRect: contentRect,
                styleMask: styleMask,
                backing: .buffered,
                defer: false
            )

            systemWindow.contentView = rootContentView
            configureTitleBar(for: systemWindow, configuration: window.configuration.titleBar)
            systemWindow.collectionBehavior = collectionBehavior(for: window.configuration.collectionBehavior)
            if let preferredScreen = preferredScreen(for: window.configuration.screenPreference), frame.origin == .zero {
                center(systemWindow, on: preferredScreen)
            } else if frame.origin == .zero {
                systemWindow.center()
                windowsPendingInitialCenter.insert(window.id)
            }
            systemWindow.isRestorable = false
            systemWindow.isReleasedWhenClosed = false
            systemWindow.acceptsMouseMovedEvents = true
            systemWindow.delegate = windowEventHandler
            systemWindow.level = windowLevel(for: window.configuration.level)
            systemWindow.isOpaque = !window.configuration.background.isTransparent
            systemWindow.hasShadow = window.configuration.hasShadow
            systemWindow.backgroundColor = backgroundColor(for: window.configuration.background)
            if window.configuration.chrome == .borderless {
                systemWindow.animationBehavior = .none
            }
            window.systemWindow = systemWindow
            if let title = window.configuration.title {
                window.title = title
            }
            if window.frame.origin != .zero {
                window.frame = Rect(origin: .zero, size: size)
            }
            window.minSize = minSize
            window.setWindowMode(window.configuration.mode)
            let renderSize = systemWindow.size
            if window.frame.size != renderSize {
                windowsSynchronizingFromSystem.insert(window.id)
                window.frame = Rect(origin: .zero, size: renderSize)
                windowsSynchronizingFromSystem.remove(window.id)
            }
            window.userInterfaceIdiom = .desktop
            synchronizeSafeAreaInsets(for: systemWindow, window: window)

            let sizeInt = SizeInt(width: Int(renderSize.width), height: Int(renderSize.height))
            unsafe try? RenderEngine.shared.createWindow(window.id, for: metalView, size: sizeInt)

            super.createWindow(for: window)
        }

        override func menuBuilder(for window: UIWindow) -> (any UIMenuBuilder)? {
            if let builder = self.menus[window.id] {
                return builder
            } else {
                let builder = MacOSUIMenuBuilder(window: window)
                self.menus[window.id] = builder
                return builder
            }
        }

        override func showWindow(_ window: UIWindow, isFocused: Bool) {
            guard let nsWindow = window.systemWindow as? NSWindow else {
                fatalError("System window not exist.")
            }

            if nsWindow.isMiniaturized {
                nsWindow.deminiaturize(nil)
            }

            if windowsPendingInitialCenter.remove(window.id) != nil {
                nsWindow.center()
            }

            if isFocused {
                nsWindow.makeKeyAndOrderFront(nil)
            } else if shouldOrderFrontRegardless(window) {
                nsWindow.orderFrontRegardless()
            } else {
                nsWindow.orderFront(nil)
            }

            applyTrafficLightOffset(window.configuration.titleBar.trafficLightOffset, to: nsWindow)

            window.windowDidAppear()
            if isFocused {
                self.setActiveWindow(window)
            }
        }

        override func setWindowMode(_ window: UIWindow, mode: UIWindow.Mode) {
            guard let nsWindow = window.systemWindow as? NSWindow else {
                fatalError("System window not exist.")
            }

            let isFullScreen = nsWindow.styleMask.contains(.fullScreen)

            switch mode {
            case .windowed:
                if isFullScreen {
                    nsWindow.toggleFullScreen(nil)
                }
                window.isFullscreen = false

            case .fullscreen:
                if !isFullScreen {
                    nsWindow.toggleFullScreen(nil)
                }
                window.isFullscreen = true

            case .fullScreenWindowed:
                if isFullScreen {
                    nsWindow.toggleFullScreen(nil)
                }
                windowsPendingInitialCenter.remove(window.id)
                let screenFrame =
                    preferredScreen(for: window.configuration.screenPreference)?.visibleFrame
                    ?? nsWindow.screen?.visibleFrame
                    ?? screenManager.primaryScreen()?.visibleFrame
                if let screenFrame {
                    nsWindow.setFrame(screenFrame, display: true)
                }
                window.isFullscreen = false
            }
        }

        override func closeWindow(_ window: UIWindow) {
            guard let nsWindow = window.systemWindow as? NSWindow else {
                fatalError("System window not exist.")
            }

            let isTransientBorderlessWindow = window.configuration.chrome == .borderless && window.configuration.background.isTransparent
            if isTransientBorderlessWindow {
                nsWindow.orderOut(nil)
            }

            self.removeWindow(window, setActiveAnotherIfNeeded: !isTransientBorderlessWindow)
            windowsPendingInitialCenter.remove(window.id)
            removeTrafficLightState(for: nsWindow)

            if !isTransientBorderlessWindow {
                nsWindow.close()
            }
        }

        override func resizeWindow(_ window: UIWindow, size: Size) {
            guard !windowsSynchronizingFromSystem.contains(window.id) else {
                return
            }

            let nsWindow = window.systemWindow as? NSWindow

            let cgSize = CGSize(width: CGFloat(size.width), height: CGFloat(size.height))
            if nsWindow?.contentView?.frame.size != cgSize {
                nsWindow?.setContentSize(cgSize)
            }
        }

        override func setMinimumSize(_ size: Size, for window: UIWindow) {
            guard let nsWindow = window.systemWindow as? NSWindow else {
                fatalError("System window not exist.")
            }

            let minSize = CGSize(width: CGFloat(size.width), height: CGFloat(size.height))

            nsWindow.contentMinSize = minSize
            nsWindow.minSize = minSize
        }

        override func getScreen(for window: UIWindow) -> Screen? {
            guard
                let nsWindow = window.systemWindow as? NSWindow,
                let screen = screenManager.screen(containing: nsWindow.frame) ?? nsWindow.screen
            else {
                return nil
            }

            return screenManager.makeScreen(from: screen)
        }

        private var currentShape: Input.CursorShape = .arrow
        private var mouseMode: Input.MouseMode = .visible
        private var cursors: [Input.CursorShape: (NSCursor, Texture2D, Vector2)] = [:]

        override func setCursorShape(_ shape: Input.CursorShape) {
            self.currentShape = shape

            var cursor = NSCursor.current

            switch shape {
            case .arrow:
                cursor = .arrow
            case .pointingHand:
                cursor = .pointingHand
            case .iBeam:
                cursor = .iBeam
            case .wait:
                cursor = .arrow
            case .cross:
                cursor = .crosshair
            case .busy:
                cursor = .arrow
            case .drag:
                cursor = .dragCopy
            case .drop:
                cursor = .openHand
            case .resizeLeft:
                cursor = .resizeLeft
            case .resizeRight:
                cursor = .resizeRight
            case .resizeLeftRight:
                cursor = .resizeLeftRight
            case .resizeUp:
                cursor = .resizeUp
            case .resizeDown:
                cursor = .resizeDown
            case .resizeUpDown:
                cursor = .resizeUpDown
            case .move:
                cursor = .closedHand
            case .forbidden:
                cursor = .operationNotAllowed
            case .help:
                break
            }

            cursor.set()
        }

        override func updateCursor() {
            if let customCursor = self.cursors[self.currentShape]?.0 {
                customCursor.set()
            } else {
                self.setCursorShape(self.currentShape)
            }
        }

        override func getCursorShape() -> Input.CursorShape {
            return self.currentShape
        }

        override func setCursorImage(for shape: Input.CursorShape, texture: Texture2D?, hotspot: Vector2) {
            defer {
                updateCursor()
            }

            guard let texture else {
                self.cursors[shape] = nil

                return
            }

            if self.cursors[shape]?.1 === texture && self.cursors[shape]?.2 == hotspot {
                return
            }

            var position: Vector2 = .one

            if let atlas = texture as? TextureAtlas.Slice {
                position = atlas.position
            }

            let image = texture.image
            guard
                let bitmap = unsafe NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: texture.width,
                    pixelsHigh: texture.height,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bitmapFormat: NSBitmapImageRep.Format(),
                    bytesPerRow: texture.width * 4,
                    bitsPerPixel: 32
                )
            else {
                return
            }

            guard let pixels = unsafe bitmap.bitmapData else {
                return
            }

            let length = texture.height * texture.width

            for index in 0..<length {
                let rowIndex = index / texture.width + Int(position.y)
                let columnIndex = index % texture.width + Int(position.x)

                let color = image.getPixel(x: columnIndex, y: rowIndex)

                unsafe pixels[index * 4 + 0] = UInt8(clamp(color.red * 255.0, 0, 255))
                unsafe pixels[index * 4 + 1] = UInt8(clamp(color.green * 255.0, 0, 255))
                unsafe pixels[index * 4 + 2] = UInt8(clamp(color.blue * 255.0, 0, 255))
                unsafe pixels[index * 4 + 3] = UInt8(clamp(color.alpha * 255.0, 0, 255))
            }

            let nsImage = NSImage(size: CGSize(width: CGFloat(texture.width), height: CGFloat(texture.height)))
            nsImage.addRepresentation(bitmap)
            let cursor = NSCursor(
                image: nsImage,
                hotSpot: CGPoint(x: CGFloat(hotspot.x), y: CGFloat(hotspot.y))
            )

            self.cursors[shape] = (cursor, texture, hotspot)
        }

        override func setMouseMode(_ mode: Input.MouseMode) {
            if self.mouseMode == mode {
                return
            }

            self.mouseMode = mode

            switch mode {
            case .captured:
                break
            case .visible:
                NSCursor.unhide()
            case .hidden:
                NSCursor.hide()
            case .confinedHidden:
                break
            case .confined:
                break
            }
        }

        override func getMouseMode() -> Input.MouseMode {
            self.mouseMode
        }

        func findWindow(for nsWindow: NSWindow) -> UIWindow? {
            return self.windows.first {
                ($0.systemWindow as? NSWindow) === nsWindow
            }
        }

        func synchronizeRenderMetrics(for nsWindow: NSWindow, window: UIWindow, updateWindowFrame: Bool) {
            let size = nsWindow.size

            if updateWindowFrame && window.frame.size != size {
                windowsSynchronizingFromSystem.insert(window.id)
                defer {
                    windowsSynchronizingFromSystem.remove(window.id)
                }
                window.frame = Rect(origin: .zero, size: size)
            }

            if let metalView = nsWindow.contentView?.subviews.first(where: { $0 is MetalView }) as? MetalView {
                metalView.updateDrawableMetrics()
            }

            window.setNeedsLayout()
            synchronizeSafeAreaInsets(for: nsWindow, window: window)
            applyTrafficLightOffset(window.configuration.titleBar.trafficLightOffset, to: nsWindow)

            let sizeInt = SizeInt(width: Int(size.width), height: Int(size.height))
            unsafe try? RenderEngine.shared.resizeWindow(window.id, newSize: sizeInt)
        }

        private func configureTitleBar(for nsWindow: NSWindow, configuration: UIWindow.TitleBar) {
            switch configuration.background {
            case .system:
                nsWindow.titlebarAppearsTransparent = false
                nsWindow.titleVisibility = .visible
            case .transparent:
                nsWindow.titlebarAppearsTransparent = true
                nsWindow.titleVisibility = .hidden
            }
            applyTrafficLightOffset(configuration.trafficLightOffset, to: nsWindow)
        }

        private func applyTrafficLightOffset(_ offset: Point?, to nsWindow: NSWindow) {
            let windowID = ObjectIdentifier(nsWindow)
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

            guard let offset else {
                if let defaultOrigins = trafficLightDefaultOrigins[windowID] {
                    for buttonType in buttons {
                        guard
                            let button = nsWindow.standardWindowButton(buttonType),
                            let defaultOrigin = defaultOrigins[buttonType]
                        else {
                            continue
                        }

                        button.setFrameOrigin(defaultOrigin)
                    }
                }

                trafficLightDefaultOrigins.removeValue(forKey: windowID)
                trafficLightAppliedOrigins.removeValue(forKey: windowID)
                return
            }

            nsWindow.layoutIfNeeded()
            unsafe nsWindow.standardWindowButton(.closeButton)?.superview?.layoutSubtreeIfNeeded()

            var defaultOrigins = trafficLightDefaultOrigins[windowID, default: [:]]
            var appliedOrigins = trafficLightAppliedOrigins[windowID, default: [:]]

            for buttonType in buttons {
                guard let button = nsWindow.standardWindowButton(buttonType) else {
                    continue
                }

                let currentOrigin = button.frame.origin
                let defaultOrigin: NSPoint
                if let previousAppliedOrigin = appliedOrigins[buttonType],
                    previousAppliedOrigin == currentOrigin,
                    let previousDefaultOrigin = defaultOrigins[buttonType] {
                    defaultOrigin = previousDefaultOrigin
                } else {
                    defaultOrigin = currentOrigin
                }

                let appliedOrigin = NSPoint(
                    x: defaultOrigin.x + CGFloat(offset.x),
                    y: defaultOrigin.y - CGFloat(offset.y)
                )

                defaultOrigins[buttonType] = defaultOrigin
                appliedOrigins[buttonType] = appliedOrigin
                button.setFrameOrigin(appliedOrigin)
            }

            trafficLightDefaultOrigins[windowID] = defaultOrigins
            trafficLightAppliedOrigins[windowID] = appliedOrigins
        }

        func removeTrafficLightState(for nsWindow: NSWindow) {
            let windowID = ObjectIdentifier(nsWindow)
            trafficLightDefaultOrigins.removeValue(forKey: windowID)
            trafficLightAppliedOrigins.removeValue(forKey: windowID)
        }

        private func synchronizeSafeAreaInsets(for nsWindow: NSWindow, window: UIWindow) {
            let titleBarOverlaysContent = nsWindow.styleMask.contains(.fullSizeContentView)
            let topInset: Float
            if titleBarOverlaysContent && window.configuration.titleBar.reservesSafeArea {
                topInset = Float(max(0, nsWindow.frame.height - nsWindow.contentLayoutRect.height))
            } else {
                topInset = 0
            }

            let insets = EdgeInsets(top: topInset, leading: 0, bottom: 0, trailing: 0)
            guard window.safeAreaInsets != insets else {
                return
            }

            window.safeAreaInsets = insets
            for subview in window.subviews {
                subview.safeAreaInsets = insets
                subview.setNeedsLayout()
            }
        }

        private func backgroundColor(for background: UIWindow.Background) -> NSColor {
            switch background {
            case .transparent:
                return .clear
            case let .opaque(color):
                return NSColor(
                    red: CGFloat(color.red),
                    green: CGFloat(color.green),
                    blue: CGFloat(color.blue),
                    alpha: CGFloat(color.alpha)
                )
            }
        }

        private func visualEffectView(for effect: UIWindow.BackgroundEffect, frame: NSRect) -> NSView? {
            guard case let .blur(material) = effect else {
                return nil
            }

            var visualEffectView: NSView

            if #available(macOS 26.0, *), material == .glass {
                let view = NSGlassEffectView(frame: frame)
                view.style = .regular
                //            view.tintColor = NSColor.controlAccentColor.withAlphaComponent(0.05)
                visualEffectView = view
            } else {
                let view = NSVisualEffectView(frame: frame)
                view.material = nsVisualEffectMaterial(for: material)
                view.blendingMode = .behindWindow
                view.state = .active
                visualEffectView = view
            }

            visualEffectView.autoresizingMask = [.width, .height]
            visualEffectView.appearance = NSAppearance(named: .vibrantDark)
            visualEffectView.wantsLayer = true

            return visualEffectView
        }

        private func nsVisualEffectMaterial(for material: UIWindow.BackgroundEffect.BlurMaterial) -> NSVisualEffectView.Material {
            switch material {
            case .windowBackground:
                return .windowBackground
            case .hudWindow:
                return .hudWindow
            case .sidebar:
                return .sidebar
            case .popover:
                return .popover
            case .contentBackground:
                return .contentBackground
            case .underWindowBackground:
                return .underWindowBackground
            default:
                return .windowBackground
            }
        }

        private func windowLevel(for level: UIWindow.Level) -> NSWindow.Level {
            switch level {
            case .normal:
                return .normal
            case .floating:
                return .floating
            case .statusBar:
                return .screenSaver
            }
        }

        private func collectionBehavior(for behavior: UIWindow.CollectionBehavior) -> NSWindow.CollectionBehavior {
            switch behavior {
            case .standard:
                return .fullScreenPrimary
            case .allSpacesStationary:
                return [.canJoinAllSpaces, .stationary, .ignoresCycle]
            }
        }

        private func shouldOrderFrontRegardless(_ window: UIWindow) -> Bool {
            switch window.configuration.level {
            case .normal:
                switch window.configuration.collectionBehavior {
                case .standard:
                    return false
                case .allSpacesStationary:
                    return true
                }
            case .floating,
                .statusBar:
                return true
            }
        }

        private func preferredScreen(for preference: WindowScreenPreference?) -> NSScreen? {
            guard let preference else {
                return nil
            }

            let screens = NSScreen.screens
            switch preference {
            case .main:
                return screenManager.primaryScreen()
            case let .index(index):
                return screen(at: index, in: screens)
            case let .external(index):
                let mainScreen = screenManager.primaryScreen()
                let externalScreens = screens.filter { screen in
                    guard let mainScreen else {
                        return true
                    }

                    return screen !== mainScreen
                }

                return screen(at: index, in: externalScreens) ?? screen(at: index, in: screens)
            }
        }

        private func screen(at index: Int, in screens: [NSScreen]) -> NSScreen? {
            guard index >= 0 && index < screens.count else {
                return nil
            }

            return screens[index]
        }

        private func center(_ window: NSWindow, on screen: NSScreen) {
            let screenFrame = screen.visibleFrame
            let windowFrame = window.frame
            let origin = NSPoint(
                x: screenFrame.midX - windowFrame.width / 2,
                y: screenFrame.midY - windowFrame.height / 2
            )
            window.setFrameOrigin(origin)
        }
    }

    // MARK: - NSWindowDelegate

    final class NSWindowDelegateObject: NSObject, NSWindowDelegate {
        unowned let windowManager: MacOSWindowManager

        init(windowManager: MacOSWindowManager) {
            self.windowManager = windowManager
        }

        // MARK: NSWindowDelegate impl

        func windowWillClose(_ notification: Notification) {
            guard
                let nsWindow = notification.object as? NSWindow,
                let window = self.windowManager.findWindow(for: nsWindow)
            else {
                return
            }

            self.windowManager.removeTrafficLightState(for: nsWindow)
            self.windowManager.removeWindow(window)
        }

        func windowDidBecomeKey(_ notification: Notification) {
            guard
                let nsWindow = notification.object as? NSWindow,
                let window = self.windowManager.findWindow(for: nsWindow)
            else {
                return
            }

            self.windowManager.setActiveWindow(window)
        }

        func windowDidResignKey(_ notification: Notification) {
            guard
                let nsWindow = notification.object as? NSWindow,
                let window = self.windowManager.findWindow(for: nsWindow)
            else {
                return
            }

            self.windowManager.resignActiveWindow(window)
        }

        func windowDidResize(_ notification: Notification) {
            guard
                let nsWindow = notification.object as? NSWindow,
                let window = self.windowManager.findWindow(for: nsWindow)
            else {
                return
            }

            windowManager.synchronizeRenderMetrics(for: nsWindow, window: window, updateWindowFrame: true)
        }

        func windowDidChangeBackingProperties(_ notification: Notification) {
            guard
                let nsWindow = notification.object as? NSWindow,
                let window = self.windowManager.findWindow(for: nsWindow)
            else {
                return
            }

            windowManager.synchronizeRenderMetrics(for: nsWindow, window: window, updateWindowFrame: false)
        }

        func windowDidMiniaturize(_ notification: Notification) {
            guard
                let nsWindow = notification.object as? NSWindow,
                let window = self.windowManager.findWindow(for: nsWindow)
            else {
                return
            }

            NotificationCenter.default.post(name: .adaEngineWindowDidMiniaturize, object: window)
        }

        func windowDidDeminiaturize(_ notification: Notification) {
            guard
                let nsWindow = notification.object as? NSWindow,
                let window = self.windowManager.findWindow(for: nsWindow)
            else {
                return
            }

            NotificationCenter.default.post(name: .adaEngineWindowDidDeminiaturize, object: window)
        }

        func windowDidExitFullScreen(_ notification: Notification) {
            guard
                let nsWindow = notification.object as? NSWindow,
                let window = self.windowManager.findWindow(for: nsWindow)
            else {
                return
            }

            window.isFullscreen = false
        }

        func windowDidEnterFullScreen(_ notification: Notification) {
            guard
                let nsWindow = notification.object as? NSWindow,
                let window = self.windowManager.findWindow(for: nsWindow)
            else {
                return
            }

            window.isFullscreen = true
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard
                let window = self.windowManager.findWindow(for: sender)
            else {
                return true
            }

            return window.windowShouldClose()
        }
    }

    // MARK: - NSWindow + SystemWindow

    extension NSWindow: SystemWindow {
        public var position: Point {
            get {
                return self.frame.origin.toEnginePoint
            }
            set {
                self.setFrameOrigin(NSPoint(x: CGFloat(newValue.x), y: CGFloat(newValue.y)))
            }
        }

        public var size: Size {
            get {
                // we always should contain content view
                guard let contentView else {
                    preconditionFailure("Engine windows must contain a content view.")
                }
                return contentView.frame.size.toEngineSize
            }
            set {
                self.setContentSize(NSSize(width: CGFloat(newValue.width), height: CGFloat(newValue.height)))
            }
        }
    }

    final class MacOSUIMenuBuilder: UIMenuBuilder {
        private weak var window: UIWindow?
        private var isNeedsUpdate = true

        private var menu: NSMenu {
            if let mainMenu = NSApp.mainMenu {
                ensureApplicationMenu(in: mainMenu)
                return mainMenu
            }

            let mainMenu = NSMenu(title: "")
            NSApp.mainMenu = mainMenu
            ensureApplicationMenu(in: mainMenu)
            return mainMenu
        }

        init(window: UIWindow) {
            self.window = window
        }

        func insert(_ menu: UIMenu) {
            menu.setMenuOwner(self)
            remove(menu.id)

            if menu.placement == .application,
                let applicationMenu = self.menu.items.first?.submenu {
                let insertionIndex = min(2, applicationMenu.items.count)
                var items = menu.items.map(makeNSMenuItem(from:))
                if !items.isEmpty, items.last?.isSeparatorItem != true {
                    let separator = NSMenuItem.separator()
                    separator.identifier = NSUserInterfaceItemIdentifier(menu.id)
                    items.append(separator)
                }
                for (offset, item) in items.enumerated() {
                    applicationMenu.insertItem(item, at: insertionIndex + offset)
                }
                return
            }

            let nsMenu = makeNSMenu(from: menu)

            let menuItem = NSMenuItem()
            menuItem.title = menu.title
            self.menu.addItem(menuItem)
            self.menu.setSubmenu(nsMenu, for: menuItem)
            configureSystemMenu(nsMenu, for: menu)
        }

        func remove(_ menu: UIMenu.ID) {
            if let item = self.menu.items.first(where: { $0.title == menu }) {
                self.menu.removeItem(item)
            }

            guard let applicationMenu = self.menu.items.first?.submenu else {
                return
            }
            for item in applicationMenu.items.reversed() {
                guard item.identifier?.rawValue == menu else {
                    continue
                }
                applicationMenu.removeItem(item)
            }
        }

        func setNeedsUpdate() {
            self.isNeedsUpdate = true
        }

        func updateIfNeeded() {
            guard isNeedsUpdate else {
                return
            }

            self.window?._buildMenu(with: self)
            self.isNeedsUpdate = false
        }

        private func makeNSMenu(from menu: UIMenu) -> NSMenu {
            let nsMenu = NSMenu(title: menu.title)
            nsMenu.autoenablesItems = false
            let items = menu.items.map(makeNSMenuItem(from:))

            for item in items {
                nsMenu.addItem(item)
            }

            return nsMenu
        }

        private func makeNSMenuItem(from item: MenuItem) -> NSMenuItem {
            if item.isSeparator {
                return .separator()
            }

            let nsItem = NSMenuItem()
            nsItem.title = item.title
            nsItem.identifier = item.menu.map { NSUserInterfaceItemIdentifier($0.id) }
            nsItem.target = self
            nsItem.action = #selector(onActionPressed)
            nsItem.submenu = item.submenu.flatMap { self.makeNSMenu(from: $0) }
            nsItem.representedObject = item
            nsItem.isEnabled = item.isEnabled
            // Disabled placeholder items must not reserve their key equivalents.
            // AppKit otherwise consumes shortcuts such as Command-Z before the
            // focused AdaUI node can handle them.
            if item.isEnabled, let key = item.keyEquivalent?.rawValue {
                nsItem.keyEquivalent = key
            }
            if let modifier = item.keyEquivalentModifierMask {
                nsItem.keyEquivalentModifierMask = makeKeyModifierMask(from: modifier)
            }

            return nsItem
        }

        private func makeKeyModifierMask(from modifier: KeyModifier) -> NSEvent.ModifierFlags {
            var keyModifiers = NSEvent.ModifierFlags()

            if modifier.contains(.alt) {
                keyModifiers.insert(.option)
            }

            if modifier.contains(.main) {
                keyModifiers.insert(.command)
            }

            if modifier.contains(.control) {
                keyModifiers.insert(.control)
            }

            if modifier.contains(.shift) {
                keyModifiers.insert(.shift)
            }

            if modifier.contains(.capsLock) {
                keyModifiers.insert(.capsLock)
            }

            return keyModifiers
        }

        private func configureSystemMenu(_ nsMenu: NSMenu, for menu: UIMenu) {
            switch menu.title {
            case "Window":
                NSApp.windowsMenu = nsMenu
            case "Help":
                NSApp.helpMenu = nsMenu
            default:
                break
            }
        }

        private var applicationName: String {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? ProcessInfo.processInfo.processName
        }

        private func ensureApplicationMenu(in mainMenu: NSMenu) {
            let appName = applicationName
            if let applicationMenuItem = mainMenu.items.first,
                let applicationMenu = applicationMenuItem.submenu {
                applicationMenuItem.title = appName
                applicationMenu.title = appName
                if applicationMenu.items.isEmpty {
                    populateApplicationMenu(applicationMenu, appName: appName)
                }
                return
            }

            let applicationMenu = NSMenu(title: appName)
            let applicationMenuItem = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
            mainMenu.insertItem(applicationMenuItem, at: 0)
            mainMenu.setSubmenu(applicationMenu, for: applicationMenuItem)
            populateApplicationMenu(applicationMenu, appName: appName)
        }

        private func populateApplicationMenu(_ appMenu: NSMenu, appName: String) {
            appMenu.addItem(
                withTitle: "About \(appName)",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                keyEquivalent: ""
            )
            appMenu.addItem(.separator())

            let servicesMenu = NSMenu(title: "Services")
            let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
            servicesItem.submenu = servicesMenu
            appMenu.addItem(servicesItem)
            NSApp.servicesMenu = servicesMenu
            appMenu.addItem(.separator())

            appMenu.addItem(
                withTitle: "Hide \(appName)",
                action: #selector(NSApplication.hide(_:)),
                keyEquivalent: "h"
            )
            appMenu.addItem(
                withTitle: "Hide Others",
                action: #selector(NSApplication.hideOtherApplications(_:)),
                keyEquivalent: "h"
            )
            .keyEquivalentModifierMask = [.command, .option]
            appMenu.addItem(
                withTitle: "Show All",
                action: #selector(NSApplication.unhideAllApplications(_:)),
                keyEquivalent: ""
            )
            appMenu.addItem(.separator())
            appMenu.addItem(
                withTitle: "Quit \(appName)",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        }

        @objc func onActionPressed(_ nsItem: NSMenuItem) {
            guard let item = nsItem.representedObject as? MenuItem else {
                return
            }

            item.action?()
        }
    }

#endif
