//
//  SAGADLSS.swift
//  AdaEngine
//
//  NVIDIA DLSS Super Resolution on SAGA's Vulkan backend, through the optional NGX bridge.
//

#if SAGA_RENDER && SAGA_NATIVE && os(Windows) && canImport(SAGAVulkan) && canImport(SAGACompiler)
    import AdaUtils
    import Foundation
    import Logging
    import Math
    import SAGA
    import SAGACore
    import SAGATypes
    import SAGAVulkan
    import Synchronization

    /// One DLSS runtime per SAGA context: the loaded bridge and the result of initializing NGX on the context's device.
    final class SAGADLSSSession: Sendable {
        private enum State: Sendable {
            case initializing
            case ready
            case failed(String)
        }

        let bridge: DLSSBridge?
        private let state: Mutex<State>
        private let denoising = Mutex(false)

        /// Whether Ray Reconstruction is usable on this device.
        var supportsDenoising: Bool { denoising.withLock { $0 } }

        /// Loads the bridge, asks SAGA to enable the Vulkan extensions NGX needs and returns the session to start
        /// after the SAGA device exists. Must run before the first Vulkan adapter is requested.
        static func prepare(environment: [String: String] = ProcessInfo.processInfo.environment) -> SAGADLSSSession {
            let executable = Bundle.main.executableURL?.deletingLastPathComponent().path
            if let directory = DLSSRuntime.locate(
                environment: environment, executableDirectory: executable, fileExists: { FileManager.default.fileExists(atPath: $0) }
            ) {
                guard let bridge = DLSSBridge(directory: directory) else {
                    return SAGADLSSSession(bridge: nil, state: .failed("The DLSS bridge in \(directory) could not be loaded or has another ABI version"))
                }
                guard let extensions = bridge.requiredExtensions() else {
                    return SAGADLSSSession(bridge: nil, state: .failed("NGX did not report its required Vulkan extensions"))
                }
                VulkanExtensionRequest.set(instance: extensions.instance, device: extensions.device)
                return SAGADLSSSession(bridge: bridge, state: .initializing)
            }
            return SAGADLSSSession(bridge: nil, state: .failed(DLSSRuntime.probe(environment: environment, executableDirectory: executable, fileExists: {
                FileManager.default.fileExists(atPath: $0)
            }).unavailableReason ?? "DLSS is unavailable"))
        }

        private init(bridge: DLSSBridge?, state: State) {
            self.bridge = bridge
            self.state = Mutex(state)
        }

        var status: DLSSRuntimeStatus {
            state.withLock {
                switch $0 {
                case .ready: .available
                case .initializing: .unavailable(reason: "DLSS is still initializing")
                case let .failed(reason): .unavailable(reason: reason)
                }
            }
        }

        func fail(_ reason: String) { state.withLock { $0 = .failed(reason) } }

        /// Initializes NGX on the context's device from inside a native pass, where its Vulkan handles are visible.
        func start(on context: SAGAContext) {
            guard let bridge, case .initializing = state.withLock({ $0 }) else {
                return
            }
            context.queue.enqueue { [self] device in
                let pass = NativePass(label: "DLSS initialization", uses: []) { native in
                    guard let vulkan = native as? VulkanNativePassContext else {
                        self.fail("DLSS needs the SAGA Vulkan backend")
                        return
                    }
                    let outcome = bridge.initialize(
                        instance: vulkan.instance,
                        physicalDevice: vulkan.physicalDevice,
                        device: vulkan.device,
                        instanceProcedure: vulkan.instanceProcedure("vkGetInstanceProcAddr"),
                        deviceProcedure: vulkan.instanceProcedure("vkGetDeviceProcAddr"),
                        dataDirectory: NSTemporaryDirectory()
                    )
                    if outcome.supported {
                        self.denoising.withLock { $0 = bridge.supportsDenoising }
                        self.state.withLock { $0 = .ready }
                    } else if outcome.result == DLSSBridge.success {
                        self.fail("This GPU or driver does not support DLSS Super Resolution")
                    } else {
                        self.fail("NGX initialization failed (result 0x\(String(UInt32(bitPattern: outcome.result), radix: 16)))")
                    }
                }
                do {
                    _ = try await device.submitCommands([.native(pass)]).wait()
                } catch {
                    fail("DLSS initialization could not be submitted: \(error)")
                }
            }
        }
    }

    /// DLSS Super Resolution for one view. It owns the NGX feature, which lives as long as the view's sizes do not change.
    final class SAGADLSSUpscaler: TemporalUpscaler, @unchecked Sendable {
        private let session: SAGADLSSSession
        private let context: SAGAContext
        private let inputSize: SizeInt
        private let outputSize: SizeInt
        private let quality: Int32
        private let feature = Mutex<UnsafeMutableRawPointer?>(nil)
        private let denoiserFeature = Mutex<UnsafeMutableRawPointer?>(nil)

        var supportsDenoising: Bool { session.supportsDenoising }
        var supportsSpecularHitDistance: Bool { supportsDenoising && session.bridge?.supportsSpecularHitDistance == true }

        init?(session: SAGADLSSSession, context: SAGAContext, inputSize: SizeInt, outputSize: SizeInt) {
            guard session.bridge != nil, session.status.isAvailable else {
                return nil
            }
            self.session = session
            self.context = context
            self.inputSize = inputSize
            self.outputSize = outputSize
            let scale = Float(inputSize.width) / Float(max(1, outputSize.width))
            // NVSDK_NGX_PerfQuality_Value: MaxPerf 0, Balanced 1, MaxQuality 2, UltraPerformance 3, DLAA 5.
            switch DLSSQualityPreset.nearest(toRenderScale: scale) {
            case .dlaa: quality = 5
            case .quality: quality = 2
            case .balanced: quality = 1
            case .performance: quality = 0
            case .ultraPerformance: quality = 3
            }
        }

        deinit {
            // Earlier submissions may still use the features, so release them once the device has retired that work.
            let handles = [feature.withLock { $0 }, denoiserFeature.withLock { $0 }].compactMap { $0 }.map { UInt(bitPattern: $0) }
            guard let bridge = session.bridge, !handles.isEmpty else {
                return
            }
            context.queue.enqueue(onUnavailable: { handles.forEach { bridge.release(UnsafeMutableRawPointer(bitPattern: $0)) } }) { device in
                try await device.submitResourceUse([]).wait()
                handles.forEach { bridge.release(UnsafeMutableRawPointer(bitPattern: $0)) }
            }
        }

        func encodeDenoised(
            commandBuffer: CommandBuffer,
            color: Texture,
            depth: Texture,
            motion: Texture,
            reactive _: Texture,
            guides: RayReconstructionGuides,
            output: Texture,
            jitter: Vector2,
            reset: Bool
        ) -> Bool {
            guard session.status.isAvailable, session.supportsDenoising, let commands = commandBuffer as? SAGACommandBuffer else {
                return false
            }
            var inputs = [color, depth, motion, output, guides.diffuseAlbedo, guides.specularAlbedo, guides.normalRoughness]
            if supportsSpecularHitDistance, let distance = guides.specularHitDistance {
                inputs.append(distance)
            }
            let textures = inputs.compactMap { $0.gpuTexture as? SAGAGPUTexture }
            guard textures.count == inputs.count else {
                return false
            }
            func floats(_ transform: Transform3D) -> InlineArray<16, Float> {
                [
                    transform.x.x, transform.x.y, transform.x.z, transform.x.w, transform.y.x, transform.y.y, transform.y.z, transform.y.w,
                    transform.z.x, transform.z.y, transform.z.z, transform.z.w, transform.w.x, transform.w.y, transform.w.z, transform.w.w,
                ]
            }
            let worldToView = floats(guides.worldToView), viewToClip = floats(guides.viewToClip)
            commands.append { [self] in
                let ids = try textures.map { try $0.slot.get() }
                // Inputs are read; the output is the fourth texture.
                let uses = ids.enumerated().map { NativePass.Use($1, $0 == 3 ? .write : .read) }
                return .native(NativePass(label: "DLSS Ray Reconstruction", uses: uses) { native in
                    guard let vulkan = native as? VulkanNativePassContext else {
                        return
                    }
                    self.recordDenoised(
                        vulkan, ids: ids, worldToView: worldToView, viewToClip: viewToClip, jitter: jitter, reset: reset, context: commands.context
                    )
                })
            }
            return true
        }

        private func recordDenoised(
            _ vulkan: VulkanNativePassContext,
            ids: [ResourceID],
            worldToView: InlineArray<16, Float>,
            viewToClip: InlineArray<16, Float>,
            jitter: Vector2,
            reset: Bool,
            context: SAGAContext
        ) {
            guard let bridge = session.bridge, session.status.isAvailable else {
                return
            }
            let encoding = PerformanceStallProbe.begin()
            defer { PerformanceStallProbe.end("DLSS.RayReconstructionEncoding", since: encoding) }
            do {
                func image(_ id: ResourceID) throws -> DLSSBridgeImage {
                    let value = try vulkan.image(id)
                    return DLSSBridgeImage(
                        image: value.image, view: value.view, format: value.format, width: value.width, height: value.height, aspect: value.aspectMask
                    )
                }
                var created = false
                let handle: UnsafeMutableRawPointer? = try denoiserFeature.withLock { current in
                    if let current {
                        return current
                    }
                    let description = DLSSBridgeDescription(
                        inputWidth: UInt32(inputSize.width),
                        inputHeight: UInt32(inputSize.height),
                        outputWidth: UInt32(outputSize.width),
                        outputHeight: UInt32(outputSize.height),
                        quality: quality,
                        flags: 1 | 2
                    )
                    let outcome = bridge.createDenoiser(device: vulkan.device, commandBuffer: vulkan.commandBuffer, description: description)
                    guard outcome.result == DLSSBridge.success, let handle = outcome.handle else {
                        throw SAGADLSSError.createFailed(outcome.result)
                    }
                    current = handle
                    created = true
                    return handle
                }
                guard let handle else {
                    return
                }
                let frame = DLSSDBridgeFrame(
                    color: try image(ids[0]),
                    depth: try image(ids[1]),
                    motion: try image(ids[2]),
                    output: try image(ids[3]),
                    diffuseAlbedo: try image(ids[4]),
                    specularAlbedo: try image(ids[5]),
                    normalRoughness: try image(ids[6]),
                    worldToView: worldToView,
                    viewToClip: viewToClip,
                    jitterX: jitter.x,
                    jitterY: jitter.y,
                    motionScaleX: Float(inputSize.width),
                    motionScaleY: Float(inputSize.height),
                    inputWidth: UInt32(inputSize.width),
                    inputHeight: UInt32(inputSize.height),
                    reset: reset || created ? 1 : 0
                )
                let specularHitDistance = ids.count > 7 ? try image(ids[7]) : nil
                let result = bridge.evaluateDenoiser(
                    commandBuffer: vulkan.commandBuffer, handle: handle, frame: frame, specularHitDistance: specularHitDistance
                )
                if result != DLSSBridge.success { throw SAGADLSSError.evaluateFailed(result) }
            } catch {
                context.logger.error("DLSS Ray Reconstruction failed: \(error)")
                session.fail("DLSS Ray Reconstruction failed at run time: \(error)")
            }
        }

        func encode(
            commandBuffer: CommandBuffer,
            color: Texture,
            depth: Texture,
            motion: Texture,
            reactive _: Texture,
            output: Texture,
            jitter: Vector2,
            reset: Bool
        ) -> Bool {
            guard session.status.isAvailable, let commands = commandBuffer as? SAGACommandBuffer,
                let color = color.gpuTexture as? SAGAGPUTexture, let depth = depth.gpuTexture as? SAGAGPUTexture,
                let motion = motion.gpuTexture as? SAGAGPUTexture, let output = output.gpuTexture as? SAGAGPUTexture
            else { return false }
            commands.append { [self] in
                let ids = [try color.slot.get(), try depth.slot.get(), try motion.slot.get(), try output.slot.get()]
                let uses = zip(ids, [NativePass.Access.read, .read, .read, .write]).map { NativePass.Use($0, $1) }
                return .native(NativePass(label: "DLSS Super Resolution", uses: uses) { native in
                    guard let vulkan = native as? VulkanNativePassContext else {
                        return
                    }
                    self.record(vulkan, ids: ids, jitter: jitter, reset: reset, context: commands.context)
                })
            }
            return true
        }

        private func record(_ vulkan: VulkanNativePassContext, ids: [ResourceID], jitter: Vector2, reset: Bool, context: SAGAContext) {
            guard let bridge = session.bridge, session.status.isAvailable else {
                return
            }
            do {
                func image(_ id: ResourceID) throws -> DLSSBridgeImage {
                    let value = try vulkan.image(id)
                    return DLSSBridgeImage(
                        image: value.image, view: value.view, format: value.format, width: value.width, height: value.height, aspect: value.aspectMask
                    )
                }
                var created = false
                let handle: UnsafeMutableRawPointer? = try feature.withLock { current in
                    if let current {
                        return current
                    }
                    let description = DLSSBridgeDescription(
                        inputWidth: UInt32(inputSize.width),
                        inputHeight: UInt32(inputSize.height),
                        outputWidth: UInt32(outputSize.width),
                        outputHeight: UInt32(outputSize.height),
                        quality: quality,
                        flags: 1 | 2
                    )
                    let outcome = bridge.createFeature(device: vulkan.device, commandBuffer: vulkan.commandBuffer, description: description)
                    guard outcome.result == DLSSBridge.success, let handle = outcome.handle else {
                        throw SAGADLSSError.createFailed(outcome.result)
                    }
                    current = handle
                    created = true
                    return handle
                }
                guard let handle else {
                    return
                }
                let frame = DLSSBridgeFrame(
                    color: try image(ids[0]),
                    depth: try image(ids[1]),
                    motion: try image(ids[2]),
                    output: try image(ids[3]),
                    jitterX: jitter.x,
                    jitterY: jitter.y,
                    motionScaleX: Float(inputSize.width),
                    motionScaleY: Float(inputSize.height),
                    inputWidth: UInt32(inputSize.width),
                    inputHeight: UInt32(inputSize.height),
                    reset: reset || created ? 1 : 0
                )
                let result = bridge.evaluate(commandBuffer: vulkan.commandBuffer, handle: handle, frame: frame)
                if result != DLSSBridge.success { throw SAGADLSSError.evaluateFailed(result) }
            } catch {
                // The frame keeps whatever the output held; later frames use the portable reconstruction.
                context.logger.error("DLSS failed: \(error)")
                session.fail("DLSS failed at run time: \(error)")
            }
        }
    }

    enum SAGADLSSError: Error {
        case createFailed(Int32)
        case evaluateFailed(Int32)
    }
#endif
