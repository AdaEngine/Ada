#if WEBGPU_ENABLED && canImport(WebGPU)
    import AdaUtils
    import Foundation
    import Logging
    import Synchronization
    @unsafe @preconcurrency import WebGPU

    final class WGPUSwapchain: Swapchain, @unchecked Sendable {
        let renderWindow: WGPUContext.WGPURenderWindow
        var previousDrawable: (any Drawable)?
        var currentDrawable: (any Drawable)?

        init(renderWindow: WGPUContext.WGPURenderWindow) {
            self.renderWindow = renderWindow
        }

        var drawablePixelFormat: PixelFormat {
            renderWindow.pixelFormat
        }

        func getNextDrawable(_: RenderDevice) -> (any Drawable)? {
            renderWindow.surfaceLock.withLock { _ in
                guard renderWindow.isActive else {
                    return nil
                }
                if renderWindow.pendingDrawableSkips > 0 {
                    renderWindow.pendingDrawableSkips -= 1
                    return nil
                }

                #if WASM
                    let texture = webGPUDeviceLock.withLock { _ in
                        renderWindow.surface.getCurrentTexture()
                    }
                    return WGPUSwapchainDrawable(texture: texture)
                #else
                    var surfaceTexture = WGPUSurfaceTexture()
                    webGPUDeviceLock.withLock { _ in
                        renderWindow.surface.getCurrentTexture(surfaceTexture: &surfaceTexture)
                    }
                    let textureStatus = surfaceTexture.status
                    guard textureStatus == .successOptimal || textureStatus == .successSuboptimal else {
                        return nil
                    }
                    return WGPUSwapchainDrawable(
                        renderWindow: renderWindow,
                        surfaceTexture: WebGPU.GPUSurfaceTexture(wgpuStruct: surfaceTexture)
                    )
                #endif
            }
        }
    }

    final class WGPUSwapchainDrawable: Drawable, @unchecked Sendable {
        let texture: any GPUTexture
        #if WASM
            var isPresented: Bool = false

            init(texture: WebGPU.GPUTexture) {
                self.texture = WGPUGPUTexture(
                    texture: texture,
                    textureView: texture.createView()
                )
            }
        #else
            let renderWindow: WGPUContext.WGPURenderWindow
            let surfaceTexture: WebGPU.GPUSurfaceTexture
            var isPresented: Bool = false

            init(renderWindow: WGPUContext.WGPURenderWindow, surfaceTexture: WebGPU.GPUSurfaceTexture) {
                self.renderWindow = renderWindow
                self.surfaceTexture = surfaceTexture
                self.texture = WGPUGPUTexture(
                    texture: surfaceTexture.texture,
                    textureView: surfaceTexture.texture.createView()
                )
            }
        #endif

        func present() throws {
            assert(!isPresented, "Drawable is already presented")
            #if WASM
                self.isPresented = true
            #else
                let value = renderWindow.surfaceLock.withLock { _ in
                    guard renderWindow.isActive else {
                        return WebGPU.GPUStatus.success
                    }
                    return webGPUDeviceLock.withLock { _ in renderWindow.surface.present() }
                }
                self.isPresented = true
                if value != .success {
                    throw DrawableError.failedToPresentDrawable
                }
            #endif
        }
    }

    enum DrawableError: Error {
        case failedToPresentDrawable
    }

    extension WebGPU.GPUTextureDimension {
        var toTextureViewDimension: WebGPU.GPUTextureViewDimension {
            switch self {
            case ._1D: return ._1D
            case ._2D: return ._2D
            case ._3D: return ._3D
            default: return ._2D
            }
        }
    }
#endif
