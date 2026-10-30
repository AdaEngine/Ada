extension PBRMaterial {
    /// Copies surface state and shares texture assets. Graph values are independent
    /// changing a model instance never mutates the imported asset's material.
    public func makeInstance() -> PBRMaterial {
        let result = PBRMaterial()
        result.baseColorFactor = baseColorFactor
        result.baseColorTexture = baseColorTexture
        result.metallicFactor = metallicFactor
        result.roughnessFactor = roughnessFactor
        result.metallicRoughnessTexture = metallicRoughnessTexture
        result.normalTexture = normalTexture
        result.emissiveTexture = emissiveTexture
        result.emissiveStrength = emissiveStrength
        result.emissiveFactor = emissiveFactor
        result.occlusionTexture = occlusionTexture
        result.occlusionStrength = occlusionStrength
        result.normalScale = normalScale
        result.heightTexture = heightTexture
        result.heightScale = heightScale
        result.heightTextureCoordinate = heightTextureCoordinate
        result.heightMaxLayers = heightMaxLayers
        result.heightFadeDistance = heightFadeDistance
        result.alphaMode = alphaMode
        result.alphaCutoff = alphaCutoff
        result.doubleSided = doubleSided
        result.textureCoordinates = textureCoordinates
        result.emissiveLightThreshold = emissiveLightThreshold
        result.textureTransforms = textureTransforms
        result.ior = ior
        result.specularFactor = specularFactor
        result.specularColorFactor = specularColorFactor
        result.clearcoatFactor = clearcoatFactor
        result.clearcoatRoughnessFactor = clearcoatRoughnessFactor
        result.sheenColorFactor = sheenColorFactor
        result.sheenRoughnessFactor = sheenRoughnessFactor
        result.anisotropyStrength = anisotropyStrength
        result.anisotropyRotation = anisotropyRotation
        result.layerTextures = layerTextures
        result.graphMaterial = graphMaterial?.makeInstance()
        result.lightmapTexture = lightmapTexture
        result.lightmapScaleOffset = lightmapScaleOffset
        result.lightmapIntensity = lightmapIntensity
        result.assetMetaInfo = assetMetaInfo
        return result
    }
}
