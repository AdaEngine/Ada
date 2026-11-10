#if WEBGPU_ENABLED && canImport(WebGPU)
    #if os(Android)
        import CAndroid
    #endif
    import AdaUtils
    import Foundation
    import Logging
    import Math
    import Synchronization
    @unsafe @preconcurrency import WebGPU
    #if WASM && canImport(JavaScriptKit)
        import JavaScriptKit
    #endif

    final class WebGPURenderBackend: RenderBackend, @unchecked Sendable {
        func createLocalRenderDevice() -> any RenderDevice {
            WebGPURenderDevice(context: context)
        }

        func createWindow(_ windowId: WindowID, for surface: any RenderSurface, size: Math.SizeInt) throws {
            try context.createWindow(windowId, for: surface, size: size)
        }

        func resizeWindow(_ windowId: WindowID, newSize: Math.SizeInt) throws {
            try context.resizeWindow(windowId, newSize: newSize)
        }

        @MainActor
        func resizeWindow(_ windowId: WindowID, newSize: Math.SizeInt, scaleFactor: Float) throws {
            try context.resizeWindow(windowId, newSize: newSize, scaleFactor: scaleFactor)
        }

        func destroyWindow(_ windowId: WindowID) throws {
            try context.destroyWindow(windowId)
        }

        func getRenderWindow(for windowId: WindowID) -> RenderWindow? {
            context.getRenderWindow(for: windowId)
        }

        func getRenderWindows() throws -> RenderWindows {
            try context.getRenderWindows()
        }

        let type: RenderBackendType = .webgpu
        let renderDevice: RenderDevice
        private let context: WGPUContext

        init(device: WebGPU.GPUDevice, adapter: WebGPU.GPUAdapter, instance: WebGPU.GPUInstance) {
            self.context = WGPUContext(device: device, adapter: adapter, instance: instance)
            self.renderDevice = WebGPURenderDevice(context: context)
        }
    }

    extension WebGPURenderBackend {
        static func createBackend() throws -> WebGPURenderBackend {
            #if WASM && canImport(JavaScriptKit)
                guard let deviceObject = JSObject.global.__adaWebGPUDevice.object else {
                    throw WebGPUBackendError.requestDeviceFailed("Browser WebGPU device was not initialized before Swift startup.")
                }
                guard let adapterObject = JSObject.global.__adaWebGPUAdapter.object else {
                    throw WebGPUBackendError.requestAdapterFailed("Browser WebGPU adapter was not initialized before Swift startup.")
                }

                return WebGPURenderBackend(
                    device: WebGPU.GPUDevice(unsafelyWrapping: deviceObject),
                    adapter: WebGPU.GPUAdapter(unsafelyWrapping: adapterObject),
                    instance: WebGPU.GPUInstance()
                )
            #else
                let instanceDescriptor = WebGPU.GPUInstanceDescriptor(
                    requiredFeatures: [.shaderSourceSPIRV]
                )
                guard
                    let instance = instanceDescriptor.withWGPUStruct({ descriptor in
                        withUnsafePointer(to: &descriptor) { descriptor in
                            WebGPU.GPUInstance(descriptor: descriptor)
                        }
                    })
                else {
                    throw WebGPUBackendError.instanceCreationFailed
                }
                let logger = Logger(label: "org.adaengine.webgpu")
                let adapter = try requestAdapter(instance: instance, logger: logger)
                let device = try requestDevice(instance: instance, adapter: adapter, logger: logger)

                return WebGPURenderBackend(device: device, adapter: adapter, instance: instance)
            #endif
        }

        #if !WASM
            private static func requestAdapter(instance: WebGPU.GPUInstance, logger: Logger) throws -> WebGPU.GPUAdapter {
                var requestStatus: WebGPU.GPURequestAdapterStatus?
                var requestedAdapter: WebGPU.GPUAdapter?
                var requestMessage: String?
                _ = instance.requestAdapter(
                    options: adapterOptions,
                    callbackInfo: WebGPU.GPURequestAdapterCallbackInfo(mode: .allowProcessEvents) { status, adapter, message in
                        requestStatus = status
                        requestedAdapter = adapter
                        requestMessage = message
                    }
                )

                while requestStatus == nil {
                    instance.processEvents()
                }

                guard requestStatus == .success, let adapter = requestedAdapter else {
                    throw WebGPUBackendError.requestAdapterFailed(requestMessage ?? "unknown error")
                }

                logAdapterInfo(adapter, logger: logger)
                return adapter
            }

            /// Release builds skip Dawn's per-call WebGPU validation, which costs about 1 ms of CPU per frame in large
            /// scenes; the engine's own usage is validated by debug builds and tests. `ADAENGINE_WEBGPU_VALIDATION=1`
            /// keeps validation in a release build, `=0` skips it in a debug build.
            private static var skipsValidation: Bool {
                switch ProcessInfo.processInfo.environment["ADAENGINE_WEBGPU_VALIDATION"] {
                case "1": return false
                case "0": return true
                default:
                    #if DEBUG
                        return false
                    #else
                        return true
                    #endif
                }
            }

            private static var adapterOptions: WebGPU.GPURequestAdapterOptions {
                #if os(Windows) && canImport(CWebGPUDLSS)
                    WebGPU.GPURequestAdapterOptions(
                        powerPreference: .highPerformance,
                        backendType: .D3D12,
                        nextInChain: WebGPU.DawnTogglesDescriptor(enabledToggles: ["allow_unsafe_apis"])
                    )
                #elseif os(Windows)
                    WebGPU.GPURequestAdapterOptions(
                        powerPreference: .highPerformance,
                        backendType: .D3D12
                    )
                #elseif os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
                    WebGPU.GPURequestAdapterOptions(
                        powerPreference: .highPerformance,
                        backendType: .metal
                    )
                #elseif os(Android)
                    WebGPU.GPURequestAdapterOptions(powerPreference: .highPerformance, backendType: .vulkan)
                #elseif os(Linux)
                    WebGPU.GPURequestAdapterOptions(powerPreference: .highPerformance, backendType: .vulkan)
                #else
                    WebGPU.GPURequestAdapterOptions(powerPreference: .highPerformance)
                #endif
            }

            private static func logAdapterInfo(_ adapter: WebGPU.GPUAdapter, logger: Logger) {
                var info = WebGPU.GPUAdapterInfo()
                guard adapter.getInfo(info: &info) == .success else {
                    logger.info("Selected WebGPU adapter, but adapter info is unavailable.")
                    return
                }

                let message = "Selected WebGPU adapter: backend=\(info.backendType.rawValue) vendor=\(info.vendor) device=\(info.device) description=\(info.description)"
                logger.info("\(message)")
                #if os(Android)
                    unsafe message.withCString { unsafe ada_android_log($0) }
                #endif
            }

            private static func requestDevice(
                instance: WebGPU.GPUInstance,
                adapter: WebGPU.GPUAdapter,
                logger: Logger
            ) throws -> WebGPU.GPUDevice {
                var requestStatus: WebGPU.GPURequestDeviceStatus?
                var requestedDevice: WebGPU.GPUDevice?
                var requestMessage: String?
                var supportedLimits = WebGPU.GPULimits()
                guard adapter.getLimits(limits: &supportedLimits) == .success else {
                    throw WebGPUBackendError.requestDeviceFailed("Unable to query adapter limits.")
                }
                // The complete PBR texture set and graph bindings exceed the baseline of 16.
                let requiredLimits = WebGPU.GPULimits(
                    maxSampledTexturesPerShaderStage: min(32, supportedLimits.maxSampledTexturesPerShaderStage),
                    maxSamplersPerShaderStage: min(32, supportedLimits.maxSamplersPerShaderStage),
                    maxColorAttachmentBytesPerSample: min(48, supportedLimits.maxColorAttachmentBytesPerSample)
                )
                var features: [WebGPU.GPUFeatureName] = [.depth32FloatStencil8, .float32Filterable]
                #if !WASM
                // GPU-driven shadow batching issues one multi-draw per draw group when both are available.
                features += [.multiDrawIndirect, .indirectFirstInstance].filter { adapter.hasFeature(feature: $0) }
                // Profiling only: per-command-buffer GPU timings (WGPUTimestampQuery).
                if WGPUTimestampQuery.isRequested, adapter.hasFeature(feature: .timestampQuery) {
                    features.append(.timestampQuery)
                }
                #endif
                var nativeToggles: (any WebGPU.GPUChainedStruct)?
                var enabledToggles: [String] = []
                #if os(Windows) && canImport(CWebGPUDLSS)
                // Native-only Dawn extensions. This is never requested by browser WebGPU.
                features += [.sharedTextureMemoryD3D12Resource, .sharedFenceDXGISharedHandle].filter {
                    adapter.hasFeature(feature: $0)
                }
                enabledToggles.append("allow_unsafe_apis")
                #endif
                if Self.skipsValidation {
                    enabledToggles.append("skip_validation")
                }
                var disabledToggles: [String] = []
                #if !WASM
                if WGPUTimestampQuery.isRequested {
                    // Profiling needs microsecond timestamps, not the privacy-quantized ones.
                    disabledToggles.append("timestamp_quantization")
                }
                #endif
                if !enabledToggles.isEmpty || !disabledToggles.isEmpty {
                    nativeToggles = WebGPU.DawnTogglesDescriptor(enabledToggles: enabledToggles, disabledToggles: disabledToggles)
                }
                let pipelineCache = makePipelineCache(adapter: adapter, logger: logger)
                // Dawn may call the cache until the device is destroyed, which can outlive
                // this backend, so the device chain owns one retain for the process lifetime.
                let pipelineCacheUserdata = unsafe pipelineCache.map { unsafe Unmanaged.passRetained($0).toOpaque() }
                if let pipelineCacheUserdata = unsafe pipelineCacheUserdata {
                    nativeToggles = unsafe WebGPU.DawnCacheDeviceDescriptor(
                        isolationKey: "AdaEngine",
                        loadDataFunction: { key, keySize, value, valueSize, userdata in
                            guard let key = unsafe key, let userdata = unsafe userdata else {
                                return 0
                            }
                            let cache = unsafe Unmanaged<PipelineDiskCache>.fromOpaque(userdata).takeUnretainedValue()
                            let output = unsafe value.map { unsafe UnsafeMutableRawBufferPointer(start: $0, count: valueSize) }
                            return unsafe cache.load(key: UnsafeRawBufferPointer(start: key, count: keySize), into: output)
                        },
                        storeDataFunction: { key, keySize, value, valueSize, userdata in
                            guard let key = unsafe key, let value = unsafe value, let userdata = unsafe userdata else {
                                return
                            }
                            let cache = unsafe Unmanaged<PipelineDiskCache>.fromOpaque(userdata).takeUnretainedValue()
                            unsafe cache.store(
                                key: UnsafeRawBufferPointer(start: key, count: keySize),
                                value: UnsafeRawBufferPointer(start: value, count: valueSize)
                            )
                        },
                        functionUserdata: pipelineCacheUserdata,
                        nextInChain: nativeToggles
                    )
                }
                let descriptor = WebGPU.GPUDeviceDescriptor(
                    label: "AdaEngine WebGPU Device",
                    requiredFeatures: features,
                    requiredLimits: requiredLimits,
                    defaultQueue: WebGPU.GPUQueueDescriptor(),
                    deviceLostCallbackInfo: WebGPU.GPUDeviceLostCallbackInfo(mode: .allowSpontaneous) { _, deviceLostReason, message in
                        logger.info("Device lost: \(deviceLostReason.rawValue): \(message)")
                    },
                    // Swan's generated uncaptured-error callback wrapper releases its userdata
                    // after invocation, but Dawn may call this callback many times over a device's
                    // lifetime. Disable it here to avoid dangling Swift callback userdata.
                    uncapturedErrorCallbackInfo: WebGPU.GPUUncapturedErrorCallbackInfo { _, _, _ in },
                    nextInChain: nativeToggles
                )
                let requestCallbackInfo = WebGPU.GPURequestDeviceCallbackInfo(mode: .allowProcessEvents) { status, device, message in
                    requestStatus = status
                    requestedDevice = device
                    requestMessage = message
                }
                _ = descriptor.withWGPUStruct { descriptor in
                    var descriptor = descriptor
                    // Release the generated one-shot closure before replacing it; the
                    // raw stateless callback below has no retained Swift userdata.
                    if let userdata = descriptor.uncapturedErrorCallbackInfo.userdata1 {
                        Unmanaged<AnyObject>.fromOpaque(userdata).release()
                    }
                    #if os(Android)
                    // Stateless C callback: Dawn can invoke it repeatedly without Swift userdata.
                    descriptor.uncapturedErrorCallbackInfo.callback = { _, type, message, _, _ in
                        let text = "WebGPU error \(type.rawValue): \(message.toString)"
                        unsafe text.withCString { unsafe ada_android_log($0) }
                    }
                    #else
                    descriptor.uncapturedErrorCallbackInfo.callback = { _, type, message, _, _ in
                        let text = "WebGPU error \(type.rawValue): \(message.toString)\n"
                        FileHandle.standardError.write(Data(text.utf8))
                    }
                    #endif
                    descriptor.uncapturedErrorCallbackInfo.userdata1 = nil
                    descriptor.uncapturedErrorCallbackInfo.userdata2 = nil

                    return requestCallbackInfo.withWGPUStruct { callbackInfo in
                        adapter.requestDevice(descriptor: &descriptor, callbackInfo: callbackInfo)
                    }
                }

                while requestStatus == nil {
                    instance.processEvents()
                }

                guard requestStatus == .success, let device = requestedDevice else {
                    if let pipelineCacheUserdata = unsafe pipelineCacheUserdata {
                        unsafe Unmanaged<PipelineDiskCache>.fromOpaque(pipelineCacheUserdata).release()
                    }
                    throw WebGPUBackendError.requestDeviceFailed(requestMessage ?? "unknown error")
                }

                return device
            }

            /// User cache root. On Windows Foundation's caches directory is %TEMP%, which
            /// Disk Cleanup empties, so the per-user %LOCALAPPDATA% is used instead.
            private static func pipelineCacheRoot() -> URL? {
                #if os(Windows)
                    if let localAppData = ProcessInfo.processInfo.environment["LOCALAPPDATA"], !localAppData.isEmpty {
                        return URL(fileURLWithPath: localAppData, isDirectory: true)
                    }
                #endif
                return try? FileSystem.current.url(for: .cachesDirectory)
            }

            /// Persistent Dawn blob cache, so translated and compiled shaders survive restarts.
            private static func makePipelineCache(adapter: WebGPU.GPUAdapter, logger: Logger) -> PipelineDiskCache? {
                var info = WebGPU.GPUAdapterInfo()
                guard adapter.getInfo(info: &info) == .success else {
                    return nil
                }
                let fingerprint = [
                    "\(info.backendType.rawValue)",
                    String(info.vendorID, radix: 16),
                    String(info.deviceID, radix: 16),
                    info.vendor,
                    info.architecture,
                    info.device,
                    info.description
                ].joined(separator: "|")
                guard let directory = PipelineDiskCache.directory(
                    environment: ProcessInfo.processInfo.environment,
                    cachesDirectory: pipelineCacheRoot(),
                    adapterFingerprint: fingerprint
                ) else {
                    logger.info("WebGPU pipeline disk cache disabled.")
                    return nil
                }
                logger.info("WebGPU pipeline disk cache: \(directory.path)")
                return PipelineDiskCache(directory: directory)
            }
        #endif
    }

    private enum WebGPUBackendError: LocalizedError {
        case instanceCreationFailed
        case requestAdapterFailed(String)
        case requestDeviceFailed(String)

        var errorDescription: String? {
            switch self {
            case .instanceCreationFailed:
                "Failed to create WebGPU instance."
            case let .requestAdapterFailed(message):
                "Failed to request WebGPU adapter: \(message)"
            case let .requestDeviceFailed(message):
                "Failed to request WebGPU device: \(message)"
            }
        }
    }

    #if !WASM
        extension WGPUStringView {
            var toString: String {
                guard let data, length > 0 else {
                    return ""
                }
                return data.withMemoryRebound(to: UInt8.self, capacity: length) { data in
                    String(bytes: UnsafeBufferPointer(start: data, count: length), encoding: .utf8) ?? ""
                }
            }
        }
    #endif
#endif
