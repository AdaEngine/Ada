//
//  SAGAContext.swift
//  AdaEngine
//
//  Owns the SAGA device that backs a SAGA render path (browser WebGPU or native Vulkan).
//

#if SAGA_RENDER && canImport(SAGACompiler)
    import AdaUtils
    import Foundation
    import Logging
    import SAGA
    import SAGABackend
    import SAGACompiler
    import SAGAShaderIR
    import SAGACore
    import SAGATypes
    import Synchronization

    /// Thread-safe list of device error messages.
    final class SAGAErrorLog: Sendable {
        private let messages = Mutex<[String]>([])
        var all: [String] { messages.withLock { $0 } }
        func record(_ message: String) { messages.withLock { $0.append(message) } }
    }

    /// Shared state for the SAGA render backend.
    ///
    /// SAGA's `Device` is an actor with asynchronous resource creation. AdaRender's API is synchronous,
    /// so every device operation goes through ``queue``, which preserves submission order.
    final class SAGAContext: Sendable {
        let capabilities: DeviceCapabilities
        let supportsPresentation: Bool
        let queue: OrderedGPUWorkQueue<Device>
        /// Waits for each submission and logs device errors. Enabled by `globalThis.__adaSAGADebug = true`.
        /// `ADAENGINE_SAGA_DEBUG=1` turns on error and missing-binding reports for every context.
        static var debugFromEnvironment: Bool { ProcessInfo.processInfo.environment["ADAENGINE_SAGA_DEBUG"] == "1" }

        let debugErrors: Bool
        let logger = Logger(label: "org.adaengine.saga")

        /// The shader format the device consumes: WGSL in the browser, SPIR-V on Vulkan.
        let shaderOutput: ShaderOutputFormat
        /// Messages of failed device operations, kept for diagnostics and tests.
        let errorLog = SAGAErrorLog()

        /// - Parameter makeDevice: Creates the SAGA `Device`. It runs on the first queued operation.
        init(
            capabilities: DeviceCapabilities,
            supportsPresentation: Bool,
            shaderOutput: ShaderOutputFormat,
            debugErrors: Bool = SAGAContext.debugFromEnvironment,
            makeDevice: @escaping @Sendable () async throws -> Device
        ) {
            self.debugErrors = debugErrors
            if debugErrors {
                FileHandle.standardError.write(Data("[SAGA] debug error logging enabled\n".utf8))
            }
            self.capabilities = capabilities
            self.supportsPresentation = supportsPresentation
            self.shaderOutput = shaderOutput
            let errorLog = self.errorLog
            self.queue = OrderedGPUWorkQueue<Device>(
                context: makeDevice,
                onError: { error in
                    errorLog.record("\(error)")
                    FileHandle.standardError.write(Data("[SAGA] device operation failed: \(error)\n".utf8))
                }
            )
        }

        /// Creates a SAGA buffer without blocking and returns the slot its id is written to.
        func createBuffer(_ descriptor: BufferDescriptor) -> ResourceSlot<ResourceID> {
            let slot = ResourceSlot<ResourceID>()
            queue.enqueue { device in
                slot.fulfill(try await device.createBuffer(descriptor))
            }
            return slot
        }

        private let clearPipelines = Mutex<[String: ResourceSlot<SAGATypes.RenderPipeline>]>([:])

        /// A pipeline that draws a degenerate triangle. A pass that records no draw uses it so its clears still run.
        func clearPipeline(colors: [TextureFormat], depth: TextureFormat?) -> ResourceSlot<SAGATypes.RenderPipeline> {
            let key = colors.map { String($0.rawValue) }.joined(separator: ",") + "|" + (depth.map { String($0.rawValue) } ?? "-")
            return clearPipelines.withLock { cache in
                if let existing = cache[key] { return existing }
                let slot = ResourceSlot<SAGATypes.RenderPipeline>()
                cache[key] = slot
                let output = shaderOutput
                queue.enqueue { device in
                    var outputs = ""
                    var assignments = ""
                    for index in colors.indices {
                        outputs += "@location(\(index)) c\(index): vec4<f32>, "
                        assignments += "out.c\(index) = vec4<f32>(0.0); "
                    }
                    let source = """
                    struct Out { \(outputs) }
                    @vertex fn vs() -> @builtin(position) vec4<f32> { return vec4<f32>(0.0, 0.0, 0.0, 1.0); }
                    @fragment fn fs() -> Out { var out: Out; \(assignments) return out; }
                    """
                    let compiler = IndependentShaderCompiler()
                    let vertex = try compiler.compileRenderStage(.wgsl(source), entryPoint: "vs", to: output)
                    let fragment = colors.isEmpty ? nil : try compiler.compileRenderStage(.wgsl(source), entryPoint: "fs", to: output)
                    slot.fulfill(
                        try await device.createRenderPipeline(
                            vertex: vertex,
                            fragment: fragment,
                            colorFormat: colors.first,
                            depthState: depth.map { RenderDepthState(format: $0, compare: .always, writeEnabled: false) },
                            additionalColorTargets: Dictionary(
                                uniqueKeysWithValues: colors.enumerated().dropFirst().map { (UInt32($0.offset), RenderColorTarget(format: $0.element)) }
                            )
                        )
                    )
                }
                return slot
            }
        }

        func createSampler(_ descriptor: SAGATypes.SamplerDescriptor) -> ResourceSlot<ResourceID> {
            let slot = ResourceSlot<ResourceID>()
            queue.enqueue { device in
                slot.fulfill(try await device.createSampler(descriptor))
            }
            return slot
        }
    }
#endif
