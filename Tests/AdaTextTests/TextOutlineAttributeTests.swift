@testable import AdaRender
@testable import AdaText
import AdaUtils
import AdaWGSLCompiler
import Foundation
import SAGAShaderIR
import Testing

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
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let artifact = try ShaderModule.linkWESL(from: repository.appendingPathComponent("Sources/AdaText/Assets/text.wesl"))
        let stages = try WESLBackendCompiler.compile(artifact, to: .msl)
        let vertex = try #require(stages.first { $0.stage == "vertex" })
        let fragment = try #require(stages.first { $0.stage == "fragment" })
        guard case let .render(vertexLayout) = vertex.reflection, case let .render(fragmentLayout) = fragment.reflection else {
            Issue.record("Text vertex and fragment stages must reflect their varyings")
            return
        }
        #expect(vertexLayout.varyings.map(\.location) == [0, 1, 2, 3])
        #expect(vertexLayout.varyings.map(\.componentCount) == [4, 4, 1, 2])
        #expect(vertexLayout.varyings == fragmentLayout.varyings)
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
