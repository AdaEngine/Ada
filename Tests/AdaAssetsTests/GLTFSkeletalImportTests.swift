import AdaAssets
import Foundation
import Math
import Testing

@Suite
struct GLTFSkeletalImportTests {
    @Test(arguments: [5121, 5123])
    func importsTypedJointsNormalizedWeightsAndBindPose(jointType: Int) throws {
        let fixture = SkeletalGLTFFixture(jointType: jointType)
        let result = try NativeGLTFLoader().load(data: fixture.data())
        let skin = try #require(result.skins.first)
        #expect(skin.name == "TwoBones")
        #expect(skin.joints == [1, 2])
        #expect(skin.skeletonRootIndex == 1)
        #expect(skin.inverseBindMatrices[0] == .identity)
        #expect(skin.inverseBindMatrices[1].origin == Vector3(0, -1, 0))
        #expect(result.nodes[0].skinIndex == 0)
        #expect(result.nodes[2].restPose?.translation == Vector3(0, 1, 0))
        let skinning = try #require(result.meshes[0].primitives[0].skinning)
        #expect(skinning.jointIndices[1] == SIMD4<UInt16>(0, 1, 0, 0))
        #expect(skinning.weights[0] == Vector4(1, 0, 0, 0))
        #expect(abs(skinning.weights[1].x - Float(128) / 255) < 0.00001)
        #expect(abs(skinning.weights[1].x + skinning.weights[1].y - 1) < 0.00001)
        #expect(result.animations[0].name == "Move")
        #expect(result.animations[0].duration == 1)
        #expect(result.animations[0].channels[0].nodeIndex == 2)
        #expect(result.animations[0].channels[0].path == .translation)
    }

    @Test(arguments: ["LINEAR", "STEP", "CUBICSPLINE"])
    func preservesInterpolationAndCubicTangents(interpolation: String) throws {
        let result = try NativeGLTFLoader().load(data: SkeletalGLTFFixture(interpolation: interpolation).data())
        let sampler = result.animations[0].samplers[0]
        #expect(sampler.times == [0, 1])
        #expect(sampler.interpolation.rawValue == interpolation)
        if interpolation == "CUBICSPLINE" {
            #expect(sampler.output.count == 6)
            #expect(sampler.output.values == [2, 0, 0, 0, 1, 0, 3, 0, 0, 4, 0, 0, 0, 2, 0, 5, 0, 0])
        } else {
            #expect(sampler.output.values == [0, 1, 0, 0, 2, 0])
        }
    }

    @Test
    func importsCubicQuaternionValuesWithoutNormalizingTangents() throws {
        var fixture = SkeletalGLTFFixture(interpolation: "CUBICSPLINE")
        let values: [Float] = [2, 0, 0, 0, 0, 0, 0, 1, 3, 0, 0, 0, 4, 0, 0, 0, 0, 0, 1, 0, 5, 0, 0, 0]
        fixture.setOutput(values, type: "VEC4")
        fixture.channels[0]["target"] = ["node": 2, "path": "rotation"]
        let result = try NativeGLTFLoader().load(data: fixture.data())
        #expect(result.animations[0].channels[0].path == .rotation)
        #expect(result.animations[0].samplers[0].output.values == values)
    }

    @Test
    func importsScaleAndDefaultLinearInterpolation() throws {
        var fixture = SkeletalGLTFFixture()
        fixture.interpolation = nil
        fixture.setOutput([1, 1, 1, 2, 2, 2], type: "VEC3")
        fixture.channels[0]["target"] = ["node": 2, "path": "scale"]
        let result = try NativeGLTFLoader().load(data: fixture.data())
        #expect(result.animations[0].channels[0].path == .scale)
        #expect(result.animations[0].samplers[0].interpolation == .linear)
        #expect(result.animations[0].samplers[0].output.values == [1, 1, 1, 2, 2, 2])
    }

    @Test(arguments: [Float.nan, Float.infinity, -0.5])
    func rejectsNonFiniteAndNegativeWeights(value: Float) throws {
        var fixture = SkeletalGLTFFixture()
        fixture.setWeights([value, 0, 0, 0, 0.5, 0.5, 0, 0, 1, 0, 0, 0])
        let data = try fixture.data()
        #expect(throws: NativeGLTFLoader.GLTFError.invalidSkinningAttributes) { try NativeGLTFLoader().load(data: data) }
    }

