import AdaAssets
import Foundation
import Math
import Testing

@Suite
struct GLTFMaterialImportTests {
    @Test
    func importsFullCoreMaterialAndTextureSampler() throws {
        let result = try NativeGLTFLoader().load(data: document())
        let material = try #require(result.materials.first)
        #expect(material.baseColorFactor == Vector4(0.2, 0.3, 0.4, 0.7))
        #expect(material.normalScale == 0.6)
        #expect(material.occlusionStrength == 0.8)
        #expect(material.emissiveFactor == Vector3(0.1, 0.2, 0.3))
        #expect(material.emissiveStrength == 4)
        #expect(material.alphaMode == .mask)
        #expect(material.alphaCutoff == 0.35)
        #expect(material.doubleSided)
        #expect(material.textureCoordinates == [1, 0, 1, 0, 1])
        #expect(result.samplers[0].minFilter == 9987)
        #expect(result.samplers[0].wrapS == 33648)
        #expect(result.samplers[0].wrapT == 33071)
    }

    @Test
    func absentMaterialPropertiesUseGlTFDefaults() throws {
        let data = try JSONSerialization.data(withJSONObject: ["asset": ["version": "2.0"], "materials": [[:]]])
        let result = try NativeGLTFLoader().load(data: data)
        #expect(result.materials[0].baseColorFactor == .one)
        #expect(result.materials[0].metallicFactor == 1)
        #expect(result.materials[0].roughnessFactor == 1)
        #expect(result.materials[0].emissiveFactor == .zero)
        #expect(result.materials[0].alphaMode == .opaque)
        #expect(!result.materials[0].doubleSided)
    }

    @Test(arguments: ["factorLength", "textureIndex", "uvSet", "alpha", "strength"])
    func rejectsMalformedMaterials(kind: String) throws {
        let data = try document(invalid: kind)
        #expect(throws: NativeGLTFLoader.GLTFError.invalidMaterial(0)) { try NativeGLTFLoader().load(data: data) }
    }

    @Test
    func invalidSamplerFailsBeforeTextureCreation() throws {
        let data = try document(invalid: "sampler")
        #expect(throws: NativeGLTFLoader.GLTFError.invalidSampler(0)) { try NativeGLTFLoader().load(data: data) }
    }

    private func document(invalid: String? = nil) throws -> Data {
        var material: [String: Any] = [
            "pbrMetallicRoughness": ["baseColorFactor": [0.2, 0.3, 0.4, 0.7], "baseColorTexture": ["index": 0, "texCoord": 1]],
            "normalTexture": ["index": 0, "texCoord": 1, "scale": 0.6],
            "occlusionTexture": ["index": 0, "strength": 0.8],
            "emissiveTexture": ["index": 0, "texCoord": 1], "emissiveFactor": [0.1, 0.2, 0.3],
            "alphaMode": "MASK", "alphaCutoff": 0.35, "doubleSided": true,
            "extensions": ["KHR_materials_emissive_strength": ["emissiveStrength": 4]],
        ]
        switch invalid {
        case "factorLength": material["pbrMetallicRoughness"] = ["baseColorFactor": [1, 1]]
        case "textureIndex": material["normalTexture"] = ["index": 9]
        case "uvSet": material["normalTexture"] = ["index": 0, "texCoord": 2]
        case "alpha": material["alphaMode"] = "INVALID"
        case "strength": material["emissiveFactor"] = [-1, 0, 0]
        default: break
        }
        var result: [String: Any] = [:]
        result["asset"] = ["version": "2.0"]
        result["images"] = [["uri": "data:application/octet-stream;base64,AQID"]]
        result["textures"] = [["source": 0, "sampler": 0]]
        result["samplers"] = [["minFilter": invalid == "sampler" ? 123 : 9987, "magFilter": 9729, "wrapS": 33648, "wrapT": 33071]]
        result["materials"] = [material]
        return try JSONSerialization.data(withJSONObject: result)
    }
}
