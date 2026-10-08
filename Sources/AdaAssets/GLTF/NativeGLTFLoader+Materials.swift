import Math

extension NativeGLTFLoader {
    func importSamplers(_ gltf: GLTF) throws -> [GLTFImportResult.Sampler] {
        try (gltf.samplers ?? []).enumerated().map { index, sampler in
            let minFilter = sampler.minFilter ?? 9987
            let magFilter = sampler.magFilter ?? 9729
            let wrapS = sampler.wrapS ?? 10497
            let wrapT = sampler.wrapT ?? 10497
            guard [9728, 9729, 9984, 9985, 9986, 9987].contains(minFilter), [9728, 9729].contains(magFilter),
                  [10497, 33648, 33071].contains(wrapS), [10497, 33648, 33071].contains(wrapT)
            else { throw GLTFError.invalidSampler(index) }
            return .init(
                minFilter: minFilter,
                magFilter: magFilter,
                wrapS: wrapS,
                wrapT: wrapT
            )
        }
    }

    func importMaterials(_ gltf: GLTF) throws -> [GLTFImportResult.Material] {
        try (gltf.materials ?? []).enumerated().map { index, material in
            let pbr = material.pbrMetallicRoughness
            let base = pbr?.baseColorFactor ?? [1, 1, 1, 1]
            let emissive = material.emissiveFactor ?? [0, 0, 0]
            let metallic = pbr?.metallicFactor ?? 1
            let roughness = pbr?.roughnessFactor ?? 1
            let normalScale = material.normalTexture?.scale ?? 1
            let occlusion = material.occlusionTexture?.strength ?? 1
            let cutoff = material.alphaCutoff ?? 0.5
            let strength = material.extensions?.KHR_materials_emissive_strength?.emissiveStrength ?? 1
            let coordinates = [
                pbr?.baseColorTexture?.texCoord ?? 0,
                pbr?.metallicRoughnessTexture?.texCoord ?? 0,
                material.normalTexture?.texCoord ?? 0,
                material.occlusionTexture?.texCoord ?? 0,
                material.emissiveTexture?.texCoord ?? 0,
            ]
            let textures = [
                pbr?.baseColorTexture?.index,
                pbr?.metallicRoughnessTexture?.index,
                material.normalTexture?.index,
                material.occlusionTexture?.index,
                material.emissiveTexture?.index,
            ]
            guard base.count == 4, emissive.count == 3,
                  (base + emissive + [metallic, roughness, occlusion]).allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
                  normalScale.isFinite, cutoff.isFinite, cutoff >= 0, strength.isFinite, strength >= 0,
                  coordinates.allSatisfy({ $0 == 0 || $0 == 1 }),
                  textures.compactMap({ $0 }).allSatisfy({ (gltf.textures ?? []).indices.contains($0) }),
                  let alpha = GLTFImportResult.AlphaMode(rawValue: material.alphaMode ?? "OPAQUE")
            else { throw GLTFError.invalidMaterial(index) }
            return .init(
                name: material.name,
                baseColorFactor: Vector4(base[0], base[1], base[2], base[3]),
                baseColorTextureIndex: textures[0],
                metallicFactor: metallic,
                roughnessFactor: roughness,
                metallicRoughnessTextureIndex: textures[1],
                normalTextureIndex: textures[2],
                normalScale: normalScale,
                occlusionTextureIndex: textures[3],
                occlusionStrength: occlusion,
                emissiveTextureIndex: textures[4],
                emissiveFactor: Vector3(emissive[0], emissive[1], emissive[2]),
                emissiveStrength: strength,
                alphaMode: alpha,
                alphaCutoff: cutoff,
                doubleSided: material.doubleSided ?? false,
                textureCoordinates: coordinates
            )
        }
    }
}
