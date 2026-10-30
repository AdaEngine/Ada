import Foundation
import Testing

@testable import AdaRender

@Suite("Shader cache keys")
struct ShaderCacheKeyTests {
    @Test func stageParserAcceptsWindowsLineEndings() throws {
        let lf = "#version 450 core\n#pragma stage : vert\nvoid vertex() {}\n#version 450 core\n#pragma stage : frag\nvoid fragment() {}\n"
        for source in [lf, lf.replacingOccurrences(of:"\n",with:"\r\n")] {
            let split = try ShaderUtils.processGLSLShader(source:source)
            #expect(split.count == 2)
            #expect(split[.vertex]?.contains("void vertex()") == true)
            #expect(split[.fragment]?.contains("void fragment()") == true)
        }
    }
    @Test func editingAnIncludedFileChangesTheSourceHash() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShaderCacheKeyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let header = directory.appendingPathComponent("Shared.glsl")
        try "float shared() { return 1.0; }\n".write(to: header, atomically: true, encoding: .utf8)
        let searchPath: [ShaderSource.IncludeSearchPath] = [._module("Test", directory)]
        let shader = "#include <Test/Shared.glsl>\nvoid main() {}\n"

        let before = ShaderCache.hashValue(of: shader, includeSearchPaths: searchPath)
        #expect(before == ShaderCache.hashValue(of: shader, includeSearchPaths: searchPath), "The hash must be stable.")
        try "float shared() { return 2.0; }\n".write(to: header, atomically: true, encoding: .utf8)
        #expect(before != ShaderCache.hashValue(of: shader, includeSearchPaths: searchPath), "Editing the include must invalidate the cache.")
    }

    @Test func unresolvedIncludesFallBackToTheRawTextHash() {
        let shader = "#include <Missing/Nothing.glsl>\nvoid main() {}\n"
        #expect(ShaderCache.hashValue(of: shader, includeSearchPaths: []) == shader.uniqueHashValue)
    }

    @Test func sourcesWithoutIncludesKeepTheirOldHash() {
        let shader = "void main() {}\n"
        #expect(ShaderCache.hashValue(of: shader, includeSearchPaths: []) == shader.uniqueHashValue)
    }
}
