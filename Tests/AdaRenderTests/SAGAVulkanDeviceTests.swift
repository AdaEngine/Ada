#if SAGA_NATIVE
    import AdaUtils
    import Dispatch
    import Foundation
    import Math
    import Synchronization
    import Testing
    #if os(Windows)
        import WinSDK
    #endif

    @_spi(Internal) @testable import AdaRender

    /// Exercises the SAGA adapter on a real Vulkan device. Skipped without a Vulkan adapter.
    @Suite(.serialized)
    struct SAGAVulkanDeviceTests {
        @Test(.enabled(if: SAGAContext.isVulkanAvailable))
        func buffersRoundTripThroughTheGPU() async throws {
            let context = try SAGAContext.vulkan()
            let device = SAGARenderDevice(context: context)
            let values: [UInt32] = (0..<64).map { $0 &* 2654435761 }
            var copy = values
            let buffer = unsafe try copy.withUnsafeMutableBytes { raw in
                let address = try #require(raw.baseAddress)
                return unsafe device.createBuffer(label: "round trip", bytes: address, length: raw.count, options: .storageShared)
            }
            let data = try await buffer.readData()
            let readBack = data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
            #expect(readBack == values)
        }

        @Test(.enabled(if: SAGAContext.isVulkanAvailable))
        func bufferWritesAtAnOffsetLandWhereExpected() async throws {
            let context = try SAGAContext.vulkan()
            let device = SAGARenderDevice(context: context)
            let buffer = device.createBuffer(label: "offset", length: 64, options: .storageShared)
            var word: UInt32 = 0xDEADBEEF
            unsafe try withUnsafeMutableBytes(of: &word) { bytes in
                let address = try #require(bytes.baseAddress)
                unsafe buffer.setData(address, byteCount: bytes.count, offset: 16)
            }
            let data = try await buffer.readData()
            let words = data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
            #expect(words[4] == 0xDEADBEEF)
            #expect(words[0] == 0 && words[5] == 0)
        }

        @Test(.enabled(if: SAGAContext.isVulkanAvailable))
        func adjacentBufferUploadsUseOneSubmissionOnEitherSideOfACopy() async throws {
            try await compareAdjacentUploadsAcrossCopy(context: SAGAContext.vulkan())
        }

        #if os(Windows)
        @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_ENABLE_D3D12"] == "1"))
        func direct3D12UploadsPreserveCopyBoundariesAndOverlappingWrites() async throws {
            let backend = try SAGANativeRenderBackend(windowless: true, windowsRenderer: .direct3D12)
            try await compareAdjacentUploadsAcrossCopy(context: backend.context, allocateDuringBatch: true)
        }
        #endif

        private func compareAdjacentUploadsAcrossCopy(context: SAGAContext, allocateDuringBatch: Bool = false) async throws {
            let device = SAGARenderDevice(context: context)
            let source = try #require(device.createBuffer(label: "source", length: 8, options: .storageShared) as? SAGABuffer)
            let snapshot = try #require(device.createBuffer(label: "snapshot", length: 8, options: .storageShared) as? SAGABuffer)
            let sequences = Mutex<[UInt64]>([])
            let gate = AsyncStream<Void>.makeStream()
            context.queue.enqueue { gpu in
                let ticket = try await gpu.submitResourceUse([])
                sequences.withLock { $0.append(ticket.sequence) }
                var iterator = gate.stream.makeAsyncIterator()
                _ = await iterator.next()
            }

            func write(_ values: [UInt32], at offset: Int) {
                var words = values
                unsafe words.withUnsafeMutableBytes { bytes in
                    if let address = unsafe bytes.baseAddress {
                        unsafe source.setData(address, byteCount: bytes.count, offset: offset)
                    }
                }
            }

            write([1, 2], at: 0)
            let freshBuffer = allocateDuringBatch ? device.createBuffer(label: "independent allocation", length: 8, options: .storageShared) : nil
            write([3], at: 4)
            let sourceSlot = source.slot
            let snapshotSlot = snapshot.slot
            context.queue.enqueue { gpu in
                _ = try await gpu.submitCommands([.copy(source: sourceSlot.get(), destination: snapshotSlot.get())])
            }
            write([4, 5], at: 0)
            write([6], at: 4)
            context.queue.enqueue { gpu in
                let ticket = try await gpu.submitResourceUse([])
                sequences.withLock { $0.append(ticket.sequence) }
            }
            gate.continuation.finish()

            let copied = try await snapshot.readData().withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
            let final = try await source.readData().withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
            #expect(copied == [1, 3])
            #expect(final == [4, 6])
            let markers = sequences.withLock { $0 }
            try #require(markers.count == 2)
            #expect(markers[1] - markers[0] == 4)
            #expect(context.errorLog.all.isEmpty)
            withExtendedLifetime(freshBuffer) {}
        }

        private static let triangleShader = """
            @vertex fn vs(@builtin(vertex_index) index: u32) -> @builtin(position) vec4<f32> {
                var corners = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
                return vec4<f32>(corners[index], 0.0, 1.0);
            }
            @fragment fn fs() -> @location(0) vec4<f32> { return vec4<f32>(0.25, 0.5, 0.75, 1.0); }
            """

        @Test(.enabled(if: SAGAContext.isVulkanAvailable))
        func recordingWritableGeometryInvalidatesItsShadowRevision() async throws {
            let device = SAGARenderDevice(context: try SAGAContext.vulkan())
            let fragmentSource = """
                @group(0) @binding(0) var<storage, read> source: array<u32>;
                @group(0) @binding(1) var<storage, read_write> destination: array<u32>;
                @fragment fn fs() -> @location(0) vec4f {
                    destination[0] = source[0];
                    return vec4f(1.0);
                }
                """
            let vertex = Shader(source: Self.triangleShader, entryPoint: "vs", stage: .vertex)
            let fragment = Shader(source: fragmentSource, entryPoint: "fs", stage: .fragment)
            vertex.compiledShader = try device.compileShader(from: vertex)
            fragment.compiledShader = try device.compileShader(from: fragment)
            let pipeline = device.createRenderPipeline(from: RenderPipelineDescriptor(
                vertex: vertex, fragment: fragment, colorAttachments: [.init(format: .rgba8)]
            ))
            let source = try #require(device.createVertexBuffer(label: nil, length: 16, binding: 0) as? SAGABuffer)
            let destination = try #require(device.createVertexBuffer(label: nil, length: 16, binding: 1) as? SAGABuffer)
            var input = BufferData<UInt32>(elements: [])
            var output = BufferData<UInt32>(elements: [])
            input.buffer = source
            output.buffer = destination
            let command = device.createCommandQueue().makeCommandBuffer()
            let pass = command.beginRenderPass(RenderPassDescriptor(colorAttachments: []))
            pass.setRenderPipelineState(pipeline)
            pass.setFragmentBuffer(input, offset: 0, slot: 0)
            pass.setFragmentBuffer(output, offset: 0, slot: 1)
            #expect(destination.shadowRasterRevision != nil)
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            #expect(source.shadowRasterRevision != nil)
            #expect(destination.hasUntrackedShadowWrites)
            pass.endRenderPass()
        }

        @Test(.enabled(if: SAGAContext.isVulkanAvailable), arguments: [false, true])
        func aRenderPassDrawsIntoATextureThatReadsBack(rebindColor: Bool) async throws {
            let context = try SAGAContext.vulkan(debugErrors: true)
            let device = SAGARenderDevice(context: context)
            let vertex = Shader(source: Self.triangleShader, entryPoint: "vs", stage: .vertex)
            let uniformShader = """
                @group(0) @binding(0) var<uniform> color: vec4<f32>;
                @fragment fn fs() -> @location(0) vec4<f32> { return color; }
                """
            let fragment = Shader(source: rebindColor ? uniformShader : Self.triangleShader, entryPoint: "fs", stage: .fragment)
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
                    width: size.width,
                    height: size.height,
                    pixelFormat: .rgba8,
                    textureUsage: [.renderTarget, .read],
                    textureType: .texture2D
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
            func bindColor(_ color: SIMD4<Float>) {
                let uniform = device.createUniformBuffer(length: MemoryLayout<SIMD4<Float>>.stride, binding: 0)
                var value = color
                withUnsafeMutableBytes(of: &value) { bytes in
                    if let base = bytes.baseAddress { uniform.setData(base, byteCount: bytes.count, offset: 0) }
                }
                pass.setFragmentBuffer(uniform, offset: 0, slot: 0)
            }
            if rebindColor { bindColor(SIMD4(1, 0, 0, 1)) }
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            if rebindColor {
                // Rebinding before commit must preserve the first draw's original uniform and its lifetime.
                bindColor(SIMD4(0.25, 0.5, 0.75, 1))
                pass.setScissorRect(Rect(x: 8, y: 0, width: 8, height: 16))
                pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            }
            pass.endRenderPass()
            commands.commit()

            let image = try #require(try await device.readImage(from: texture))
            #expect(image.width == 16 && image.height == 16)
            let bytes = [UInt8](image.data)
            let center = (8 * 16 + 8) * 4
            if rebindColor { #expect(Array(bytes[0..<4]) == [255, 0, 0, 255]) }
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

        @Test(.enabled(if: SAGAContext.isVulkanAvailable))
        func aPassWritesEveryColorTarget() async throws {
            let context = try SAGAContext.vulkan(debugErrors: true)
            let device = SAGARenderDevice(context: context)
            let vertex = Shader(source: Self.multipleTargetShader, entryPoint: "vs", stage: .vertex)
            let fragment = Shader(source: Self.multipleTargetShader, entryPoint: "fs", stage: .fragment)
            vertex.compiledShader = try device.compileShader(from: vertex)
            fragment.compiledShader = try device.compileShader(from: fragment)
            let pipeline = device.createRenderPipeline(
                from: RenderPipelineDescriptor(
                    vertex: vertex,
                    fragment: fragment,
                    debugName: "multiple targets",
                    backfaceCulling: false,
                    depthPixelFormat: .none,
                    colorAttachments: [.init(format: .rgba8), .init(format: .rgba8), .init(format: .rgba8)]
                )
            )
            let size = SizeInt(width: 8, height: 8)
            func makeTarget() -> Texture2D {
                let gpu = device.createTexture(
                    from: TextureDescriptor(
                        width: size.width,
                        height: size.height,
                        pixelFormat: .rgba8,
                        textureUsage: [.renderTarget, .read],
                        textureType: .texture2D
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
            @Test(.enabled(if: SAGAContext.isVulkanAvailable), .timeLimit(.minutes(1)))
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
                                0,
                                classPointer.baseAddress,
                                titlePointer.baseAddress,
                                DWORD(WS_OVERLAPPEDWINDOW),
                                0,
                                0,
                                96,
                                96,
                                nil,
                                nil,
                                GetModuleHandleW(nil),
                                nil
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
                        vertex: vertex,
                        fragment: fragment,
                        debugName: "present test",
                        backfaceCulling: false,
                        depthPixelFormat: .none,
                        colorAttachments: [.init(format: .bgra8)]
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
                try backend.destroyWindow(windowID)
                await backend.context.queue.drain()
                #expect(backend.context.errorLog.all.isEmpty, "SAGA device errors: \(backend.context.errorLog.all)")
            }

        @Test(.enabled(if: SAGAContext.isVulkanAvailable))
        @MainActor
        func nativeWindowClosesAfterPendingPresentationRetires() async throws {
            let created = DispatchSemaphore(value: 0)
            let closed = DispatchSemaphore(value: 0)
            let nativeWindow = Mutex((handle: UInt(0), thread: DWORD(0), closeRequested: false, destroyed: false))
            let requestClose: @Sendable () -> Void = {
                let thread = nativeWindow.withLock { window in
                    window.closeRequested = true
                    return window.thread
                }
                if thread != 0 { _ = PostThreadMessageW(thread, UINT(WM_QUIT), 0, 0) }
            }
            Thread.detachNewThread {
                let windowClass = Array("STATIC".utf16) + [0]
                let hwnd = unsafe windowClass.withUnsafeBufferPointer { name in
                    unsafe CreateWindowExW(
                        0,
                        name.baseAddress,
                        nil,
                        DWORD(WS_OVERLAPPEDWINDOW),
                        0,
                        0,
                        96,
                        96,
                        nil,
                        nil,
                        GetModuleHandleW(nil),
                        nil
                    )
                }
                var message = unsafe MSG()
                unsafe _ = PeekMessageW(&message, nil, 0, 0, 0)
                let closeRequested = nativeWindow.withLock { window in
                    window.handle = UInt(bitPattern: hwnd)
                    window.thread = GetCurrentThreadId()
                    return window.closeRequested
                }
                created.signal()
                // Pump native driver messages until retirement requests a close on the creating thread.
                if !closeRequested {
                    while unsafe GetMessageW(&message, nil, 0, 0) {
                        unsafe TranslateMessage(&message)
                        unsafe DispatchMessageW(&message)
                    }
                }
                let destroyed = unsafe hwnd != nil && DestroyWindow(hwnd)
                nativeWindow.withLock {
                    $0.thread = 0
                    $0.destroyed = destroyed
                }
                closed.signal()
            }
            defer { requestClose() }
            try #require(created.wait(timeout: .now() + 5) == .success)
            let handle = nativeWindow.withLock { $0.handle }
            let hwnd = try #require(unsafe HWND(bitPattern: handle))

            let backend = try SAGANativeRenderBackend(windowless: false)
            let renderer = RenderEngine(renderBackend: backend)
            let windowID = WindowID()
            try renderer.createWindow(
                windowID,
                for: WindowsSurface(windowId: windowID, windowHwnd: UnsafeMutableRawPointer(hwnd)),
                size: SizeInt(width: 64, height: 64)
            )
            let device = renderer.renderDevice
            let swapchain = try #require(device.createSwapchain(from: windowID))
            let drawable = try #require(swapchain.getNextDrawable(device))
            let (release, gate) = AsyncStream<Void>.makeStream()
            let (blocked, reachedGate) = AsyncStream<Void>.makeStream()
            defer { gate.finish() }
            backend.context.queue.enqueueCleanup {
                reachedGate.finish()
                var waiting = release.makeAsyncIterator()
                _ = await waiting.next()
            }
            try drawable.present()
            try renderer.destroyWindow(windowID)
            let (destruction, completion) = AsyncStream<Bool>.makeStream()
            renderer.afterPendingWindowRetirement {
                requestClose()
                let completed = closed.wait(timeout: .now() + 5) == .success
                completion.yield(completed && nativeWindow.withLock { $0.destroyed })
                completion.finish()
            }
            var gateStarted = blocked.makeAsyncIterator()
            _ = await gateStarted.next()
            try await Task.sleep(for: .milliseconds(40))
            #expect(!nativeWindow.withLock { $0.closeRequested })
            #expect(unsafe IsWindow(hwnd))
            gate.finish()
            var didDestroy = destruction.makeAsyncIterator()
            #expect(await didDestroy.next() == true)
            #expect(backend.context.errorLog.all.isEmpty, "SAGA device errors: \(backend.context.errorLog.all)")
        }

        @Test(.enabled(if: SAGAContext.isVulkanAvailable))
        @MainActor
        func twoWindowsPresentAndTheFirstSurfaceCanBeRecreated() async throws {
            func makeWindow(_ title: String) throws -> HWND {
                let className = Array("STATIC".utf16) + [0]
                let titleText = Array(title.utf16) + [0]
                return try #require(
                    unsafe className.withUnsafeBufferPointer { classPointer in
                        unsafe titleText.withUnsafeBufferPointer { titlePointer in
                            unsafe CreateWindowExW(
                                0,
                                classPointer.baseAddress,
                                titlePointer.baseAddress,
                                DWORD(WS_OVERLAPPEDWINDOW),
                                0,
                                0,
                                96,
                                96,
                                nil,
                                nil,
                                GetModuleHandleW(nil),
                                nil
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
                    vertex: vertex,
                    fragment: fragment,
                    debugName: "two windows",
                    backfaceCulling: false,
                    depthPixelFormat: .none,
                    colorAttachments: [.init(format: .bgra8)]
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
            for id in ids { try backend.destroyWindow(id) }
            await backend.context.queue.drain()
            #expect(backend.context.errorLog.all.isEmpty, "SAGA device errors: \(backend.context.errorLog.all)")
        }
        #endif
    }
#endif
