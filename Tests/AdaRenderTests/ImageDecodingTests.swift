import AdaAssets
import AdaRender
import Foundation
import Testing

@Suite("Image decoding", .serialized)
struct ImageDecodingTests {
    private static let pixels: [UInt8] = [
        255, 0, 0, 255, 0, 255, 0, 128,
        0, 0, 255, 64, 255, 255, 255, 0,
    ]

    @Test(arguments: ["pixels.png", "pixels.tga", "bottom.tga", "rle.tga", "palette.tga"])
    func decodesPixelsAndOrientation(fileName: String) throws {
        let data = try Data(contentsOf: fixture(fileName))
        let image = try Image.decode(from: data)
        #expect(image.width == 2)
        #expect(image.height == 2)
        #expect(image.format == .rgba8)
        #expect(image.data == Data(Self.pixels))
        #expect(try Image(contentsOf: fixture(fileName)).data == image.data)
    }

    @Test
    func decodesBMPPaddingAndBottomUpRows() throws {
        let image = try Image.decode(from: Data(contentsOf: fixture("pixels.bmp")))
        var pixels = Self.pixels
        for index in stride(from: 3, to: pixels.count, by: 4) {
            pixels[index] = 255
        }
        #expect(image.width == 2)
        #expect(image.height == 2)
        #expect(image.data == Data(pixels))
    }

    @Test(arguments: ["red.jpg", "repeated.tga"])
    func decodesOpaqueRed(fileName: String) throws {
        let image = try Image.decode(from: Data(contentsOf: fixture(fileName)))
        #expect(image.width == 2)
        #expect(image.height == 2)
        #expect(image.data.count == 16)
        for offset in stride(from: 0, to: image.data.count, by: 4) {
            #expect(image.data[offset] >= 250)
            #expect(image.data[offset + 1] <= 5)
            #expect(image.data[offset + 2] <= 5)
            #expect(image.data[offset + 3] == 255)
        }
    }

    @Test
    func supportsUppercaseExtensionsAndContentFallback() throws {
        let data = try Data(contentsOf: fixture("red.jpg"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).JPEG")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        #expect(try Image(contentsOf: url).width == 2)
        #expect(try Image.decode(from: data, fileExtension: "JPEG").data == Image.decode(from: data).data)
        #expect(try Image.decode(from: data, fileExtension: "png").width == 2)
    }

    @Test(arguments: ["pixels.png", "red.jpg", "pixels.bmp", "pixels.tga"])
    func loadsThroughAssetsManager(fileName: String) async throws {
        let url = try fixture(fileName)
        let expected = try Image(contentsOf: url)
        let handle = try await AssetsManager.load(Image.self, at: url.path)
        #expect(handle.isLoaded)
        #expect(handle.asset.width == 2)
        #expect(handle.asset.data == expected.data)
        #expect(handle.asset.assetMetaInfo?.assetName == fileName)
    }

    @Test
    func assetUsesProvidedBytesWithoutReadingItsURL() async throws {
        let decoder = try MemoryAssetDecoder(
            data: Data(contentsOf: fixture("pixels.tga")),
            fileExtension: "TGA"
        )
        let image = try await Image(from: decoder)
        #expect(image.data == Data(Self.pixels))
    }

    @Test(arguments: [Data(), Data([1, 2, 3]), Data([137, 80, 78, 71, 13, 10, 26, 10]), Data([255, 216, 255])])
    func rejectsInvalidOrTruncatedData(data: Data) {
        #expect(throws: (any Error).self) { try Image.decode(from: data) }
    }

    @Test
    func reportsUnsupportedFormat() {
        #expect(throws: ImageDecodingError.unsupportedFormat("webp")) {
            try Image.decode(from: Data([1, 2, 3]), fileExtension: "WEBP")
        }
    }

    @Test
    func registeredDecoderWorksForDataFilesAndAssets() async throws {
        Image.registerDecoder(TestImageDecoder(red: 42))
        let data = TestImageDecoder.signature
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).testimage")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        #expect(try Image.decode(from: data).data == Data([42, 0, 0, 255]))
        #expect(try Image(contentsOf: url).data == Data([42, 0, 0, 255]))
        let handle = try await AssetsManager.load(Image.self, at: url.path)
        #expect(handle.asset.data == Data([42, 0, 0, 255]))

        Image.registerDecoder(TestImageDecoder(red: 84))
        #expect(try Image.decode(from: data).data == Data([84, 0, 0, 255]))
        #expect(Image.extensions().filter { $0 == "testimage" }.count == 1)
    }

    @Test
    func concurrentRegistrationAndDecoding() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for red in UInt8(0)..<UInt8(32) {
                group.addTask {
                    Image.registerDecoder(TestImageDecoder(red: red))
                    let image = try Image.decode(from: TestImageDecoder.signature)
                    #expect(image.data.count == 4)
                    #expect(image.data[0] < 32)
                }
            }
            try await group.waitForAll()
        }
        #expect(Image.extensions().filter { $0 == "testimage" }.count == 1)
    }

    @Test
    func advertisesOnlyRegisteredFormats() {
        #expect(Set(["png", "jpg", "jpeg", "bmp", "tga"]).isSubset(of: Set(Image.extensions())))
        #expect(!Image.extensions().contains("gif"))
        #expect(!Image.extensions().contains("tiff"))
        #expect(!Image.extensions().contains("webp"))
    }

    private func fixture(_ fileName: String) throws -> URL {
        try #require(Bundle.module.url(forResource: fileName, withExtension: nil, subdirectory: "Images"))
    }
}

private struct TestImageDecoder: ImageDecoder {
    static let signature = Data("AdaEngine test image".utf8)
    let supportedExtensions = ["TESTIMAGE"]
    let red: UInt8

    func canDecode(_ data: Data) -> Bool {
        // Re-entering the registry verifies that callbacks execute outside its lock.
        _ = Image.extensions()
        return data == Self.signature
    }

    func decode(_ data: Data) throws -> Image {
        Image(width: 1, height: 1, data: Data([red, 0, 0, 255]))
    }
}

private struct MemoryAssetDecoder: AssetDecoder {
    let assetData: Data
    let assetMeta: AssetMeta
    var decoder: (any Decoder)? { nil }

    init(data: Data, fileExtension: String) throws {
        assetData = data
        let metadata = try JSONSerialization.data(withJSONObject: [
            "filePath": "file:///nonexistent-adaengine-image/\(UUID()).\(fileExtension)",
            "queryParams": [],
        ])
        assetMeta = try JSONDecoder().decode(AssetMeta.self, from: metadata)
    }

    func getOrLoadResource<A: Asset>(_ resourceType: A.Type, at path: String) throws -> AssetHandle<A> {
        throw AssetDecodingError.decodingProblem("Unexpected nested resource load.")
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        throw AssetDecodingError.decodingProblem("Unexpected text decoding.")
    }

    func decode<A: Asset>(_ type: A.Type, from decoder: any Decoder) async throws -> A {
        throw AssetDecodingError.decodingProblem("Unexpected nested asset decoding.")
    }
}
