import AdaUtils
import Foundation
import Testing
@testable import AdaText

struct TextOutlineAttributeTests {

    @Test
    func outlineAttributes_haveRenderableDefaultsAndCanBeCustomized() {
        var attributes = TextAttributeContainer()

        #expect(attributes.outlineColor == Color(red: 0, green: 0, blue: 0, alpha: 0))
        #expect(attributes.outlineWidth == 1)

        attributes.outlineColor = .white
        attributes.outlineWidth = 2.5

        let text = AttributedText("Outlined", attributes: attributes)
        let resolved = text.attributes(at: text.startIndex)

        #expect(resolved.outlineColor == .white)
        #expect(resolved.outlineWidth == 2.5)
    }

    @Test
    func outlineAttributes_areAppliedThroughDynamicAttributedTextMembers() {
        var text = AttributedText("Title")

        text.outlineColor = .white
        text.outlineWidth = 3

        for index in text.text.indices {
            let attributes = text.attributes(at: index)
            #expect(attributes.outlineColor == .white)
            #expect(attributes.outlineWidth == 3)
        }
    }

    @Test
    func textShader_usesExplicitVaryingLocationsForMetalCompatibility() throws {
        let shaderURL = Bundle.module.url(forResource: "text", withExtension: "glsl", subdirectory: "Assets")
        let shader = try #require(shaderURL.map { try String(contentsOf: $0, encoding: .utf8) })

        #expect(shader.contains("layout (location = 0) out vec4 v_ForegroundColor;"))
        #expect(shader.contains("layout (location = 1) out vec4 v_OutlineColor;"))
        #expect(shader.contains("layout (location = 2) out float v_OutlineWidth;"))
        #expect(shader.contains("layout (location = 3) out vec2 v_TexCoordinate;"))
        #expect(shader.contains("layout (location = 0) in vec4 v_ForegroundColor;"))
        #expect(shader.contains("layout (location = 1) in vec4 v_OutlineColor;"))
        #expect(shader.contains("layout (location = 2) in float v_OutlineWidth;"))
        #expect(shader.contains("layout (location = 3) in vec2 v_TexCoordinate;"))
    }

    @Test
    func fontResource_canLoadPrebuiltAtlasWithoutSourceFont() throws {
        let emSize = 12.0
        #expect(FontResource.prebuildSystemAtlas(weight: .regular, emFontScale: emSize))

        let sourceFileName = FontResource.prebuiltAtlasFileName(
            fontFileName: "OpenSans-Regular.ttf",
            emFontScale: emSize
        )
        let fakeFileName = FontResource.prebuiltAtlasFileName(
            fontFileName: "PrebuiltOnly.ttf",
            emFontScale: emSize
        )
        let cacheDirectory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("AdaEngine")
        .appendingPathComponent("FontGeneratedAtlases")
        let sourceFile = cacheDirectory.appendingPathComponent(sourceFileName)
        #expect(FileManager.default.fileExists(atPath: sourceFile.path))

        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bundle")
        let prebuiltSubdirectory = "Resources/FontGeneratedAtlases"
        let prebuiltDirectory = bundleURL.appendingPathComponent(prebuiltSubdirectory)
        try FileManager.default.createDirectory(at: prebuiltDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: sourceFile,
            to: prebuiltDirectory.appendingPathComponent(fakeFileName)
        )
        defer {
            try? FileManager.default.removeItem(at: bundleURL)
        }

        let bundle = try #require(Bundle(url: bundleURL))
        FontResource.registerPrebuiltAtlasBundle(bundle, subdirectory: prebuiltSubdirectory)

        let fakeFontPath = bundleURL.appendingPathComponent("PrebuiltOnly.ttf")
        #expect(FontResource.hasPrebuiltAtlas(fontPath: fakeFontPath, emFontScale: emSize))
    }
}
