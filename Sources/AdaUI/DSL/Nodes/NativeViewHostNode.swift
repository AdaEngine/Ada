//
//  NativeViewHostNode.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 21.04.2026.
//

@_spi(Internal) import AdaInput
@_spi(Internal) import AdaRender
import AdaUtils
import Math

#if canImport(MapKit)
    import MapKit
#endif

#if canImport(AppKit) || canImport(UIKit)

    /// An internal protocol to unify AppKit and UIKit representables.
    @MainActor
    protocol NativeViewRepresentableInternal {
        func makeNativeView(context: NativeViewHostContext) -> Any
        func updateNativeView(_ view: Any, context: NativeViewHostContext)
        func sizeThatFits(_ proposal: ProposedViewSize, view: Any, context: NativeViewHostContext) -> Size
        func makeNativeCoordinator() -> Any
        func dismantleNativeView(_ view: Any, coordinator: Any)
    }

    struct NativeViewHostContext {
        let environment: EnvironmentValues
        let coordinator: Any
    }

    #if canImport(AppKit) && os(macOS)
        import AppKit

        extension AppKitViewRepresentable {
            func makeNativeView(context: NativeViewHostContext) -> Any {
                let ctx = AppKitViewRepresentableContext<Self>(
                    environment: context.environment,
                    coordinator: context.coordinator as! Coordinator
                )
                return self.makeNSView(context: ctx)
            }

            func updateNativeView(_ view: Any, context: NativeViewHostContext) {
                let ctx = AppKitViewRepresentableContext<Self>(
                    environment: context.environment,
                    coordinator: context.coordinator as! Coordinator
                )
                self.updateNSView(view as! NSViewType, context: ctx)
            }

            func sizeThatFits(_ proposal: ProposedViewSize, view: Any, context: NativeViewHostContext) -> Size {
                let ctx = AppKitViewRepresentableContext<Self>(
                    environment: context.environment,
                    coordinator: context.coordinator as! Coordinator
                )
                return self.sizeThatFits(proposal, nsView: view as! NSViewType, context: ctx)
            }

            func makeNativeCoordinator() -> Any {
                return (self as Self).makeCoordinator()
            }

            func dismantleNativeView(_ view: Any, coordinator: Any) {
                Self.dismantleNSView(view as! NSViewType, coordinator: coordinator as! Coordinator)
            }
        }

        extension AppKitViewRepresentableView: NativeViewRepresentableInternal {
            func makeNativeView(context: NativeViewHostContext) -> Any {
                representable.makeNativeView(context: context)
            }
            func updateNativeView(_ view: Any, context: NativeViewHostContext) {
                representable.updateNativeView(view, context: context)
            }
            func sizeThatFits(_ proposal: ProposedViewSize, view: Any, context: NativeViewHostContext) -> Size {
                representable.sizeThatFits(proposal, view: view, context: context)
            }
            func makeNativeCoordinator() -> Any {
                representable.makeNativeCoordinator()
            }
            func dismantleNativeView(_ view: Any, coordinator: Any) {
                representable.dismantleNativeView(view, coordinator: coordinator)
            }
        }

    #endif

    #if canImport(UIKit) && (os(iOS) || os(tvOS) || os(visionOS))
        import UIKit

        extension UIKitViewRepresentable {
            func makeNativeView(context: NativeViewHostContext) -> Any {
                let ctx = UIKitViewRepresentableContext<Self>(
                    environment: context.environment,
                    coordinator: context.coordinator as! Coordinator
                )
                return self.makeUIView(context: ctx)
            }

            func updateNativeView(_ view: Any, context: NativeViewHostContext) {
                let ctx = UIKitViewRepresentableContext<Self>(
                    environment: context.environment,
                    coordinator: context.coordinator as! Coordinator
                )
                self.updateUIView(view as! UIViewType, in: ctx)
            }

            func sizeThatFits(_ proposal: ProposedViewSize, view: Any, context: NativeViewHostContext) -> Size {
                let ctx = UIKitViewRepresentableContext<Self>(
                    environment: context.environment,
                    coordinator: context.coordinator as! Coordinator
                )
                return self.sizeThatFits(proposal, uiView: view as! UIViewType, context: ctx)
            }

            func makeNativeCoordinator() -> Any {
                return (self as Self).makeCoordinator()
            }

            func dismantleNativeView(_ view: Any, coordinator: Any) {
                Self.dismantleUIView(view as! UIViewType, coordinator: coordinator as! Coordinator)
            }
        }

        extension UIKitViewRepresentableView: NativeViewRepresentableInternal {
            func makeNativeView(context: NativeViewHostContext) -> Any {
                representable.makeNativeView(context: context)
            }
            func updateNativeView(_ view: Any, context: NativeViewHostContext) {
                representable.updateNativeView(view, context: context)
            }
            func sizeThatFits(_ proposal: ProposedViewSize, view: Any, context: NativeViewHostContext) -> Size {
                representable.sizeThatFits(proposal, view: view, context: context)
            }
            func makeNativeCoordinator() -> Any {
                representable.makeNativeCoordinator()
            }
            func dismantleNativeView(_ view: Any, coordinator: Any) {
                representable.dismantleNativeView(view, coordinator: coordinator)
            }
        }

    #endif

    @MainActor
    final class NativeViewHostNode: ViewNode {
        private var representable: any NativeViewRepresentableInternal
        private var nativeView: Any?
        private var coordinator: Any?

        private var offscreenTexture: Texture2D?
        private var isOverlayAttached = false
        private let offscreenSupersamplingMultiplier: Float = 2
        private let maxOffscreenScale: Float = 4
        #if canImport(UIKit) && (os(iOS) || os(tvOS) || os(visionOS))
            private var lastOffscreenTouchLocation: Point?
        #endif
        #if canImport(AppKit) && os(macOS)
            private weak var activeAppKitMouseTarget: NSView?
            private weak var activeAppKitPressedControl: NSControl?
        #endif

        init<V: View>(representable: any NativeViewRepresentableInternal, content: V) {
            self.representable = representable
            super.init(content: content)
        }

        override func performLayout() {
            super.performLayout()

            if coordinator == nil {
                coordinator = representable.makeNativeCoordinator()
            }
            guard let coordinator else {
                preconditionFailure("Native view representables must create a coordinator.")
            }

            let context = NativeViewHostContext(environment: self.environment, coordinator: coordinator)

            if nativeView == nil {
                nativeView = representable.makeNativeView(context: context)
            }
            guard let nativeView else {
                preconditionFailure("Native view representables must create a native view.")
            }

            representable.updateNativeView(nativeView, context: context)

            let mode = resolvedRenderingMode()
            switch mode {
            case .overlay:
                updateOverlay()
            case .offscreen:
                updateOffscreen()
            @unknown default:
                break
            }
        }

        override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
            if coordinator == nil {
                coordinator = representable.makeNativeCoordinator()
            }
            guard let coordinator else {
                preconditionFailure("Native view representables must create a coordinator.")
            }

            if nativeView == nil {
                let context = NativeViewHostContext(environment: self.environment, coordinator: coordinator)
                nativeView = representable.makeNativeView(context: context)
            }
            guard let nativeView else {
                preconditionFailure("Native view representables must create a native view.")
            }

            let context = NativeViewHostContext(environment: self.environment, coordinator: coordinator)
            return representable.sizeThatFits(proposal, view: nativeView, context: context)
        }

        private func updateOverlay() {
            guard let nativeView = self.nativeView else {
                return
            }

            // Ensure offscreen resources are cleaned up
            self.offscreenTexture = nil

            guard let window = self.owner?.window, let systemWindow = window.systemWindow else {
                detachFromOverlay()
                return
            }

            #if canImport(AppKit) && os(macOS)
                if let nsWindow = systemWindow as? NSWindow, let overlayHostView = nsWindow.contentView, let nsView = nativeView as? NSView {
                    if unsafe nsView.superview !== overlayHostView {
                        overlayHostView.addSubview(nsView)
                        isOverlayAttached = true
                    }

                    let absoluteFrame = self.visualAbsoluteFrame()
                    // In AppKit, Y-axis is flipped compared to AdaUI (which uses top-left origin)
                    let windowHeight = Float(nsWindow.contentRect(forFrameRect: nsWindow.frame).height)
                    nsView.frame = NSRect(
                        x: CGFloat(absoluteFrame.origin.x),
                        y: CGFloat(windowHeight - absoluteFrame.origin.y - absoluteFrame.size.height),
                        width: CGFloat(absoluteFrame.size.width),
                        height: CGFloat(absoluteFrame.size.height)
                    )

                    // Clipping
                    let visibleFrame = self.calculateVisibleFrame()
                    if visibleFrame.size.width < absoluteFrame.size.width || visibleFrame.size.height < absoluteFrame.size.height {
                        let maskLayer = CAShapeLayer()
                        // Convert visible frame to local view coordinates
                        let localVisibleFrame = Rect(
                            origin: Point(x: visibleFrame.origin.x - absoluteFrame.origin.x, y: visibleFrame.origin.y - absoluteFrame.origin.y),
                            size: visibleFrame.size
                        )
                        if nsView.layer == nil {
                            nsView.wantsLayer = true
                        }
                        let maskRect = appKitMaskRectInBoundsCoordinates(from: localVisibleFrame, nsView: nsView)
                        maskLayer.path = NSBezierPath(rect: maskRect).cgPath
                        nsView.layer?.mask = maskLayer
                    } else {
                        nsView.layer?.mask = nil
                    }

                    nsView.isHidden = false
                }
            #elseif canImport(UIKit) && (os(iOS) || os(tvOS) || os(visionOS))
                if let uiView = nativeView as? UIKit.UIView {
                    // UIKit implementation
                    if let parent = findUIKitParentView() {
                        if uiView.superview != parent {
                            parent.addSubview(uiView)
                            isOverlayAttached = true
                        }
                        let absoluteFrame = self.visualAbsoluteFrame()
                        uiView.frame = CGRect(
                            x: CGFloat(absoluteFrame.origin.x),
                            y: CGFloat(absoluteFrame.origin.y),
                            width: CGFloat(absoluteFrame.size.width),
                            height: CGFloat(absoluteFrame.size.height)
                        )

                        // Clipping
                        let visibleFrame = self.calculateVisibleFrame()
                        if visibleFrame.size.width < absoluteFrame.size.width || visibleFrame.size.height < absoluteFrame.size.height {
                            let maskView = UIKit.UIView()
                            let localVisibleFrame = Rect(
                                origin: Point(x: visibleFrame.origin.x - absoluteFrame.origin.x, y: visibleFrame.origin.y - absoluteFrame.origin.y),
                                size: visibleFrame.size
                            )
                            maskView.frame = localVisibleFrame.toCGRect
                            maskView.backgroundColor = .black
                            uiView.mask = maskView
                        } else {
                            uiView.mask = nil
                        }

                        uiView.isHidden = false
                    }
                }
            #endif
        }

        private func detachFromOverlay() {
            guard isOverlayAttached, let nativeView = self.nativeView else {
                return
            }

            #if canImport(AppKit) && os(macOS)
                if let nsView = nativeView as? NSView {
                    nsView.removeFromSuperview()
                }
            #elseif canImport(UIKit) && (os(iOS) || os(tvOS) || os(visionOS))
                if let uiView = nativeView as? UIKit.UIView {
                    uiView.removeFromSuperview()
                }
            #endif

            isOverlayAttached = false
        }

        private func updateOffscreen() {
            detachFromOverlay()
            prepareNativeViewForOffscreenRendering()
        }

        override func didMove(to parent: ViewNode?) {
            super.didMove(to: parent)

            if parent == nil {
                cleanupNativeView()
            }
        }

        override func update(from newNode: ViewNode) {
            guard let newNode = newNode as? NativeViewHostNode else {
                super.update(from: newNode)
                return
            }

            self.representable = newNode.representable
            super.update(from: newNode)
        }

        #if canImport(UIKit) && (os(iOS) || os(tvOS) || os(visionOS))
            private func findUIKitParentView() -> UIKit.UIView? {
                return nil  // To be implemented
            }
        #endif

        override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
            if self.point(inside: point, with: event) {
                return self
            }
            return nil
        }

        override func point(inside point: Point, with _: any InputEvent) -> Bool {
            return point.x >= 0 && point.y >= 0 && point.x <= frame.width && point.y <= frame.height
        }

        override func onMouseEvent(_ event: MouseEvent) {
            if resolvedRenderingMode() == .offscreen {
                if event.button == .scrollWheel {
                    forwardScrollEvent(event)
                } else {
                    forwardMouseEvent(event)
                }
            }
        }

        private func forwardMouseEvent(_ event: MouseEvent) {
            guard let nativeView = self.nativeView else {
                return
            }

            #if canImport(AppKit) && os(macOS)
                if let nsView = nativeView as? NSView, let nsWindow = owner?.window?.systemWindow as? NSWindow {
                    let timestamp = Double(event.time)
                    let eventType: NSEvent.EventType

                    switch event.phase {
                    case .began:
                        switch event.button {
                        case .left:
                            eventType = .leftMouseDown
                        case .right:
                            eventType = .rightMouseDown
                        case .middle:
                            eventType = .otherMouseDown
                        case .none,
                            .scrollWheel:
                            return
                        }
                    case .changed:
                        switch event.button {
                        case .left:
                            eventType = .leftMouseDragged
                        case .right:
                            eventType = .rightMouseDragged
                        case .middle:
                            eventType = .otherMouseDragged
                        case .none,
                            .scrollWheel:
                            return
                        }
                    case .ended:
                        switch event.button {
                        case .left:
                            eventType = .leftMouseUp
                        case .right:
                            eventType = .rightMouseUp
                        case .middle:
                            eventType = .otherMouseUp
                        case .none,
                            .scrollWheel:
                            return
                        }
                    case .cancelled:
                        activeAppKitMouseTarget = nil
                        activeAppKitPressedControl = nil
                        return
                    }

                    let windowPoint = appKitWindowPoint(from: event.mousePosition, in: nsWindow)
                    let localPoint = appKitLocalPoint(from: event.mousePosition, in: nsView)
                    let currentHitView = nsView.hitTest(localPoint)
                    let targetView: NSView

                    switch event.phase {
                    case .began:
                        targetView = currentHitView ?? nsView
                        activeAppKitMouseTarget = targetView
                        activeAppKitPressedControl = nearestAppKitControl(from: targetView)
                    case .changed,
                        .ended:
                        targetView = activeAppKitMouseTarget ?? currentHitView ?? nsView
                    case .cancelled:
                        targetView = nsView
                    }

                    if let nsEvent = NSEvent.mouseEvent(
                        with: eventType,
                        location: windowPoint,
                        modifierFlags: appKitModifierFlags(from: event.modifierKeys),
                        timestamp: timestamp,
                        windowNumber: nsWindow.windowNumber,
                        context: nil,
                        eventNumber: 0,
                        clickCount: 1,
                        pressure: event.phase == .ended ? 0.0 : 1.0
                    ) {
                        switch eventType {
                        case .leftMouseDown:
                            targetView.mouseDown(with: nsEvent)
                        case .leftMouseUp:
                            targetView.mouseUp(with: nsEvent)
                        case .leftMouseDragged:
                            targetView.mouseDragged(with: nsEvent)
                        case .rightMouseDown:
                            targetView.rightMouseDown(with: nsEvent)
                        case .rightMouseUp:
                            targetView.rightMouseUp(with: nsEvent)
                        case .rightMouseDragged:
                            targetView.rightMouseDragged(with: nsEvent)
                        case .otherMouseDown:
                            targetView.otherMouseDown(with: nsEvent)
                        case .otherMouseUp:
                            targetView.otherMouseUp(with: nsEvent)
                        case .otherMouseDragged:
                            targetView.otherMouseDragged(with: nsEvent)
                        default: break
                        }
                    }

                    if event.phase == .ended {
                        let releasedControl = currentHitView.flatMap { nearestAppKitControl(from: $0) }
                        if let pressedControl = activeAppKitPressedControl,
                            releasedControl === pressedControl {
                            triggerAppKitControlClickFallback(pressedControl)
                        }
                        activeAppKitMouseTarget = nil
                        activeAppKitPressedControl = nil
                    }
                }
            #endif
        }

        private func forwardScrollEvent(_ event: MouseEvent) {
            #if canImport(AppKit) && os(macOS)
                guard let nsView = nativeView as? NSView, let nsWindow = owner?.window?.systemWindow as? NSWindow else {
                    return
                }

                let windowPoint = appKitWindowPoint(from: event.mousePosition, in: nsWindow)

                if let cgEvent = CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: .pixel,
                    wheelCount: 2,
                    wheel1: Int32(event.scrollDelta.y),
                    wheel2: Int32(event.scrollDelta.x),
                    wheel3: 0
                ) {
                    cgEvent.location = nsWindow.convertPoint(toScreen: windowPoint)
                    if let nsEvent = NSEvent(cgEvent: cgEvent) {
                        nsView.scrollWheel(with: nsEvent)
                    }
                }
            #endif
        }

        override func onTouchesEvent(_ touches: Set<TouchEvent>) {
            if resolvedRenderingMode() == .offscreen {
                forwardTouchesEvent(touches)
            }
        }

        private func forwardTouchesEvent(_ touches: Set<TouchEvent>) {
            #if canImport(UIKit) && (os(iOS) || os(tvOS) || os(visionOS))
                guard let uiView = nativeView as? UIKit.UIView else {
                    return
                }

                let scrollView = findScrollView(in: uiView)
                for touch in touches {
                    switch touch.phase {
                    case .began:
                        lastOffscreenTouchLocation = touch.location
                    case .moved:
                        if let previousLocation = lastOffscreenTouchLocation, let scrollView {
                            let deltaX = touch.location.x - previousLocation.x
                            let deltaY = touch.location.y - previousLocation.y

                            var offset = scrollView.contentOffset
                            offset.x -= CGFloat(deltaX)
                            offset.y -= CGFloat(deltaY)

                            scrollView.setContentOffset(offset, animated: false)
                        }
                        lastOffscreenTouchLocation = touch.location
                    case .ended:
                        let absoluteOrigin = self.visualAbsoluteFrame().origin
                        let localPoint = CGPoint(
                            x: CGFloat(touch.location.x - absoluteOrigin.x),
                            y: CGFloat(touch.location.y - absoluteOrigin.y)
                        )

                        if let hitView = uiView.hitTest(localPoint, with: nil) {
                            // Try to trigger actions if it's a control
                            if let control = hitView as? UIKit.UIControl {
                                control.sendActions(for: UIKit.UIControl.Event.touchUpInside)
                            }
                        }
                        lastOffscreenTouchLocation = nil
                    case .cancelled:
                        lastOffscreenTouchLocation = nil
                    }
                }
            #endif
        }

        #if canImport(UIKit) && (os(iOS) || os(tvOS) || os(visionOS))
            private func findScrollView(in view: UIKit.UIView) -> UIKit.UIScrollView? {
                if let scrollView = view as? UIKit.UIScrollView {
                    return scrollView
                }
                for subview in view.subviews {
                    if let found = findScrollView(in: subview) {
                        return found
                    }
                }
                return nil
            }
        #endif

        override func draw(with context: UIGraphicsContext) {
            if resolvedRenderingMode() == .offscreen {
                if let texture = offscreenTexture {
                    var context = context
                    context.translateBy(x: self.frame.origin.x, y: -self.frame.origin.y)
                    let rect = Rect(origin: .zero, size: frame.size)
                    context.drawRect(rect, texture: texture, color: .white)
                }
            }
        }

        override func update(_: AdaUtils.TimeInterval) {
            if resolvedRenderingMode() == .offscreen {
                updateOffscreen()
                renderOffscreen()
            } else if resolvedRenderingMode() == .overlay {
                updateOverlay()
            }
        }

        private func renderOffscreen() {
            guard let nativeView = self.nativeView else {
                return
            }
            guard unsafe RenderEngine.shared as RenderEngine? != nil else {
                return
            }

            let size = self.frame.size
            if size.width <= 0 || size.height <= 0 {
                return
            }

            let scale = effectiveOffscreenScale()
            let pixelSize = SizeInt(
                width: Int(size.width * scale),
                height: Int(size.height * scale)
            )

            if offscreenTexture?.width != pixelSize.width || offscreenTexture?.height != pixelSize.height {
                let descriptor = TextureDescriptor(
                    width: pixelSize.width,
                    height: pixelSize.height,
                    pixelFormat: .rgba8,
                    textureUsage: [.read, .write],
                    textureType: .texture2D
                )
                self.offscreenTexture = Texture2D(descriptor: descriptor)
            }

            guard let texture = offscreenTexture else {
                return
            }
            prepareNativeViewForOffscreenRendering(scale: scale)

            #if canImport(AppKit) && os(macOS)
                if let nsView = nativeView as? NSView {
                    let width = pixelSize.width
                    let height = pixelSize.height

                    let colorSpace = CGColorSpaceCreateDeviceRGB()
                    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

                    guard
                        let context = unsafe CGContext(
                            data: nil,
                            width: width,
                            height: height,
                            bitsPerComponent: 8,
                            bytesPerRow: width * 4,
                            space: colorSpace,
                            bitmapInfo: bitmapInfo
                        )
                    else {
                        return
                    }

                    context.translateBy(x: 0, y: CGFloat(height))
                    context.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))

                    if let layer = nsView.layer {
                        layer.render(in: context)
                    } else {
                        let prevContext = NSGraphicsContext.current
                        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: nsView.isFlipped)
                        nsView.displayIgnoringOpacity(nsView.bounds)
                        NSGraphicsContext.current = prevContext
                    }

                    if let data = unsafe context.data {
                        unsafe texture.replaceRegion(
                            RectInt(origin: .zero, size: pixelSize),
                            withBytes: data,
                            bytesPerRow: width * 4
                        )
                    }
                }
            #elseif canImport(UIKit) && (os(iOS) || os(tvOS) || os(visionOS))
                if let uiView = nativeView as? UIKit.UIView {
                    let width = pixelSize.width
                    let height = pixelSize.height

                    let colorSpace = CGColorSpaceCreateDeviceRGB()
                    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

                    guard
                        let context = CGContext(
                            data: nil,
                            width: width,
                            height: height,
                            bitsPerComponent: 8,
                            bytesPerRow: width * 4,
                            space: colorSpace,
                            bitmapInfo: bitmapInfo
                        )
                    else {
                        return
                    }

                    context.translateBy(x: 0, y: CGFloat(height))
                    context.scaleBy(x: CGFloat(scale), y: CGFloat(-scale))

                    uiView.layer.render(in: context)

                    if let data = context.data {
                        texture.replaceRegion(
                            RectInt(origin: .zero, size: pixelSize),
                            withBytes: data,
                            bytesPerRow: width * 4
                        )
                    }
                }
            #endif
        }

        private func prepareNativeViewForOffscreenRendering(scale: Float? = nil) {
            let size = self.frame.size
            guard size.width > 0, size.height > 0 else {
                return
            }

            #if canImport(AppKit) && os(macOS)
                if let nsView = nativeView as? NSView {
                    let targetFrame = NSRect(
                        x: 0,
                        y: 0,
                        width: CGFloat(size.width),
                        height: CGFloat(size.height)
                    )

                    if nsView.frame != targetFrame {
                        nsView.frame = targetFrame
                    }
                    if nsView.bounds != targetFrame {
                        nsView.bounds = targetFrame
                    }

                    nsView.needsLayout = true
                    nsView.layoutSubtreeIfNeeded()
                    nsView.needsDisplay = true
                    nsView.displayIfNeeded()

                    if let layer = nsView.layer {
                        layer.contentsScale = CGFloat(scale ?? max(environment.scaleFactor, 1))
                        layer.setNeedsDisplay()
                        layer.displayIfNeeded()
                    }
                }
            #elseif canImport(UIKit) && (os(iOS) || os(tvOS) || os(visionOS))
                if let uiView = nativeView as? UIKit.UIView {
                    let targetFrame = CGRect(
                        x: 0,
                        y: 0,
                        width: CGFloat(size.width),
                        height: CGFloat(size.height)
                    )

                    if uiView.frame != targetFrame {
                        uiView.frame = targetFrame
                    }
                    if uiView.bounds != targetFrame {
                        uiView.bounds = targetFrame
                    }

                    uiView.contentScaleFactor = CGFloat(scale ?? max(environment.scaleFactor, 1))
                    uiView.setNeedsLayout()
                    uiView.layoutIfNeeded()
                    uiView.setNeedsDisplay()
                }
            #endif
        }

        private func effectiveOffscreenScale() -> Float {
            let baseScale = max(environment.scaleFactor, platformBackingScaleFactor(), 1)
            return min(baseScale * offscreenSupersamplingMultiplier, maxOffscreenScale)
        }

        private func platformBackingScaleFactor() -> Float {
            #if canImport(AppKit) && os(macOS)
                if let nsWindow = owner?.window?.systemWindow as? NSWindow {
                    return Float(nsWindow.backingScaleFactor)
                }
            #elseif canImport(UIKit) && (os(iOS) || os(tvOS) || os(visionOS))
                if let uiWindow = owner?.window?.systemWindow as? UIKit.UIWindow {
                    return Float(uiWindow.screen.scale)
                }
            #endif

            return 1
        }

        #if canImport(AppKit) && os(macOS)
            /// Converts a rectangle from AdaUI local space (origin top-left, +Y down) into `NSView.bounds`
            /// coordinates for use with `CALayer` masking. Non-flipped AppKit views use a bottom-left origin in bounds.
            private func appKitMaskRectInBoundsCoordinates(from adaLocalRect: Rect, nsView: NSView) -> CGRect {
                if nsView.isFlipped {
                    return adaLocalRect.toCGRect
                }
                let b = nsView.bounds
                let x = CGFloat(adaLocalRect.origin.x)
                let w = CGFloat(adaLocalRect.size.width)
                let h = CGFloat(adaLocalRect.size.height)
                let y = b.height - CGFloat(adaLocalRect.origin.y) - CGFloat(adaLocalRect.size.height)
                return CGRect(x: x, y: y, width: w, height: h)
            }

            private func appKitWindowPoint(from windowPosition: Point, in nsWindow: NSWindow) -> NSPoint {
                let windowHeight = Float(nsWindow.contentRect(forFrameRect: nsWindow.frame).height)
                return NSPoint(
                    x: CGFloat(windowPosition.x),
                    y: CGFloat(windowHeight - windowPosition.y)
                )
            }

            private func appKitLocalPoint(from windowPosition: Point, in nsView: NSView) -> NSPoint {
                let absoluteOrigin = visualAbsoluteFrame().origin
                let x = windowPosition.x - absoluteOrigin.x
                let y = windowPosition.y - absoluteOrigin.y
                let localY = nsView.isFlipped ? y : Float(nsView.bounds.height) - y
                return NSPoint(x: CGFloat(x), y: CGFloat(localY))
            }

            private func appKitModifierFlags(from modifiers: KeyModifier) -> NSEvent.ModifierFlags {
                var flags = NSEvent.ModifierFlags()

                if modifiers.contains(.alt) {
                    flags.insert(.option)
                }
                if modifiers.contains(.main) {
                    flags.insert(.command)
                }
                if modifiers.contains(.control) {
                    flags.insert(.control)
                }
                if modifiers.contains(.shift) {
                    flags.insert(.shift)
                }
                if modifiers.contains(.capsLock) {
                    flags.insert(.capsLock)
                }

                return flags
            }

            private func nearestAppKitControl(from view: NSView) -> NSControl? {
                var current: NSView? = view
                while let node = current {
                    if let control = node as? NSControl {
                        return control
                    }
                    // AppKit owns the superview chain while this synchronous fallback walks it.
                    current = unsafe node.superview
                }
                return nil
            }

            private func triggerAppKitControlClickFallback(_ control: NSControl) {
                if let button = control as? NSButton {
                    button.performClick(nil)
                    return
                }

                if let action = control.action {
                    NSApp.sendAction(action, to: control.target, from: control)
                }
            }
        #endif

        private func cleanupNativeView() {
            detachFromOverlay()

            if let nativeView, let coordinator {
                representable.dismantleNativeView(nativeView, coordinator: coordinator)
            }

            self.nativeView = nil
            self.coordinator = nil
            self.offscreenTexture = nil
        }

        private func resolvedRenderingMode() -> NativeRenderingMode {
            if requiresLiveOverlayRendering() {
                return .overlay
            }
            return environment.nativeRenderingMode
        }

        private func requiresLiveOverlayRendering() -> Bool {
            guard let nativeView else {
                return false
            }

            #if canImport(MapKit)
                if nativeView is MKMapView {
                    return true
                }
            #endif

            return false
        }
    }

#endif
