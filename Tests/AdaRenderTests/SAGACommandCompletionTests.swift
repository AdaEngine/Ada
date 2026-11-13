#if SAGA_METAL
    @testable import AdaRender
    import AdaUtils
    import Math
    import SAGABackend
    import SAGACore
    import SAGAShaderIR
    import SAGATypes
    import Synchronization
    import Testing

    struct SAGACommandCompletionTests {
        @Test
        func completionRunsWhenTheDeviceCannotBeCreated() async throws {
            let context = try Self.unavailableContext()
            let commands = SAGACommandBuffer(context: context)
            let completions = Mutex(0)
            commands.addCompletedHandler { completions.withLock { $0 += 1 } }
            commands.addCompletedTimingHandler { _ in completions.withLock { $0 += 1 } }
            commands.commit()
            await context.queue.drain()

            #expect(completions.withLock { $0 } == 2, "A failed device must still notify both handlers")
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