    @Test
    func omittedInverseBindMatricesDefaultToIdentity() throws {
        var fixture = SkeletalGLTFFixture()
        fixture.skins[0].removeValue(forKey: "inverseBindMatrices")
        fixture.nodes[1]["translation"] = [2, 3, 4]
        let result = try NativeGLTFLoader().load(data: fixture.data())
        #expect(result.skins[0].inverseBindMatrices == [.identity, .identity])
        #expect(result.nodes[1].transform.origin == Vector3(2, 3, 4))
    }

    @Test
    func staticModelsRemainCompatible() throws {
        var fixture = SkeletalGLTFFixture()
        fixture.nodes[0].removeValue(forKey: "skin")
        fixture.skins = []
        fixture.animations = []
        fixture.attributes.removeValue(forKey: "JOINTS_0")
        fixture.attributes.removeValue(forKey: "WEIGHTS_0")
        let result = try NativeGLTFLoader().load(data: fixture.data())
        #expect(result.skins.isEmpty)
        #expect(result.animations.isEmpty)
        #expect(result.meshes[0].primitives[0].skinning == nil)
    }

    @Test(arguments: ["TwoBoneRibbon", "TestHumanoid"])
    func importsActualBlenderGLB(name: String) async throws {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "glb", subdirectory: "Fixtures"))
        let result = try await NativeGLTFLoader().load(url: url)
        let skin = try #require(result.skins.first)
        #expect(skin.joints.count == (name == "TwoBoneRibbon" ? 2 : 11))
        #expect(skin.inverseBindMatrices.count == skin.joints.count)
        #expect(!result.meshes.isEmpty)
        #expect(result.meshes.allSatisfy { $0.primitives.allSatisfy { $0.skinning != nil } })
        let clips = Set(result.animations.compactMap(\.name))
        #expect(clips == (name == "TwoBoneRibbon" ? ["Bend"] : ["Idle", "Walk", "Run"]))
        #expect(result.animations.allSatisfy { $0.duration > 0 && !$0.channels.isEmpty })
        let meshNode = try #require(result.nodes.first { $0.meshIndex != nil })
        #expect(meshNode.skinIndex == 0)
    }

    @Test(arguments: ["joint", "duplicateJoint", "skin", "missingMesh", "root", "bindCount", "bindType", "nodeCycle", "nodeTRS"])
    func rejectsInvalidSkeletonReferences(kind: String) throws {
        var fixture = SkeletalGLTFFixture()
        switch kind {
        case "joint": fixture.skins[0]["joints"] = [1, 9]
        case "duplicateJoint": fixture.skins[0]["joints"] = [1, 1]
        case "skin": fixture.nodes[0]["skin"] = 3
        case "missingMesh": fixture.nodes[0].removeValue(forKey: "mesh")
        case "root": fixture.skins[0]["skeleton"] = 2
        case "bindCount": fixture.accessors[fixture.bindAccessor]["count"] = 1
        case "bindType": fixture.accessors[fixture.bindAccessor]["type"] = "VEC4"
        case "nodeCycle": fixture.nodes[2]["children"] = [1]
        case "nodeTRS": fixture.nodes[2]["translation"] = [1, 2]
        default: Issue.record("Unknown case")
        }
        let data = try fixture.data()
        #expect(throws: NativeGLTFLoader.GLTFError.self) { try NativeGLTFLoader().load(data: data) }
    }

    @Test(arguments: ["sampler", "node", "count", "timeOrder", "negativeTime", "timeType", "outputType", "matrixTarget", "duplicateTarget", "rotation"])
    func rejectsInvalidAnimationChannels(kind: String) throws {
        var fixture = SkeletalGLTFFixture()
        switch kind {
        case "sampler": fixture.channels[0]["sampler"] = 9
        case "node": fixture.channels[0]["target"] = ["node": 9, "path": "translation"]
        case "count": fixture.accessors[fixture.outputAccessor]["count"] = 1
        case "timeOrder": fixture.replaceTimeValues([1, 0])
        case "negativeTime": fixture.replaceTimeValues([-1, 1])
        case "timeType": fixture.accessors[fixture.timeAccessor]["type"] = "VEC2"
        case "outputType": fixture.accessors[fixture.outputAccessor]["componentType"] = 5123
        case "matrixTarget":
            fixture.nodes[2].removeValue(forKey: "translation")
            fixture.nodes[2]["matrix"] = SkeletalGLTFFixture.identity
        case "duplicateTarget": fixture.channels.append(fixture.channels[0])
        case "rotation": fixture.channels[0]["target"] = ["node": 2, "path": "rotation"]
        default: Issue.record("Unknown case")
        }
        let data = try fixture.data()
        #expect(throws: NativeGLTFLoader.GLTFError.self) { try NativeGLTFLoader().load(data: data) }
    }

    @Test(arguments: ["missingWeights", "floatJoints", "normalizedJoints", "unnormalizedWeights", "vertexCount", "jointRange", "zeroWeights", "extraSet"])
    func rejectsInvalidVertexInfluences(kind: String) throws {
        var fixture = SkeletalGLTFFixture()
        switch kind {
        case "missingWeights": fixture.attributes.removeValue(forKey: "WEIGHTS_0")
        case "floatJoints": fixture.accessors[fixture.jointAccessor]["componentType"] = 5126
        case "normalizedJoints": fixture.accessors[fixture.jointAccessor]["normalized"] = true
        case "unnormalizedWeights": fixture.accessors[fixture.weightAccessor]["normalized"] = false
        case "vertexCount": fixture.accessors[fixture.weightAccessor]["count"] = 2
        case "jointRange": fixture.buffer[fixture.jointOffset] = 2
        case "zeroWeights": fixture.buffer.replaceSubrange(fixture.weightOffset..<fixture.weightOffset + 4, with: [0, 0, 0, 0])
        case "extraSet": fixture.attributes["JOINTS_1"] = fixture.jointAccessor
        default: Issue.record("Unknown case")
        }
        let data = try fixture.data()
        #expect(throws: NativeGLTFLoader.GLTFError.self) { try NativeGLTFLoader().load(data: data) }
    }

    @Test
    func unsupportedMorphAnimationFailsExplicitly() throws {
        var fixture = SkeletalGLTFFixture()
        fixture.channels[0]["target"] = ["node": 2, "path": "weights"]
        let data = try fixture.data()
        #expect(throws: NativeGLTFLoader.GLTFError.unsupportedAnimationPath("weights")) { try NativeGLTFLoader().load(data: data) }
    }

    @Test
    func importsGLBThroughTheSamePath() throws {
        let fixture = SkeletalGLTFFixture()
        let result = try NativeGLTFLoader().load(data: fixture.glb())
        #expect(result.skins[0].joints == [1, 2])
        #expect(result.animations[0].samplers[0].times == [0, 1])
    }
}

