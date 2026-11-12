//
//  SAGAContext+Vulkan.swift
//  AdaEngine
//

#if SAGA_RENDER && SAGA_NATIVE && canImport(SAGAVulkan) && canImport(SAGACompiler)
    import SAGA
    import SAGACore
    import SAGAShaderIR
    import SAGATypes
    import SAGAVulkan

    extension SAGAContext {
        /// Whether a Vulkan driver with a usable adapter is installed.
        static var isVulkanAvailable: Bool {
            VulkanBackend.requestAdapter() != nil
        }

        /// A context that renders offscreen through SAGA's Vulkan runtime. Presentation is not wired yet.
        static func vulkan(debugErrors: Bool = false) throws -> SAGAContext {
            let backend = try VulkanBackend.makeDevice()
            return SAGAContext(
                capabilities: backend.capabilities,
                supportsPresentation: false,
                shaderOutput: .spirv,
                debugErrors: debugErrors,
                makeDevice: { try await Device.make(backend: backend) }
            )
        }
    }
#endif
