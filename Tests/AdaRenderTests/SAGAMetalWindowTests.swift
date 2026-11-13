#if os(macOS) && SAGA_METAL
    @testable import AdaRender
    import AdaUtils
    import AppKit
    import Foundation
    import Math
    import MetalKit
    import Testing

    private let sagaMetalWindowSmokeEnabled = ProcessInfo.processInfo.environment["ADAENGINE_SAGA_METAL_WINDOW_SMOKE"] == "1"

    @MainActor
    struct SAGAMetalWindowTests {
        @Test(.enabled(if: sagaMetalWindowSmokeEnabled))
        func presentsAndResizesAnEngineDrawable() async throws {
            _ = NSApplication.shared
            let view = MTKView(frame: NSRect(x: 0, y: 0, width: 64, height: 64), device: nil)
            view.isPaused = true
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFrontRegardless()
            defer { window.close() }

            try RenderEngine.setupRenderEngine()
            try #require(unsafe RenderEngine.shared.type == .saga, "The default renderer must be SAGA Metal.")
            let backend = try SAGAMetalRenderBackend()
            let id = WindowID()
            var feedback = 0
            var displayed: [SizeInt] = []
            let first = SizeInt(width: 64, height: 64)
            try backend.createWindow(id, for: view, size: first) { frame in
                feedback += 1
                if frame.presentedTime > 0 {
                    displayed.append(SizeInt(width: Int(frame.width), height: Int(frame.height)))
                }
            }
            let device = backend.renderDevice
            let swapchain = try #require(device.createSwapchain(from: id))
            let sampler = device.createSampler(from: SamplerDescriptor())

            func submitFrame(_ size: SizeInt) async throws {
                let previousFeedback = feedback
                let drawable = try #require(swapchain.getNextDrawable(device))
                let texture = Texture2D(gpuTexture: drawable.texture, sampler: sampler, size: size)
                let commands = device.createCommandQueue().makeCommandBuffer()
                let pass = commands.beginRenderPass(RenderPassDescriptor(colorAttachments: [
                    .init(
                        texture: texture,
                        operation: .init(loadAction: .clear, storeAction: .store),
                        clearColor: Color(red: 0.25, green: 0.5, blue: 0.75)
                    )
                ]))
                pass.endRenderPass()
                commands.commit()
                try drawable.present()
                let image = try #require(try await device.readImage(from: texture))
                let pixel = image.getPixel(x: image.width / 2, y: image.height / 2)
                #expect(abs(pixel.red - 0.25) < 0.02)
                #expect(abs(pixel.green - 0.5) < 0.02)
                #expect(abs(pixel.blue - 0.75) < 0.02)
                for _ in 0..<50 where feedback == previousFeedback {
                    try await Task.sleep(for: .milliseconds(20))
                }
            }

            func present(_ size: SizeInt) async throws {
                // WindowServer can discard the first frame while a new window or drawable size is being shown.
                for _ in 0..<4 where displayed.last != size {
                    try await submitFrame(size)
                }
                #expect(displayed.last == size, "No frame of size \(size) reached a display.")
            }

            try backend.resizeWindow(id, newSize: first, scaleFactor: 1)
            try await present(first)
            let second = SizeInt(width: 96, height: 72)
            window.setContentSize(NSSize(width: second.width, height: second.height))
            try backend.resizeWindow(id, newSize: second, scaleFactor: 1)
            try await present(second)
            try backend.destroyWindow(id)
            await backend.context.queue.drain()
            #expect(swapchain.getNextDrawable(device) == nil)
            #expect(backend.context.errorLog.all.isEmpty, "\(backend.context.errorLog.all)")
        }
    }
#endif
