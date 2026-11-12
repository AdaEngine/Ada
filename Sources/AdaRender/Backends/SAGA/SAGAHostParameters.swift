//
//  SAGAHostParameters.swift
//  AdaEngine
//

#if SAGA_WEBGPU && canImport(SAGAWebHost) && canImport(JavaScriptKit)
    import JavaScriptKit
    import SAGAWebHost

    extension WebHostParameters {
        /// Reads the values SAGA's JavaScript host (`openWebGPU` in `webgpu.mjs`) exposes as properties.
        init(host: JSObject) {
            self.init()
            func flag(_ name: String) -> UInt32 {
                host[name].boolean == true || (host[name].number ?? 0) != 0 ? 1 : 0
            }
            func number(_ name: String) -> UInt32 {
                UInt32(clamping: Int(host[name].number ?? 0))
            }
            maxBufferSize = UInt64(host.maxBufferSize.number ?? 0)
            maxTextureDimension2D = number("maxTextureDimension2D")
            presentation = flag("supportsPresentation")
            readableStorage = flag("supportsReadableStorage")
            shaderF16 = flag("supportsShaderF16")
            uniformBufferStandardLayout = flag("supportsUniformBufferStandardLayout")
            indirectFirstInstance = flag("supportsIndirectFirstInstance")
            clipDistances = flag("supportsClipDistances")
            primitiveIndex = flag("supportsPrimitiveIndex")
            depthClipControl = flag("supportsDepthClipControl")
            timestampQuery = flag("supportsTimestampQuery")
            subgroups = flag("supportsSubgroups")
            subgroupID = flag("supportsSubgroupID")
            dualSourceBlending = flag("supportsDualSourceBlending")
            textureCompressionBC = flag("supportsTextureCompressionBC")
            textureCompressionETC2 = flag("supportsTextureCompressionETC2")
            textureCompressionASTC = flag("supportsTextureCompressionASTC")
            textureCompressionBCSliced3D = flag("supportsTextureCompressionBCSliced3D")
            textureCompressionASTCSliced3D = flag("supportsTextureCompressionASTCSliced3D")
            float32Filterable = flag("supportsFloat32Filtering")
            float32Blendable = flag("supportsFloat32Blending")
            multisampledFloat32Mask = number("multisampledFloat32Mask")
            textureFormatsTier1 = flag("supportsTextureFormatsTier1")
            textureFormatsTier2 = flag("supportsTextureFormatsTier2")
            rg11b10UfloatRenderable = flag("supportsRG11B10Render")
            depth32FloatStencil8 = flag("supportsDepth32FloatStencil8")
            bgra8UnormStorage = flag("supportsBGRA8UnormStorage")
            maxImmediateSize = number("maxImmediateSize")
            linearIndexing = flag("supportsLinearIndexing")
            subgroupSizeControl = flag("supportsSubgroupSizeControl")
            subgroupMinSize = number("subgroupMinSize")
            subgroupMaxSize = number("subgroupMaxSize")
            subgroupUniformity = flag("supportsSubgroupUniformity")
            maxComputeWorkgroupStorageSize = number("maxComputeWorkgroupStorageSize")
            maxComputeInvocationsPerWorkgroup = number("maxComputeInvocationsPerWorkgroup")
            let workgroup = host.maxComputeWorkgroupSize.object
            maxComputeWorkgroupSizeX = UInt32(clamping: Int(workgroup?.x.number ?? 0))
            maxComputeWorkgroupSizeY = UInt32(clamping: Int(workgroup?.y.number ?? 0))
            maxComputeWorkgroupSizeZ = UInt32(clamping: Int(workgroup?.z.number ?? 0))
            maxComputeWorkgroupsPerDimension = number("maxComputeWorkgroupsPerDimension")
            maxVertexAttributes = number("maxVertexAttributes")
            maxVertexBuffers = number("maxVertexBuffers")
            maxVertexBufferArrayStride = number("maxVertexBufferArrayStride")
            vertexFormatSnorm1010102 = flag("supportsVertexFormatSnorm1010102")
            maxInterStageShaderVariables = number("maxInterStageShaderVariables")
            maxColorAttachments = number("maxColorAttachments")
            maxColorAttachmentBytesPerSample = number("maxColorAttachmentBytesPerSample")
            maxBindGroupsPlusVertexBuffers = number("maxBindGroupsPlusVertexBuffers")
        }
    }
#endif
