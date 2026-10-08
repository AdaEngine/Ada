//
//  FontConstantsBuilderTests.swift
//  AdaEngine
//

import Foundation
import Testing

@Suite("Font Constants Builder Tests")
struct FontConstantsBuilderTests {

    @Test("generates font constants from fonts config")
    func generatesFontConstants() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FontConstantsBuilderTests-\(UUID().uuidString)", isDirectory: true)
        let fontsDirectory = temporaryDirectory.appendingPathComponent("Assets/Fonts", isDirectory: true)
        try FileManager.default.createDirectory(at: fontsDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }

        try Data([0x00, 0x01]).write(to: fontsDirectory.appendingPathComponent("OpenSans-Regular.ttf"))
        try Data([0x00, 0x02]).write(to: fontsDirectory.appendingPathComponent("OpenSans-Bold.otf"))

        let config = temporaryDirectory.appendingPathComponent("App.fonts.json")
        try #"{"fontSetName":"App","inputDirectory":"Assets/Fonts","accessorTypeName":"AppFonts","emFontScale":52}"#
            .write(to: config, atomically: true, encoding: .utf8)

        let output = temporaryDirectory.appendingPathComponent("AppFonts+Generated.swift")
        let tool = try textureAtlasBuilderToolPath()
        let process = Process()
        process.executableURL = tool
        process.arguments = ["--config", config.path, "--output-swift", output.path]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)

        let generated = try String(contentsOf: output, encoding: .utf8)
        #expect(generated.contains("public enum AppFontsKey: String, CaseIterable, Sendable"))
        #expect(generated.contains("case OpenSans_Bold = \"OpenSans-Bold\""))
        #expect(generated.contains("case OpenSans_Regular = \"OpenSans-Regular\""))
        #expect(generated.contains("public struct AppFontsFontReference: Sendable"))
        #expect(generated.contains("public static let OpenSans_Regular = reference(.OpenSans_Regular)"))
        #expect(generated.contains("path: \"Assets/Fonts/OpenSans-Regular.ttf\""))
        #expect(generated.contains("defaultEmFontScale: 52.0"))
        #expect(generated.contains("resolvedPath += \"#emSize=\\(resolvedScale)\""))
    }
}

private func textureAtlasBuilderToolPath() throws -> URL {
    let rootURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    #if os(Windows)
    let executableName = "TextureAtlasBuilderTool.exe"
    #else
    let executableName = "TextureAtlasBuilderTool"
    #endif

    var candidates: [URL] = []
    if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
        candidates.append(executableDirectory.appendingPathComponent(executableName))
    }
    candidates.append(Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(executableName))
    candidates += [
        rootURL.appendingPathComponent(".build/debug").appendingPathComponent(executableName),
        rootURL.appendingPathComponent(".build/arm64-apple-macosx/debug").appendingPathComponent(executableName),
        rootURL.appendingPathComponent(".build/x86_64-apple-macosx/debug").appendingPathComponent(executableName),
        rootURL.appendingPathComponent(".build/x86_64-unknown-windows-msvc/debug").appendingPathComponent(executableName)
    ]

    for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
    }

    throw ToolLookupError.missingTextureAtlasBuilderTool(candidates.map(\.path).joined(separator: ", "))
}

private enum ToolLookupError: Error {
    case missingTextureAtlasBuilderTool(String)
}
