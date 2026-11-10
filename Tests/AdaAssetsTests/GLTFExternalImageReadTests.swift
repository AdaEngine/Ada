import AdaAssets
import Foundation
import Testing

@Suite
struct GLTFExternalImageReadTests {
    @Test
    func externalImagesKeepTheirBytesAndOrder() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let payloads = (0 ..< 6).map { index in Data((0 ..< (index + 1) * 97).map { UInt8(truncatingIfNeeded: $0 &* (index + 3)) }) }
        for (index, payload) in payloads.enumerated() {
            try payload.write(to: directory.appendingPathComponent("image-\(index).png"))
        }
        // Two image entries share one file; each must still receive the complete bytes.
        let uris = (0 ..< 6).map { "image-\($0).png" } + ["image-2.png"]
        let result = try NativeGLTFLoader().load(data: Self.document(imageURIs: uris), baseURL: directory)
        #expect(result.images.map(\.data) == (payloads + [payloads[2]]).map { Optional($0) })
    }

    @Test
    func aMissingExternalImageStillFailsTheImport() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("present.png"))
        #expect(throws: (any Error).self) {
            try NativeGLTFLoader().load(data: Self.document(imageURIs: ["present.png", "missing.png"]), baseURL: directory)
        }
    }

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gltf-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func document(imageURIs: [String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "asset": ["version": "2.0"],
            "images": imageURIs.map { ["uri": $0] },
        ])
    }
}
