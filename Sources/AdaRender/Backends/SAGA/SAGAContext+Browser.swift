//
//  SAGAContext+Browser.swift
//  AdaEngine
//

#if SAGA_RENDER && SAGA_WEBGPU && canImport(SAGAWebHost) && canImport(SAGACompiler)
    import SAGA
    import SAGACore
    import SAGAShaderIR
    import SAGATypes
    import SAGAWebGPU
    import SAGAWebHost

    extension SAGAContext {
        /// A context that renders through SAGA's JavaScript WebGPU host, reached over `transport`.
        convenience init(
            capabilities: DeviceCapabilities,
            supportsPresentation: Bool,
            debugErrors: Bool = false,
            transport: some BrowserTransport
        ) {
            installBrowserTransport(transport)
            self.init(
                capabilities: capabilities,
                supportsPresentation: supportsPresentation,
                shaderOutput: .wgsl,
                debugErrors: debugErrors,
                makeDevice: {
                    let host = makeWebGPUHost(capabilities: capabilities, supportsPresentation: supportsPresentation)
                    return try await Device.make(backend: BrowserComputeBackend(host: host))
                }
            )
        }
    }
#endif
