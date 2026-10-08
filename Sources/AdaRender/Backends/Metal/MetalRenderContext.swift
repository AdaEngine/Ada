//
//  MetalRenderContext.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/16/22.
//

#if METAL
    import Math
    import Metal
    import MetalKit
    import QuartzCore

    extension MetalRenderBackend {
        final class Context: @unchecked Sendable {
            private(set) var windows: [WindowID: MetalRenderWindow] = [:]
            let physicalDevice: MTLDevice

            init() {
                self.physicalDevice = Self.prefferedDevice()
                let needsShowDebugHUD = ProcessInfo.processInfo.environment["METAL_HUD_DEBUG"] != nil
                UserDefaults.standard.set(needsShowDebugHUD, forKey: "MetalForceHudEnabled")
            }

            func getRenderWindow(for window: WindowID) -> MetalRenderWindow? {
                windows[window]
            }

            // MARK: - Methods
            @MainActor
            func createRenderWindow(with id: WindowID, view: MTKView, size: SizeInt) throws {
                if windows[id] != nil {
                    throw ContextError.creationWindowAlreadyExists
                }

                let window = MetalRenderWindow(
                    view: view,
                    size: size,
                    scaleFactor: view.scaleFactor
                )
                let isOpaque = view.isOpaque
                view.colorPixelFormat = .bgra8Unorm
                view.device = self.physicalDevice
                view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: isOpaque ? 1 : 0)
                view.framebufferOnly = false
                view.sampleCount = 1

                let layer = view.layer as? CAMetalLayer
                layer?.frame = view.bounds
                layer?.pixelFormat = view.colorPixelFormat
                layer?.contentsScale = CGFloat(view.scaleFactor)
                layer?.isOpaque = isOpaque
                layer?.maximumDrawableCount = unsafe RenderEngine.configurations.maxFramesInFlight
                layer?.allowsNextDrawableTimeout = true

                self.windows[id] = window
            }

            @MainActor
            func updateSizeForRenderWindow(_ windowId: WindowID, size: SizeInt) {
                // Must copy the struct out, mutate, and write back. Optional-chained field
                // assignment on `Dictionary` value types does not reliably persist the change,
                // so logical size could stay stuck at the initial window size → stale camera
                // viewport / main render target while the NSWindow grows (black or frozen UI).
                guard var window = windows[windowId] else {
                    return
                }
                window.size = size
                window.scaleFactor = window.view.scaleFactor
                windows[windowId] = window
            }

            func destroyWindow(by id: WindowID) {
                guard self.windows[id] != nil else {
                    assertionFailure("Not found window by id \(id)")
                    return
                }
                self.windows[id] = nil
            }

            // MARK: - Private

            private static func prefferedDevice() -> MTLDevice {
                #if !os(macOS)
                    // For ios/tvOS/ipadOS we have only one device
                    guard let device = MTLCreateSystemDefaultDevice() else {
                        preconditionFailure("Metal is unavailable on this device.")
                    }
                    return device
                #endif
                // TODO: (Vlad) Make picking preffered device, currently we picked descrete GPU
                guard let device = MTLCreateSystemDefaultDevice() else {
                    preconditionFailure("Metal is unavailable on this device.")
                }
                return device
            }

            enum ContextError: LocalizedError {
                case creationWindowAlreadyExists
                case commandQueueCreationFailed

                var errorDescription: String? {
                    switch self {
                    case .creationWindowAlreadyExists:
                        return "MetalRenderWindow Creation Failed: Window by given id already exists."
                    case .commandQueueCreationFailed:
                        return "MetalRenderWindow Creation Failed: MTLDevice cannot create MTLCommandQueue."
                    }
                }
            }
        }

        struct MetalRenderWindow: Sendable {
            let view: MTKView
            var size: SizeInt
            var scaleFactor: Float
        }
    }

#endif
