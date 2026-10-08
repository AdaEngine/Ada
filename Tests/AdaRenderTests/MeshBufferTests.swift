//
//  MeshBufferTests.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 10.12.2025.
//

import Testing
@_spi(Internal) @testable import AdaRender
import AdaUtils
import Math
#if canImport(Metal)
import Metal
#endif

@Suite
struct MeshBufferTests {

    // MARK: - Float Buffer Tests

    @Test func `float buffer stores and retrieves data correctly`() {
        let values: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0]
        let buffer = MeshBuffer<Float>(values)

        #expect(buffer.count == 5)
        #expect(buffer.elements == values)
    }

    @Test func `float buffer with indices stores data correctly`() {
        let values: [Float] = [1.0, 2.0, 3.0, 4.0]
        let indices: [UInt32] = [0, 1, 2, 2, 3, 0]
        let buffer = MeshBuffer<Float>(elements: values, indices: indices)

        #expect(buffer.count == 4)
        #expect(buffer.elements == values)
    }

    @Test func `float buffer from sequence stores data correctly`() {
        let sequence = (0..<5).map { Float($0) }
        let buffer = MeshBuffer<Float>(sequence)

        #expect(buffer.count == 5)
        #expect(buffer.elements == [0.0, 1.0, 2.0, 3.0, 4.0])
    }

    // MARK: - Integer Buffer Tests

    @Test func `int8 buffer stores and retrieves data correctly`() {
        let values: [Int8] = [1, 2, 3, -1, -128, 127]
        let buffer = MeshBuffer<Int8>(values)

        #expect(buffer.count == 6)
        #expect(buffer.elements == values)
    }

    @Test func `uint8 buffer stores and retrieves data correctly`() {
        let values: [UInt8] = [0, 1, 128, 255]
        let buffer = MeshBuffer<UInt8>(values)

        #expect(buffer.count == 4)
        #expect(buffer.elements == values)
    }

    @Test func `int16 buffer stores and retrieves data correctly`() {
        let values: [Int16] = [0, 1, -1, 32767, -32768]
        let buffer = MeshBuffer<Int16>(values)

        #expect(buffer.count == 5)
        #expect(buffer.elements == values)
    }

    @Test func `uint16 buffer stores and retrieves data correctly`() {
        let values: [UInt16] = [0, 1, 32768, 65535]
        let buffer = MeshBuffer<UInt16>(values)

        #expect(buffer.count == 4)
        #expect(buffer.elements == values)
    }

    @Test func `int32 buffer stores and retrieves data correctly`() {
        let values: [Int32] = [0, 1, -1, Int32.max, Int32.min]
        let buffer = MeshBuffer<Int32>(values)

        #expect(buffer.count == 5)
        #expect(buffer.elements == values)
    }

    @Test func `uint32 buffer stores and retrieves data correctly`() {
        let values: [UInt32] = [0, 1, UInt32.max / 2, UInt32.max]
        let buffer = MeshBuffer<UInt32>(values)

        #expect(buffer.count == 4)
        #expect(buffer.elements == values)
    }

    // MARK: - Vector Buffer Tests

    @Test func `vector2 buffer stores and retrieves data correctly`() {
        let values: [Vector2] = [
            Vector2(x: 0, y: 0),
            Vector2(x: 1, y: 2),
            Vector2(x: -1, y: -2),
            Vector2(x: 0.5, y: 0.25)
        ]
        let buffer = MeshBuffer<Vector2>(values)

        #expect(buffer.count == 4)
        #expect(buffer.elements == values)
    }

    @Test func `vector3 buffer stores and retrieves data correctly`() {
        let values: [Vector3] = [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 1, y: 2, z: 3),
            Vector3(x: -1, y: -2, z: -3),
            Vector3(x: 0.5, y: 0.25, z: 0.125)
        ]
        let buffer = MeshBuffer<Vector3>(values)

        #expect(buffer.count == 4)
        #expect(buffer.elements == values)
    }

    @Test func `vector4 buffer stores and retrieves data correctly`() {
        let values: [Vector4] = [
            Vector4(x: 0, y: 0, z: 0, w: 0),
            Vector4(x: 1, y: 2, z: 3, w: 4),
            Vector4(x: -1, y: -2, z: -3, w: -4),
            Vector4(x: 0.5, y: 0.25, z: 0.125, w: 0.0625)
        ]
        let buffer = MeshBuffer<Vector4>(values)

        #expect(buffer.count == 4)
        #expect(buffer.elements == values)
    }

    @Test func `vector3 buffer with indices stores data correctly`() {
        let values: [Vector3] = [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 1, y: 0, z: 0),
            Vector3(x: 0.5, y: 1, z: 0)
        ]
        let indices: [UInt32] = [0, 1, 2]
        let buffer = MeshBuffer<Vector3>(elements: values, indecies: indices)

        #expect(buffer.count == 3)
        #expect(buffer.elements == values)
    }

    @Test func `mesh vertex descriptor keeps standard shader locations for sparse attributes`() {
        var mesh = MeshDescriptor(name: "colored mesh")
        mesh.positions = MeshBuffer<Vector3>([
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 1, y: 0, z: 0),
        ])
        mesh.colors = MeshBuffer<Color>([
            .red,
            .blue,
        ])

        let attributes = Array(mesh.getMeshVertexBufferDescriptor().attributes)

        #expect(attributes.count == 4)
        #expect(attributes[0].name == MeshDescriptor.positions.id.name)
        #expect(attributes[0].format == .vector3)
        #expect(attributes[0].offset == 0)
        #expect(attributes[1].format == .invalid)
        #expect(attributes[2].format == .invalid)
        #expect(attributes[3].name == MeshDescriptor.colors.id.name)
        #expect(attributes[3].format == .vector4)
        #expect(attributes[3].offset == MemoryLayout<Vector3>.stride)
    }

    @Test func `mesh vertex descriptor keeps tangent at shader location four`() {
        var mesh = MeshDescriptor(name: "tangent mesh")
        mesh.positions = MeshBuffer<Vector3>([.zero])
        mesh.normals = MeshBuffer<Vector3>([.up])
        mesh.tangents = MeshBuffer<Vector4>([[1, 0, 0, 1]])

        let attributes = Array(mesh.getMeshVertexBufferDescriptor().attributes)

        #expect(attributes.count == 5)
        #expect(attributes[2].format == .invalid)
        #expect(attributes[3].format == .invalid)
        #expect(attributes[4].name == MeshDescriptor.tangents.id.name)
        #expect(attributes[4].format == .vector4)
    }

    @Test func `shader reflection keeps internal uniforms in descriptor layout only`() throws {
        let source = try ShaderSource(source: """
        #version 450 core
        #pragma stage : vert

        layout (binding = 2) uniform AE_GlobalView {
            mat4 u_ViewProjection;
        };

        layout (binding = 3) uniform AE_Mesh2dUniform {
            mat4 u_MeshModel;
        };

        [[main]]
        void test_vertex()
        {
            gl_Position = u_ViewProjection * u_MeshModel * vec4(0.0, 0.0, 0.0, 1.0);
        }
        """)
        let compiler = ShaderCompiler(shaderSource: source)
        let spirv = try compiler.compileSpirvBin(for: .vertex, ignoreCache: true)
        let reflection = try SpirvCompiler(
            spriv: spirv.data,
            stage: .vertex,
            deviceLang: .glsl
        ).reflection()

        let descriptorSet = try #require(reflection.descriptorSets.first)
        #expect(descriptorSet.uniformsBuffers.keys.contains(2))
        #expect(descriptorSet.uniformsBuffers.keys.contains(3))
        #expect(reflection.shaderBuffers["AE_GlobalView"] == nil)
        #expect(reflection.shaderBuffers["AE_Mesh2dUniform"] == nil)
    }

    @Test func `shader reflection grows descriptor sets for nonzero set resources`() throws {
        let source = try ShaderSource(source: """
        #version 450 core
        #pragma stage : frag

        layout (location = 0) out vec4 color;
        layout (set = 1, binding = 0) uniform texture2D customTexture;
        layout (set = 1, binding = 1) uniform sampler customSampler;

        [[main]]
        void test_fragment()
        {
            color = texture(sampler2D(customTexture, customSampler), vec2(0.5));
        }
        """)
        let compiler = ShaderCompiler(shaderSource: source)
        let spirv = try compiler.compileSpirvBin(for: .fragment, ignoreCache: true)
        let reflection = try SpirvCompiler(
            spriv: spirv.data,
            stage: .fragment,
            deviceLang: .glsl
        ).reflection()

        #expect(reflection.descriptorSets.count == 2)
        #expect(reflection.descriptorSets[1].sampledImages.keys.contains(0))
        #expect(reflection.descriptorSets[1].samplers.keys.contains(1))
    }

    #if canImport(Metal)
    @Test func `mesh2d positions and colors pipeline compiles on Metal`() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return
        }

        var mesh = MeshDescriptor(name: "colored mesh")
        mesh.positions = MeshBuffer<Vector3>([
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 1, y: 0, z: 0),
        ])
        mesh.colors = MeshBuffer<Color>([
            .red,
            .blue,
        ])

        let shaderURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/AdaRender/Assets/Shaders/mesh2d/mesh2d.glsl")
        let shaderSource = try ShaderSource(from: shaderURL)
        let compiler = ShaderCompiler(shaderSource: shaderSource)
        for stage in [ShaderStage.vertex, .fragment] {
            compiler.setMacro("VERTEX_POSITIONS", value: "1", for: stage)
            compiler.setMacro("VERTEX_COLORS", value: "1", for: stage)
        }

        let vertexShader = try Self.makeMetalShader(stage: .vertex, compiler: compiler, device: device)
        let fragmentShader = try Self.makeMetalShader(stage: .fragment, compiler: compiler, device: device)

        let descriptor = RenderPipelineDescriptor(
            vertex: vertexShader,
            fragment: fragmentShader,
            vertexDescriptor: mesh.getMeshVertexBufferDescriptor(),
            colorAttachments: [
                RenderPipelineColorAttachmentDescriptor(format: .bgra8),
            ]
        )

        _ = try MetalRenderPipeline(descriptor: descriptor, device: device)
    }

    private static func makeMetalShader(
        stage: ShaderStage,
        compiler: ShaderCompiler,
        device: MTLDevice
    ) throws -> Shader {
        let spirv = try compiler.compileSpirvBin(for: stage, ignoreCache: true)
        let compiled = try SpirvCompiler(
            spriv: spirv.data,
            stage: stage,
            deviceLang: .msl
        ).compile()
        let entryPoint = try #require(compiled.entryPoints.first?.name)
        let shader = Shader(
            source: compiled.source,
            entryPoint: entryPoint,
            stage: stage,
            reflectionData: compiled.reflection
        )
        shader.compiledShader = try MetalShader(shader: shader, device: device)
        return shader
    }
    #endif

    // MARK: - Iterator Tests

    @Test func `buffer iterator returns all elements`() {
        let values: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0]
        let buffer = MeshBuffer<Float>(values)

        var iteratedValues: [Float] = []
        for value in buffer {
            iteratedValues.append(value)
        }

        #expect(iteratedValues == values)
    }

    @Test func `vector2 buffer iterator returns all elements`() {
        let values: [Vector2] = [
            Vector2(x: 1, y: 2),
            Vector2(x: 3, y: 4),
            Vector2(x: 5, y: 6)
        ]
        let buffer = MeshBuffer<Vector2>(values)

        var iteratedValues: [Vector2] = []
        for value in buffer {
            iteratedValues.append(value)
        }

        #expect(iteratedValues == values)
    }

    // MARK: - ForEach with Multiple Elements Tests

    @Test func `forEach with pairs iterates correctly`() {
        let values: [Float] = [1.0, 2.0, 3.0, 4.0]
        let buffer = MeshBuffer<Float>(values)

        var pairs: [(Float, Float)] = []
        buffer.forEach { a, b in
            pairs.append((a, b))
        }

        #expect(pairs.count == 2)
        #expect(pairs[0].0 == 1.0)
        #expect(pairs[0].1 == 2.0)
        #expect(pairs[1].0 == 3.0)
        #expect(pairs[1].1 == 4.0)
    }

    @Test func `forEach with triples iterates correctly`() {
        let values: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
        let buffer = MeshBuffer<Float>(values)

        var triples: [(Float, Float, Float)] = []
        buffer.forEach { a, b, c in
            triples.append((a, b, c))
        }

        #expect(triples.count == 2)
        #expect(triples[0] == (1.0, 2.0, 3.0))
        #expect(triples[1] == (4.0, 5.0, 6.0))
    }

    @Test func `forEach with quadruples iterates correctly`() {
        let values: [Float] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]
        let buffer = MeshBuffer<Float>(values)

        var quadruples: [(Float, Float, Float, Float)] = []
        buffer.forEach { a, b, c, d in
            quadruples.append((a, b, c, d))
        }

        #expect(quadruples.count == 2)
        #expect(quadruples[0] == (1.0, 2.0, 3.0, 4.0))
        #expect(quadruples[1] == (5.0, 6.0, 7.0, 8.0))
    }

    // MARK: - ExpressibleByArrayLiteral Tests

    @Test func `array literal creates float buffer correctly`() {
        let buffer: MeshBuffer<Float> = [1.0, 2.0, 3.0]

        #expect(buffer.count == 3)
        #expect(buffer.elements == [1.0, 2.0, 3.0])
    }

    @Test func `array literal creates uint32 buffer correctly`() {
        let buffer: MeshBuffer<UInt32> = [0, 1, 2, 3]

        #expect(buffer.count == 4)
        #expect(buffer.elements == [0, 1, 2, 3])
    }

    @Test func `array literal creates vector3 buffer correctly`() {
        let v1 = Vector3(x: 1, y: 2, z: 3)
        let v2 = Vector3(x: 4, y: 5, z: 6)
        let buffer: MeshBuffer<Vector3> = [v1, v2]

        #expect(buffer.count == 2)
        #expect(buffer.elements == [v1, v2])
    }

    // MARK: - Equatable Tests

    @Test func `equal buffers compare correctly`() {
        let values: [Float] = [1.0, 2.0, 3.0]
        let buffer1 = MeshBuffer<Float>(values)
        let buffer2 = MeshBuffer<Float>(values)

        #expect(buffer1 == buffer2)
    }

    @Test func `different buffers compare correctly`() {
        let buffer1 = MeshBuffer<Float>([1.0, 2.0, 3.0])
        let buffer2 = MeshBuffer<Float>([1.0, 2.0, 4.0])

        #expect(buffer1 != buffer2)
    }

    @Test func `buffers with different counts are not equal`() {
        let buffer1 = MeshBuffer<Float>([1.0, 2.0, 3.0])
        let buffer2 = MeshBuffer<Float>([1.0, 2.0])

        #expect(buffer1 != buffer2)
    }

    @Test func `vector buffers compare correctly`() {
        let values: [Vector3] = [
            Vector3(x: 1, y: 2, z: 3),
            Vector3(x: 4, y: 5, z: 6)
        ]
        let buffer1 = MeshBuffer<Vector3>(values)
        let buffer2 = MeshBuffer<Vector3>(values)

        #expect(buffer1 == buffer2)
    }

    // MARK: - Edge Cases

    @Test func `single element buffer works correctly`() {
        let buffer = MeshBuffer<Float>([42.0])

        #expect(buffer.count == 1)
        #expect(buffer.elements == [42.0])
    }

    @Test func `buffer preserves element order`() {
        let values: [Float] = [5.0, 4.0, 3.0, 2.0, 1.0]
        let buffer = MeshBuffer<Float>(values)

        #expect(buffer.elements == values)
        #expect(buffer.elements[0] == 5.0)
        #expect(buffer.elements[4] == 1.0)
    }

    @Test func `buffer handles special float values`() {
        let values: [Float] = [Float.infinity, -Float.infinity, 0.0, -0.0]
        let buffer = MeshBuffer<Float>(values)

        #expect(buffer.count == 4)
        let elements = buffer.elements
        #expect(elements[0] == Float.infinity)
        #expect(elements[1] == -Float.infinity)
        #expect(elements[2] == 0.0)
        #expect(elements[3] == -0.0)
    }

    @Test func `buffer handles very small float values`() {
        let values: [Float] = [Float.leastNormalMagnitude, Float.leastNonzeroMagnitude]
        let buffer = MeshBuffer<Float>(values)

        #expect(buffer.count == 2)
        #expect(buffer.elements == values)
    }

    // MARK: - Buffer with Indices Tests

    @Test func `buffer with indices stores vertices correctly`() {
        let vertices: [Vector3] = [
            Vector3(x: 0, y: 0, z: 0),
            Vector3(x: 1, y: 0, z: 0),
            Vector3(x: 0.5, y: 1, z: 0),
            Vector3(x: 1.5, y: 1, z: 0)
        ]
        let indices: [UInt32] = [0, 1, 2, 1, 3, 2] // Two triangles sharing an edge
        let buffer = MeshBuffer<Vector3>(elements: vertices, indecies: indices)

        #expect(buffer.count == 4)
        #expect(buffer.elements == vertices)
    }

    @Test func `buffer without indices stores data correctly`() {
        let values: [Float] = [1.0, 2.0, 3.0]
        let buffer = MeshBuffer<Float>(values)

        #expect(buffer.count == 3)
        #expect(buffer.elements == values)
    }

    // MARK: - Memory Layout Tests

    @Test func `float buffer has correct memory representation`() {
        let values: [Float] = [1.0, 2.0, 3.0]
        let buffer = MeshBuffer<Float>(values)

        // Verify that the buffer count matches the input array count
        #expect(buffer.count == values.count)

        // Verify each element can be retrieved correctly
        let elements = buffer.elements
        for (index, value) in values.enumerated() {
            #expect(elements[index] == value)
        }
    }

    @Test func `vector3 buffer preserves component values`() {
        let original = Vector3(x: 1.5, y: 2.5, z: 3.5)
        let buffer = MeshBuffer<Vector3>([original])

        let retrieved = buffer.elements[0]
        #expect(retrieved.x == original.x)
        #expect(retrieved.y == original.y)
        #expect(retrieved.z == original.z)
    }

    @Test func `multiple vectors preserve all component values`() {
        let vectors: [Vector4] = [
            Vector4(x: 1, y: 2, z: 3, w: 4),
            Vector4(x: 5, y: 6, z: 7, w: 8),
            Vector4(x: 9, y: 10, z: 11, w: 12)
        ]
        let buffer = MeshBuffer<Vector4>(vectors)

        let elements = buffer.elements
        for (index, original) in vectors.enumerated() {
            #expect(elements[index].x == original.x)
            #expect(elements[index].y == original.y)
            #expect(elements[index].z == original.z)
            #expect(elements[index].w == original.w)
        }
    }

    @Test func `sphere UVs follow the ECEF longitude direction`() throws {
        try Self.setupHeadlessRenderEngineIfNeeded()

        let mesh = Mesh.generateSphere(
            radius: 1,
            segments: 4,
            rings: 2,
            renderDevice: unsafe RenderEngine.shared.renderDevice
        )
        let descriptor = try #require(mesh.models.first?.parts.first?.meshDescriptor)
        let textureCoordinates = try #require(descriptor.textureCoordinates?.elements)

        // Equator at +Z is 90 degrees west in the app's ECEF coordinate system.
        let positiveZVertex = 6
        #expect(abs(descriptor.positions.elements[positiveZVertex].z - 1) < 0.0001)
        #expect(textureCoordinates[positiveZVertex] == Vector2(0.25, 0.5))
    }

    private static func setupHeadlessRenderEngineIfNeeded() throws {
        guard unsafe RenderEngine.shared == nil else {
            return
        }

        unsafe RenderEngine.configurations.preferredBackend = .headless
        try RenderEngine.setupRenderEngine()
    }
}
