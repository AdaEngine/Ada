//
//  ShaderCacheTests.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 11.12.2025.
//

@testable import AdaRender
import Foundation
import Testing

@Suite("Shader Cache Tests")
struct ShaderCacheTests {
    private let shaderSource = """
    #version 450 core
    #pragma stage : vert
    
    void main() {
        gl_Position = vec4(0.0, 0.0, 0.0, 1.0);
    }
    """
    
    private let modifiedShaderSource = """
    #version 450 core
    #pragma stage : vert
    
    void main() {
        gl_Position = vec4(1.0, 1.0, 1.0, 1.0);
    }
    """
    
    @Test func `if cached shader change we update shader`() async throws {
        // Given: Create a temporary shader file
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        
        let shaderFileURL = tempDirectory.appendingPathComponent("test_shader.glsl")
        try writeUTF8(shaderSource, to: shaderFileURL)
        
        // Create ShaderSource from the file
        let shader = try ShaderSource(from: shaderFileURL)
        let version = 1
        
        // When: First call to hasChanges (no cache exists)
        let firstCallChanges = ShaderCache.hasChanges(for: shader, version: version)
        
        // Then: Should return vertex stage as changed (first time = no cache)
        #expect(firstCallChanges.contains(.vertex))
        
        // When: Second call with the same source (cache exists)
        let secondCallChanges = ShaderCache.hasChanges(for: shader, version: version)
        
        // Then: Should return empty set (no changes)
        #expect(secondCallChanges.isEmpty)
        
        // When: Modify the shader source
        shader.setSource(modifiedShaderSource, for: .vertex)
        
        // Then: Call hasChanges - should detect the change
        let thirdCallChanges = ShaderCache.hasChanges(for: shader, version: version)
        
        // Then: Should return vertex stage as changed
        #expect(thirdCallChanges.contains(.vertex))
    }

    @Test func `shader source loads generated wgsl sidecar for stage`() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let shaderFileURL = tempDirectory.appendingPathComponent("test_shader.glsl")
        let wgslFileURL = tempDirectory.appendingPathComponent("test_shader.vert.wgsl")
        let wgslSource = "@vertex fn custom_vertex() -> @builtin(position) vec4f { return vec4f(); }"

        try writeUTF8(shaderSource, to: shaderFileURL)
        try writeUTF8(wgslSource, to: wgslFileURL)

        let shader = try ShaderSource(from: shaderFileURL)

        #expect(shader.getSourceFileURL(for: .vertex) == shaderFileURL)
        #expect(shader.getWGSLSource(for: .vertex) == wgslSource)
    }

    @Test func `shader cache manifest round trips through json`() throws {
        let manifest: ShaderCache.Cache = [
            "AdaEngine_AdaRender.bundle/Shaders/test.glsl": [
                .vertex: ShaderCache.ShaderCache(
                    sourceHashValue: 42,
                    headers: [],
                    version: 7
                )
            ]
        ]

        let encoded = try ShaderCache.encodeManifest(manifest)
        let decoded = try ShaderCache.decodeManifest(encoded)

        #expect(encoded.first == UInt8(ascii: "{"))
        #expect(decoded == manifest)
    }

    @Test func spirvCacheRoundTripsBytesAndSeparatesVersionsAndStages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("roundtrip.glsl")
        try writeUTF8(shaderSource, to: sourceURL)
        let source = try ShaderSource(from: sourceURL)
        let binary = SpirvBinary(stage: .vertex, data: Data([3, 2, 35, 7]), language: .glsl, entryPoint: "main", version: 71)
        let cacheDirectory = try ShaderCache.spirvCacheFile(for: sourceURL, stage: .vertex, version: 71).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }

        try ShaderCache.save(binary, source: source, stage: .vertex, version: 71)
        let loaded = try #require(ShaderCache.getCachedShader(for: source, stage: .vertex, version: 71, entryPoint: "main"))
        #expect(loaded.data == binary.data)
        #expect(loaded.stage == binary.stage)
        #expect(loaded.version == binary.version)
        #expect(loaded.entryPoint == binary.entryPoint)
        #expect(ShaderCache.getCachedShader(for: source, stage: .fragment, version: 71, entryPoint: "main") == nil)
        #expect(ShaderCache.getCachedShader(for: source, stage: .vertex, version: 72, entryPoint: "main") == nil)
    }

    @Test func `checking one shader stage does not hide changes in another stage`() throws {
        let source = """
        #version 450 core
        #pragma stage : vert
        void main() { gl_Position = vec4(0.0); }
        #pragma stage : frag
        layout(location = 0) out vec4 color;
        void main() { color = vec4(1.0); }
        """
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let shaderFileURL = tempDirectory.appendingPathComponent("two_stages.glsl")
        try writeUTF8(source, to: shaderFileURL)
        let shader = try ShaderSource(from: shaderFileURL)

        #expect(ShaderCache.hasChanges(for: shader, stage: .vertex, version: 1))
        #expect(ShaderCache.hasChanges(for: shader, stage: .fragment, version: 1))
        #expect(!ShaderCache.hasChanges(for: shader, stage: .vertex, version: 1))
        #expect(!ShaderCache.hasChanges(for: shader, stage: .fragment, version: 1))
    }
}

private func writeUTF8(_ string: String, to url: URL) throws {
    try Data(string.utf8).write(to: url, options: [])
}
