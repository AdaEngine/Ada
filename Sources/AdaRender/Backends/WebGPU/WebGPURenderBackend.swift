#if WEBGPU_ENABLED && canImport(WebGPU)
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
            private static func requestAdapter(instance: WebGPU.GPUInstance, logger _: Logger) throws -> WebGPU.GPUAdapter {
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

                return adapter
            }

            private static var adapterOptions: WebGPU.GPURequestAdapterOptions {
                #if os(Windows)
                    WebGPU.GPURequestAdapterOptions(
                        powerPreference: .highPerformance,
                        backendType: .D3D12
                    )
                #elseif os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
                    WebGPU.GPURequestAdapterOptions(
                        powerPreference: .highPerformance,
                        backendType: .metal
                    )
                #elseif os(Linux)
                    WebGPU.GPURequestAdapterOptions(powerPreference: .highPerformance)
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

                logger.info(
                    "Selected WebGPU adapter: backend=\(info.backendType.rawValue) vendor=\(info.vendor) device=\(info.device) description=\(info.description)"
                )
            }

            private static func requestDevice(
                instance: WebGPU.GPUInstance,
                adapter: WebGPU.GPUAdapter,
                logger: Logger
            ) throws -> WebGPU.GPUDevice {
                var requestStatus: WebGPU.GPURequestDeviceStatus?
                var requestedDevice: WebGPU.GPUDevice?
                var requestMessage: String?
                let descriptor = WebGPU.GPUDeviceDescriptor(
                    label: "AdaEngine WebGPU Device",
                    requiredFeatures: [.depth32FloatStencil8, .float32Filterable],
                    requiredLimits: nil,
                    defaultQueue: WebGPU.GPUQueueDescriptor(),
                    deviceLostCallbackInfo: WebGPU.GPUDeviceLostCallbackInfo(mode: .allowProcessEvents) { _, deviceLostReason, message in
                        logger.info("Device lost: \(deviceLostReason.rawValue): \(message)")
                    },
                    // Swan's generated uncaptured-error callback wrapper releases its userdata
                    // after invocation, but Dawn may call this callback many times over a device's
                    // lifetime. Disable it here to avoid dangling Swift callback userdata.
                    uncapturedErrorCallbackInfo: WebGPU.GPUUncapturedErrorCallbackInfo { _, _, _ in },
                    nextInChain: nil
                )
                let requestCallbackInfo = WebGPU.GPURequestDeviceCallbackInfo(mode: .allowProcessEvents) { status, device, message in
                    requestStatus = status
                    requestedDevice = device
                    requestMessage = message
                }
                _ = descriptor.withWGPUStruct { descriptor in
                    var descriptor = descriptor
                    descriptor.uncapturedErrorCallbackInfo.callback = nil
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
                    throw WebGPUBackendError.requestDeviceFailed(requestMessage ?? "unknown error")
                }

                return device
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
