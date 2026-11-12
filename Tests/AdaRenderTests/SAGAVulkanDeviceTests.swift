#if SAGA_NATIVE
    import AdaUtils
    import Foundation
    import Math
    import Testing
    #if os(Windows)
        import WinSDK
    #endif

    @_spi(Internal) @testable import AdaRender

    /// Exercises the SAGA adapter on a real Vulkan device. Skipped without a Vulkan adapter.
    @Suite(.serialized)
    struct SAGAVulkanDeviceTests {
        private static var available: Bool { SAGAContext.isVulkanAvailable }

        @Test(.enabled(if: SAGAVulkanDeviceTests.available))
        func buffersRoundTripThroughTheGPU() async throws {
            let context = try SAGAContext.vulkan()
            let device = SAGARenderDevice(context: context)
            let values: [UInt32] = (0..<64).map { $0 &* 2654435761 }
            var copy = values
            let buffer = unsafe copy.withUnsafeMutableBytes { raw in
                unsafe device.createBuffer(label: "round trip", bytes: raw.baseAddress!, length: raw.count, options: .storageShared)
            }
            let data = try await buffer.readData()
            let readBack = data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
            #expect(readBack == values)
        }

        @Test(.enabled(if: SAGAVulkanDeviceTests.available))
        func bufferWritesAtAnOffsetLandWhereExpected() async throws {
            let context = try SAGAContext.vulkan()
            let device = SAGARenderDevice(context: context)
            let buffer = device.createBuffer(label: "offset", length: 64, options: .storageShared)
            var word: UInt32 = 0xDEADBEEF
            unsafe withUnsafeMutableBytes(of: &word) { unsafe buffer.setData($0.baseAddress!, byteCount: 4, offset: 16) }
            let data = try await buffer.readData()
            let words = data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
            #expect(words[4] == 0xDEADBEEF)
            #expect(words[0] == 0 && words[5] == 0)
        }

        private static let triangleShader = """
            @vertex fn vs(@builtin(vertex_index) index: u32) -> @builtin(position) vec4<f32> {
                var corners = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
                return vec4<f32>(corners[index], 0.0, 1.0);
            }
            @fragment fn fs() -> @location(0) vec4<f32> { return vec4<f32>(0.25, 0.5, 0.75, 1.0); }
            """

        @Test(.enabled(if: SAGAVulkanDeviceTests.available))
        func aRenderPassDrawsIntoATextureThatReadsBack() async throws {
            let context = try SAGAContext.vulkan(debugErrors: true)
            let device = SAGARenderDevice(context: context)
            let vertex = Shader(source: Self.triangleShader, entryPoint: "vs", stage: .vertex)
            let fragment = Shader(source: Self.triangleShader, entryPoint: "fs", stage: .fragment)
            vertex.compiledShader = try device.compileShader(from: vertex)
            fragment.compiledShader = try device.compileShader(from: fragment)
            let pipeline = device.createRenderPipeline(
                from: RenderPipelineDescriptor(
                    vertex: vertex,
                    fragment: fragment,
                    debugName: "fullscreen triangle",
                    backfaceCulling: false,
                    depthPixelFormat: .none,
                    colorAttachments: [.init(format: .rgba8)]
                )
            )
            let size = SizeInt(width: 16, height: 16)
            let target = device.createTexture(
                from: TextureDescriptor(
                    width: size.width, height: size.height, pixelFormat: .rgba8,
                    textureUsage: [.renderTarget, .read], textureType: .texture2D
                )
            )
            let texture = Texture2D(gpuTexture: target, sampler: device.createSampler(from: SamplerDescriptor()), size: size)

            let commands = device.createCommandQueue().makeCommandBuffer()
            let pass = commands.beginRenderPass(
                RenderPassDescriptor(
                    colorAttachments: [
                        RenderPassColorAttachmentDescriptor(
                            texture: texture,
                            operation: OperationDescriptor(loadAction: .clear, storeAction: .store),
                            clearColor: .black
                        )
                    ]
                )
            )
            pass.setRenderPipelineState(pipeline)
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            pass.endRenderPass()
            commands.commit()

            let image = try #require(try await device.readImage(from: texture))
            #expect(image.width == 16 && image.height == 16)
            let bytes = [UInt8](image.data)
            let center = (8 * 16 + 8) * 4
            #expect(abs(Int(bytes[center]) - 64) <= 2)
            #expect(abs(Int(bytes[center + 1]) - 128) <= 2)
            #expect(abs(Int(bytes[center + 2]) - 191) <= 2)
            #expect(bytes[center + 3] == 255)
        }

        private static let multipleTargetShader = """
            struct Out { @location(0) a: vec4<f32>, @location(1) b: vec4<f32>, @location(2) d: vec4<f32>, }
            @vertex fn vs(@builtin(vertex_index) index: u32) -> @builtin(position) vec4<f32> {
                var corners = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
                return vec4<f32>(corners[index], 0.0, 1.0);
            }
            @fragment fn fs() -> Out {
                var out: Out;
                out.a = vec4<f32>(1.0, 0.0, 0.0, 1.0);
                out.b = vec4<f32>(0.0, 1.0, 0.0, 1.0);
                out.d = vec4<f32>(0.0, 0.0, 1.0, 1.0);
                return out;
            }
            """

        @Test(.enabled(if: SAGAVulkanDeviceTests.available))
        func aPassWritesEveryColorTarget() async throws {
            let context = try SAGAContext.vulkan(debugErrors: true)
            let device = SAGARenderDevice(context: context)
            let vertex = Shader(source: Self.multipleTargetShader, entryPoint: "vs", stage: .vertex)
            let fragment = Shader(source: Self.multipleTargetShader, entryPoint: "fs", stage: .fragment)
            vertex.compiledShader = try device.compileShader(from: vertex)
            fragment.compiledShader = try device.compileShader(from: fragment)
            let pipeline = device.createRenderPipeline(
                from: RenderPipelineDescriptor(
                    vertex: vertex, fragment: fragment, debugName: "multiple targets", backfaceCulling: false,
                    depthPixelFormat: .none, colorAttachments: [.init(format: .rgba8), .init(format: .rgba8), .init(format: .rgba8)]
                )
            )
            let size = SizeInt(width: 8, height: 8)
            func makeTarget() -> Texture2D {
                let gpu = device.createTexture(
                    from: TextureDescriptor(
                        width: size.width, height: size.height, pixelFormat: .rgba8,
                        textureUsage: [.renderTarget, .read], textureType: .texture2D
                    )
                )
                return Texture2D(gpuTexture: gpu, sampler: device.createSampler(from: SamplerDescriptor()), size: size)
            }
            let targets = [makeTarget(), makeTarget(), makeTarget()]
            let commands = device.createCommandQueue().makeCommandBuffer()
            let pass = commands.beginRenderPass(
                RenderPassDescriptor(
                    colorAttachments: targets.map {
                        RenderPassColorAttachmentDescriptor(
                            texture: $0, operation: OperationDescriptor(loadAction: .clear, storeAction: .store), clearColor: .black
                        )
                    }
                )
            )
            pass.setRenderPipelineState(pipeline)
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            pass.endRenderPass()
            commands.commit()

            await context.queue.drain()
            #expect(context.errorLog.all.isEmpty, "SAGA device errors: \(context.errorLog.all)")
            let expected: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255]]
            for (target, color) in zip(targets, expected) {
                let image = try #require(try await device.readImage(from: target))
                let bytes = [UInt8](image.data)
                let center = (4 * 8 + 4) * 4
                #expect(Array(bytes[center..<center + 4]) == color)
            }
        }

        #if os(Windows)
            @Test(.enabled(if: SAGAVulkanDeviceTests.available), .timeLimit(.minutes(1)))
            @MainActor
            func offscreenResourcesWorkBeforePresentingToAWin32Window() async throws {
                let backend = try SAGANativeRenderBackend(windowless: false)
                let device = backend.renderDevice
                let buffer = device.createBuffer(label: "before the first window", length: 4, options: .storageShared)
                #expect(try await buffer.readData() == Data(repeating: 0, count: 4))

                let className = Array("STATIC".utf16) + [0]
                let title = Array("SAGA presentation test".utf16) + [0]
                let hwnd = try #require(
                    unsafe className.withUnsafeBufferPointer { classPointer in
                        unsafe title.withUnsafeBufferPointer { titlePointer in
                            unsafe CreateWindowExW(
                                0, classPointer.baseAddress, titlePointer.baseAddress, DWORD(WS_OVERLAPPEDWINDOW),
                                0, 0, 96, 96, nil, nil, GetModuleHandleW(nil), nil
                            )
                        }
                    }
                )
                defer { DestroyWindow(hwnd) }

                let windowID = WindowID()
                let size = SizeInt(width: 64, height: 64)
                try backend.createWindow(
                    windowID,
                    for: WindowsSurface(windowId: windowID, windowHwnd: UnsafeMutableRawPointer(hwnd)),
                    size: size
                )
                let vertex = Shader(source: Self.triangleShader, entryPoint: "vs", stage: .vertex)
                let fragment = Shader(source: Self.triangleShader, entryPoint: "fs", stage: .fragment)
                vertex.compiledShader = try device.compileShader(from: vertex)
                fragment.compiledShader = try device.compileShader(from: fragment)
                let pipeline = device.createRenderPipeline(
                    from: RenderPipelineDescriptor(
                        vertex: vertex, fragment: fragment, debugName: "present test", backfaceCulling: false,
                        depthPixelFormat: .none, colorAttachments: [.init(format: .bgra8)]
                    )
                )

                let swapchain = try #require(device.createSwapchain(from: windowID))
                let drawable = try #require(swapchain.getNextDrawable(device))
                let texture = Texture2D(gpuTexture: drawable.texture, sampler: device.createSampler(from: SamplerDescriptor()), size: size)
                let commands = device.createCommandQueue().makeCommandBuffer()
                let pass = commands.beginRenderPass(
                    RenderPassDescriptor(
                        colorAttachments: [
                            RenderPassColorAttachmentDescriptor(
                                texture: texture,
                                operation: OperationDescriptor(loadAction: .clear, storeAction: .store),
                                clearColor: .black
                            )
                        ]
                    )
                )
                pass.setRenderPipelineState(pipeline)
                pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
                pass.endRenderPass()
                commands.commit()
                try drawable.present()

                await backend.context.queue.drain()
                #expect(backend.context.errorLog.all.isEmpty, "SAGA device errors: \(backend.context.errorLog.all)")
                try backend.destroyWindow(windowID)
                await backend.context.queue.drain()
            }

        @Test(.enabled(if: SAGAVulkanDeviceTests.available))
        @MainActor
        func twoWindowsPresentAndTheFirstSurfaceCanBeRecreated() async throws {
            func makeWindow(_ title: String) throws -> HWND {
                let className = Array("STATIC".utf16) + [0]
                let titleText = Array(title.utf16) + [0]
                return try #require(
                    unsafe className.withUnsafeBufferPointer { classPointer in
                        unsafe titleText.withUnsafeBufferPointer { titlePointer in
                            unsafe CreateWindowExW(
                                0, classPointer.baseAddress, titlePointer.baseAddress, DWORD(WS_OVERLAPPEDWINDOW),
                                0, 0, 96, 96, nil, nil, GetModuleHandleW(nil), nil
                            )
                        }
                    }
                )
            }
            let first = try makeWindow("SAGA window one")
            let second = try makeWindow("SAGA window two")
            defer {
                DestroyWindow(first)
                DestroyWindow(second)
            }

            let backend = try SAGANativeRenderBackend(windowless: false)
            let size = SizeInt(width: 64, height: 64)
            let ids = [WindowID(), WindowID()]
            for (id, hwnd) in zip(ids, [first, second]) {
                try backend.createWindow(id, for: WindowsSurface(windowId: id, windowHwnd: UnsafeMutableRawPointer(hwnd)), size: size)
            }

            let device = backend.renderDevice
            let vertex = Shader(source: Self.triangleShader, entryPoint: "vs", stage: .vertex)
            let fragment = Shader(source: Self.triangleShader, entryPoint: "fs", stage: .fragment)
            vertex.compiledShader = try device.compileShader(from: vertex)
            fragment.compiledShader = try device.compileShader(from: fragment)
            let pipeline = device.createRenderPipeline(
                from: RenderPipelineDescriptor(
                    vertex: vertex, fragment: fragment, debugName: "two windows", backfaceCulling: false,
                    depthPixelFormat: .none, colorAttachments: [.init(format: .bgra8)]
                )
            )
            for (index, id) in (ids + ids.prefix(1)).enumerated() {
                if index == ids.count {
                    try backend.destroyWindow(id)
                    try backend.createWindow(id, for: WindowsSurface(windowId: id, windowHwnd: UnsafeMutableRawPointer(first)), size: size)
                }
                let swapchain = try #require(device.createSwapchain(from: id))
                let drawable = try #require(swapchain.getNextDrawable(device))
                let texture = Texture2D(gpuTexture: drawable.texture, sampler: device.createSampler(from: SamplerDescriptor()), size: size)
                let commands = device.createCommandQueue().makeCommandBuffer()
                let pass = commands.beginRenderPass(
                    RenderPassDescriptor(
                        colorAttachments: [
                            RenderPassColorAttachmentDescriptor(
                                texture: texture,
                                operation: OperationDescriptor(loadAction: .clear, storeAction: .store),
                                clearColor: .black
                            )
                        ]
                    )
                )
                pass.setRenderPipelineState(pipeline)
                pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
                pass.endRenderPass()
                commands.commit()
                try drawable.present()
            }
            await backend.context.queue.drain()
            #expect(backend.context.errorLog.all.isEmpty, "SAGA device errors: \(backend.context.errorLog.all)")
            for id in ids { try backend.destroyWindow(id) }
            await backend.context.queue.drain()
        }
        #endif
    }
#endif
