#if SAGA_METAL || SAGA_METAL_NATIVE_PASS
    @testable import AdaRender
    import AdaUtils
    import Math
    import MetalKit
    import SAGABackend
    import SAGACore
    import SAGAShaderIR
    import SAGATypes
    import Synchronization
    import Testing

    #if SAGA_METAL_NATIVE_PASS && os(macOS)
        import SAGAMetal
    #endif

    struct SAGACommandCompletionTests {
        @Test
        func completionRunsWhenTheDeviceCannotBeCreated() async throws {
            let context = try Self.unavailableContext()
            let commands = SAGACommandBuffer(context: context)
            let completions = Mutex(0)
            let outcomes = Mutex<[Bool]>([])
            commands.observeSubmissionResult { success in outcomes.withLock { $0.append(success) } }
            commands.addCompletedHandler { completions.withLock { $0 += 1 } }
            commands.addCompletedTimingHandler { _ in completions.withLock { $0 += 1 } }
            commands.commit()
            await context.queue.drain()

            #expect(completions.withLock { $0 } == 2, "A failed device must still notify both handlers")
            #expect(outcomes.withLock { $0 } == [false])
            #expect(context.errorLog.all.count == 1)
        }

        @Test
        func retirementRemovesAnAttachedSurfaceWhenTheDeviceCannotBeCreated() async throws {
            let context = try Self.unavailableContext()
            let window = SAGAWindow(
                context: context,
                windowId: WindowID(),
                size: SizeInt(width: 16, height: 16),
                scaleFactor: 1,
                pixelFormat: .bgra8,
                surfaceID: 11
            )
            context.queue.enqueue { _ in }
            let removed = Mutex<[UInt32]>([])
            window.retire { id in removed.withLock { $0.append(id) } }
            await context.queue.drain()

            #expect(removed.withLock { $0 } == [11], "An attached surface must retire even if device setup failed")
            #expect(context.errorLog.all.count == 1)
        }

        #if os(macOS)
            @MainActor
            @Test
            func metalWindowDoesNotQueueAnotherFrameWhilePresentationIsPending() async throws {
                let backend = try SAGAMetalRenderBackend()
                let windowID = WindowID()
                let size = SizeInt(width: 16, height: 16)
                let view = MTKView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))
                try backend.createWindow(windowID, for: view, size: size)
                let swapchain = try #require(backend.renderDevice.createSwapchain(from: windowID))

                let release = BackendCompletion()
                backend.context.queue.enqueueCleanup {
                    try await release.wait(timeout: .seconds(5))
                }
                let drawable = try #require(swapchain.getNextDrawable(backend.renderDevice))
                try drawable.present()

                #expect(
                    swapchain.getNextDrawable(backend.renderDevice) == nil,
                    "Metal must apply backpressure while a window presentation is pending"
                )

                await release.finish(.success(()))
                await backend.context.queue.drain()
                #expect(swapchain.getNextDrawable(backend.renderDevice) != nil)
                try backend.destroyWindow(windowID)
                await backend.context.queue.drain()
            }
        #endif

        #if SAGA_METAL_NATIVE_PASS && os(macOS)
            @MainActor
            @Test
            func nativeSubmissionKeepsResourcesUntilMetalCompletes() async throws {
                let device = try MetalBackend.makeDevice()
                let context = SAGAContext(
                    capabilities: device.capabilities,
                    supportsPresentation: false,
                    shaderOutput: .msl,
                    debugErrors: false,
                    makeDevice: { try await Device.make(backend: device) }
                )
                let event = try #require(device.metalDevice.makeSharedEvent())
                defer {
                    if event.signaledValue == 0 {
                        event.signaledValue = 1
                    }
                }

                let committed = BackendCompletion()
                let bridgeAdvanced = BackendCompletion()
                let resourceReleased = BackendCompletion()
                let metalFinished = BackendCompletion()
                let observedRetirement = BackendCompletion()
                let outcomes = Mutex<[Bool]>([])
                let gpuFinishedAtRelease = Mutex(false)
                let pass = NativePass.onMainActor(label: "Hold GPU retirement", uses: []) { context in
                    let metal = try #require(context as? MetalNativePassContext)
                    metal.commandBuffer.encodeWaitForEvent(event, value: 1)
                    metal.commandBuffer.encodeSignalEvent(event, value: 2)
                    metal.commandBuffer.addCompletedHandler { command in
                        let result: Result<Void, GPUError> = command.status == .completed
                            ? .success(())
                            : .failure(.validation("Metal did not complete the native pass"))
                        Task { await metalFinished.finish(result) }
                    }
                    metal.addCommittedHandler { Task { await committed.finish(.success(())) } }
                }

                let commands = SAGACommandBuffer(context: context)
                commands.append { .native(pass) }
                commands.observeSubmissionResult { success in
                    outcomes.withLock { $0.append(success && event.signaledValue == 2) }
                    Task { await observedRetirement.finish(.success(())) }
                }
                weak var resource: RetainedResourceProbe?
                do {
                    let probe = RetainedResourceProbe {
                        gpuFinishedAtRelease.withLock { $0 = event.signaledValue == 2 }
                        Task { await resourceReleased.finish(.success(())) }
                    }
                    resource = probe
                    commands.retainUntilRetired(probe)
                }
                commands.commit()
                context.queue.enqueueCleanup { await bridgeAdvanced.finish(.success(())) }

                try await committed.wait(timeout: .seconds(5))
                try await bridgeAdvanced.wait(timeout: .seconds(5))
                #expect(event.signaledValue == 0)
                #expect(resource != nil)
                #expect(outcomes.withLock { $0 }.isEmpty)

                event.signaledValue = 1
                try await resourceReleased.wait(timeout: .seconds(5))
                try await metalFinished.wait(timeout: .seconds(5))
                try await observedRetirement.wait(timeout: .seconds(5))
                #expect(outcomes.withLock { $0 } == [true], "Observation must report success only after Metal retirement.")
                #expect(gpuFinishedAtRelease.withLock { $0 })
                #expect(context.errorLog.all.isEmpty)
            }
        #endif

        private static func unavailableContext() throws -> SAGAContext {
            SAGAContext(
                capabilities: try DeviceCapabilities(maxBufferSize: 4096, maxTextureDimension2D: 64),
                supportsPresentation: true,
                shaderOutput: .msl,
                debugErrors: false,
                makeDevice: { throw GPUError.adapterUnavailable }
            )
        }

        @Test(arguments: [false, true])
        func completionWaitsForDeviceRetirement(emptyFence: Bool) async throws {
            let capabilities = try DeviceCapabilities(maxBufferSize: 4096, maxTextureDimension2D: 64)
            let backend = HeldSubmissionBackend(capabilities: capabilities)
            let context = SAGAContext(
                capabilities: capabilities,
                supportsPresentation: false,
                shaderOutput: .msl,
                debugErrors: false,
                makeDevice: { try await Device.make(backend: backend) }
            )
            let slot = context.createBuffer(.init(size: 4, usage: .copyDestination))
            let commands = SAGACommandBuffer(context: context)
            commands.append { .writeBytes(buffer: try slot.get(), offset: 0, bytes: [1, 2, 3, 4]) }
            let fence = emptyFence ? SAGACommandBuffer(context: context) : commands
            let callbacksSawRetirement = Mutex<[Bool]>([])
            fence.addCompletedHandler {
                callbacksSawRetirement.withLock { $0.append(backend.isRetired) }
            }
            fence.addCompletedTimingHandler { _ in
                callbacksSawRetirement.withLock { $0.append(backend.isRetired) }
            }
            commands.commit()
            if emptyFence {
                fence.commit()
            }

            try await backend.started.wait(timeout: .seconds(2))
            // Give the adapter an opportunity to dispatch an early callback while the backend is held.
            try await Task.sleep(for: .milliseconds(150))
            await backend.release.finish(.success(()))
            await context.queue.drain()

            #expect(callbacksSawRetirement.withLock { $0 } == [true, true], "Callbacks must observe completed device work")
            #expect(context.errorLog.all.isEmpty)
        }

        @Test
        func retainedResourcesDoNotDelayQueueAcceptance() async throws {
            let capabilities = try DeviceCapabilities(maxBufferSize: 4096, maxTextureDimension2D: 64)
            let backend = HeldSubmissionBackend(capabilities: capabilities)
            let context = SAGAContext(
                capabilities: capabilities,
                supportsPresentation: false,
                shaderOutput: .msl,
                debugErrors: false,
                makeDevice: { try await Device.make(backend: backend) }
            )
            let slot = context.createBuffer(.init(size: 4, usage: .copyDestination))
            let commands = SAGACommandBuffer(context: context)
            commands.append { .writeBytes(buffer: try slot.get(), offset: 0, bytes: [1, 2, 3, 4]) }
            let deallocated = BackendCompletion()
            let releasedAfterRetirement = Mutex(false)
            weak var resource: RetainedResourceProbe?
            do {
                let probe = RetainedResourceProbe {
                    releasedAfterRetirement.withLock { $0 = backend.isRetired }
                    Task { await deallocated.finish(.success(())) }
                }
                resource = probe
                commands.retainUntilRetired(probe)
            }
            commands.commit()
            let bridgeAdvanced = BackendCompletion()
            context.queue.enqueueCleanup { await bridgeAdvanced.finish(.success(())) }

            do {
                try await backend.started.wait(timeout: .seconds(2))
                try await bridgeAdvanced.wait(timeout: .seconds(2))
                #expect(resource != nil)
                #expect(!backend.isRetired)
            } catch {
                await backend.release.finish(.success(()))
                throw error
            }
            await backend.release.finish(.success(()))
            try await deallocated.wait(timeout: .seconds(2))
            #expect(releasedAfterRetirement.withLock { $0 })
        }
    }

    private final class RetainedResourceProbe: Sendable {
        private let onRelease: @Sendable () -> Void

        init(onRelease: @escaping @Sendable () -> Void) {
            self.onRelease = onRelease
        }

        deinit {
            onRelease()
        }
    }

    private final class HeldSubmissionBackend: CommandBackendDevice {
        let capabilities: DeviceCapabilities
        let started = BackendCompletion()
        let release = BackendCompletion()
        private let retired = Mutex(false)

        var isRetired: Bool { retired.withLock { $0 } }

        init(capabilities: DeviceCapabilities) {
            self.capabilities = capabilities
        }

        func allocateBuffer(id: ResourceID, descriptor: BufferDescriptor) async throws {}
        func destroyBuffer(id: ResourceID) async {}
        func submit(_ submission: Submission) async throws {}

        func submitCommands(_ submission: Submission, commands: [BufferCommand]) async throws -> [[UInt32]] {
            await started.finish(.success(()))
            try await release.wait(timeout: .seconds(5))
            retired.withLock { $0 = true }
            return []
        }
    }
#endif