private struct SkeletalGLTFFixture {
    static let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    var buffer = Data()
    var views: [[String: Any]] = []
    var accessors: [[String: Any]] = []
    var nodes: [[String: Any]] = [["mesh": 0, "skin": 0], ["name": "Root", "children": [2]], ["name": "Tip", "translation": [0, 1, 0]]]
    var skins: [[String: Any]] = []
    var animations: [[String: Any]] = [["name": "Move"]]
    var channels: [[String: Any]] = [["sampler": 0, "target": ["node": 2, "path": "translation"]]]
    var attributes: [String: Int] = [:]
    var bindAccessor = 0
    var jointAccessor = 0
    var weightAccessor = 0
    var timeAccessor = 0
    var outputAccessor = 0
    var jointOffset = 0
    var weightOffset = 0
    var timeOffset = 0
    var interpolation: String?

    init(jointType: Int = 5121, interpolation: String = "LINEAR") {
        self.interpolation = interpolation
        attributes["POSITION"] = addFloats([0, 0, 0, 1, 0, 0, 0, 1, 0], type: "VEC3", count: 3)
        jointOffset = buffer.count
        let joints: [UInt16] = [0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0]
        var jointBytes = Data()
        for value in joints {
            jointBytes.append(UInt8(truncatingIfNeeded: value))
            if jointType == 5123 { jointBytes.append(UInt8(truncatingIfNeeded: value >> 8)) }
        }
        jointAccessor = add(jointBytes, type: "VEC4", count: 3, componentType: jointType)
        attributes["JOINTS_0"] = jointAccessor
        weightOffset = buffer.count
        weightAccessor = add(Data([255, 0, 0, 0, 128, 127, 0, 0, 255, 0, 0, 0]), type: "VEC4", count: 3, componentType: 5121)
        accessors[weightAccessor]["normalized"] = true
        attributes["WEIGHTS_0"] = weightAccessor
        var inverseTip = Self.identity
        inverseTip[13] = -1
        bindAccessor = addFloats(Self.identity + inverseTip, type: "MAT4", count: 2)
        skins = [["name": "TwoBones", "joints": [1, 2], "skeleton": 1, "inverseBindMatrices": bindAccessor]]
        timeOffset = buffer.count
        timeAccessor = addFloats([0, 1], type: "SCALAR", count: 2)
        let outputs: [Float] = interpolation == "CUBICSPLINE" ? [2, 0, 0, 0, 1, 0, 3, 0, 0, 4, 0, 0, 0, 2, 0, 5, 0, 0] : [0, 1, 0, 0, 2, 0]
        outputAccessor = addFloats(outputs, type: "VEC3", count: outputs.count / 3)
    }

