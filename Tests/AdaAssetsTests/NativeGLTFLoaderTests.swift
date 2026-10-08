import AdaAssets
import Foundation
import Testing

@Suite
struct NativeGLTFLoaderTests {
    @Test
    func decodesSparseNormalizedInterleavedAndTypedIndices() throws {
        let result = try NativeGLTFLoader().load(data: makeGLTF())

        let firstPrimitive = try #require(result.meshes.first?.primitives.first)
        let positions = try #require(firstPrimitive.attributes[.position])
        #expect(positions.componentCount == 3)
        #expect(positions.values == [0, 0, 0, 1, 2, 3, 0, 0, 0])
        #expect(firstPrimitive.indices == [0, 1, 2])
        #expect(firstPrimitive.attributes[.custom("_TEMPERATURE")] != nil)

        let colors = try #require(firstPrimitive.attributes[.color(0)])
        #expect(colors.values[0] == 1)
        #expect(abs(colors.values[1] - Float(128) / 255) < 0.0001)
        #expect(colors.values[2] == 0)
        #expect(colors.values[3] == 1)

        let secondPrimitive = try #require(result.meshes.first?.primitives.dropFirst().first)
        #expect(secondPrimitive.attributes[.position]?.values == [0, 0, 0, 1, 2, 3])
        #expect(secondPrimitive.indices == nil)
        #expect(secondPrimitive.mode == .lineStrip)
    }

    @Test
    func decodesDataURIImage() throws {
        let result = try NativeGLTFLoader().load(data: makeGLTF())
        #expect(result.images.first?.data == Data([1, 2, 3]))
    }

    private func makeGLTF() throws -> Data {
        var buffer = Data([1, 0, 0, 0])
        appendFloat(1, to: &buffer)
        appendFloat(2, to: &buffer)
        appendFloat(3, to: &buffer)
        buffer.append(contentsOf: [255, 128, 0, 255])
        buffer.append(contentsOf: [0, 255, 0, 255])
        buffer.append(contentsOf: [0, 0, 255, 255])
        appendUInt16(0, to: &buffer)
        appendUInt16(1, to: &buffer)
        appendUInt16(2, to: &buffer)
        buffer.append(contentsOf: [0, 0])
        appendFloat(0, to: &buffer)
        appendFloat(0, to: &buffer)
        appendFloat(0, to: &buffer)
        buffer.append(contentsOf: [0, 0, 0, 0])
        appendFloat(1, to: &buffer)
        appendFloat(2, to: &buffer)
        appendFloat(3, to: &buffer)
        buffer.append(contentsOf: [0, 0, 0, 0])

        let document: [String: Any] = [
            "asset": ["version": "2.0"],
            "buffers": [[
                "byteLength": buffer.count,
                "uri": "data:application/octet-stream;base64,\(buffer.base64EncodedString())"
            ]],
            "bufferViews": [
                ["buffer": 0, "byteLength": 1],
                ["buffer": 0, "byteOffset": 4, "byteLength": 12],
                ["buffer": 0, "byteOffset": 16, "byteLength": 12],
                ["buffer": 0, "byteOffset": 28, "byteLength": 6],
                ["buffer": 0, "byteOffset": 36, "byteLength": 32, "byteStride": 16]
            ],
            "accessors": [
                [
                    "componentType": 5126,
                    "count": 3,
                    "type": "VEC3",
                    "sparse": [
                        "count": 1,
                        "indices": ["bufferView": 0, "componentType": 5121],
                        "values": ["bufferView": 1]
                    ]
                ],
                ["bufferView": 2, "componentType": 5121, "normalized": true, "count": 3, "type": "VEC4"],
                ["bufferView": 3, "componentType": 5123, "count": 3, "type": "SCALAR"],
                ["bufferView": 4, "componentType": 5126, "count": 2, "type": "VEC3"]
            ],
            "meshes": [[
                "primitives": [
                    ["attributes": ["POSITION": 0, "COLOR_0": 1, "_TEMPERATURE": 1], "indices": 2],
                    ["attributes": ["POSITION": 3], "mode": 3]
                ]
            ]],
            "images": [["uri": "data:application/octet-stream;base64,AQID"]]
        ]
        return try JSONSerialization.data(withJSONObject: document)
    }

    private func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private func appendFloat(_ value: Float, to data: inout Data) {
        let bits = value.bitPattern
        data.append(UInt8(truncatingIfNeeded: bits))
        data.append(UInt8(truncatingIfNeeded: bits >> 8))
        data.append(UInt8(truncatingIfNeeded: bits >> 16))
        data.append(UInt8(truncatingIfNeeded: bits >> 24))
    }
}