    mutating func setOutput(_ values: [Float], type: String) {
        outputAccessor = addFloats(values, type: type, count: values.count / (type == "VEC4" ? 4 : 3))
    }

    mutating func setWeights(_ values: [Float]) {
        weightAccessor = addFloats(values, type: "VEC4", count: values.count / 4)
        attributes["WEIGHTS_0"] = weightAccessor
    }

    mutating func replaceTimeValues(_ values: [Float]) {
        buffer.replaceSubrange(timeOffset..<timeOffset + 8, with: Self.floatData(values))
    }

    func document(embedBuffer: Bool) -> [String: Any] {
        var bufferInfo: [String: Any] = ["byteLength": buffer.count]
        if embedBuffer { bufferInfo["uri"] = "data:application/octet-stream;base64,\(buffer.base64EncodedString())" }
        var clips = animations
        if !clips.isEmpty {
            var sampler: [String: Any] = ["input": timeAccessor, "output": outputAccessor]
            if let interpolation { sampler["interpolation"] = interpolation }
            clips[0]["samplers"] = [sampler]
            clips[0]["channels"] = channels
        }
        var result: [String: Any] = [:]
        result["asset"] = ["version": "2.0"]
        result["buffers"] = [bufferInfo]
        result["bufferViews"] = views
        result["accessors"] = accessors
        let primitive: [String: Any] = ["attributes": attributes]
        result["meshes"] = [["primitives": [primitive]]]
        result["nodes"] = nodes
        result["skins"] = skins
        result["animations"] = clips
        result["scenes"] = [["nodes": [0, 1]]]
        result["scene"] = 0
        return result
    }

    func data() throws -> Data { try JSONSerialization.data(withJSONObject: document(embedBuffer: true)) }

    func glb() throws -> Data {
        var json = try JSONSerialization.data(withJSONObject: document(embedBuffer: false))
        while !json.count.isMultiple(of: 4) { json.append(32) }
        var bin = buffer
        while !bin.count.isMultiple(of: 4) { bin.append(0) }
        var data = Data("glTF".utf8)
        let totalLength: Int = json.count + bin.count + 28
        Self.append(2, to: &data)
        Self.append(UInt32(totalLength), to: &data)
        Self.append(UInt32(json.count), to: &data)
        Self.append(0x4E4F534A, to: &data)
        data.append(json)
        Self.append(UInt32(bin.count), to: &data)
        Self.append(0x004E4942, to: &data)
        data.append(bin)
        return data
    }

    private mutating func addFloats(_ values: [Float], type: String, count: Int) -> Int {
        add(Self.floatData(values), type: type, count: count, componentType: 5126)
    }

    private mutating func add(_ data: Data, type: String, count: Int, componentType: Int) -> Int {
        while !buffer.count.isMultiple(of: 4) { buffer.append(0) }
        views.append(["buffer": 0, "byteOffset": buffer.count, "byteLength": data.count])
        buffer.append(data)
        accessors.append(["bufferView": views.count - 1, "componentType": componentType, "count": count, "type": type])
        return accessors.count - 1
    }

    private static func floatData(_ values: [Float]) -> Data {
        var data = Data()
        for value in values { append(value.bitPattern, to: &data) }
        return data
    }

    private static func append(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }
}
