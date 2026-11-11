#if !os(WASI)
import Foundation
import SAGACompiler
import SAGAShaderIR

/// Emits native backend stages from a linked WESL module, retaining SAGA's authoritative reflection.
public enum WESLBackendCompiler {
    /// Native code formats supported by the shader migration. WGSL uses the host artifact directly.
    public enum Target: String, Sendable {
        case msl
        case spirv
    }

    /// Reflection belongs to the emitted entry point, including Metal's remapped binding indices.
    public enum Reflection: Sendable {
        case render(RenderStageArtifact)
        case compute(ComputeShaderArtifact)
    }

    public struct Stage: Sendable {
        public let sourceEntryPoint: String
        public let entryPoint: String
        public let stage: String
        public let reflection: Reflection
        public let data: Data

        public var fileExtension: String {
            switch stage {
            case "vertex": "vert"
            case "fragment": "frag"
            default: "comp"
            }
        }
    }

    /// Compiles each named stage independently; never assumes a multi-entry module is a compute shader.
    /// The returned code alone is not a runtime pipeline: consumers must apply its matching reflection.
    public static func compile(_ module: WESLHostCompiler.Artifact, to target: Target) throws -> [Stage] {
        guard !module.entryPoints.isEmpty else {
            throw ShaderFailure.unsupported("Native WESL output requires at least one entry point")
        }
        let compiler = IndependentShaderCompiler()
        let output: ShaderOutputFormat = target == .msl ? .msl : .spirv
        return try module.entryPoints.map { entry in
            let artifact: ShaderArtifact
            let reflection: Reflection
            let emittedEntryPoint: String
            switch entry.stage {
            case "vertex", "fragment":
                let compiled = try compiler.compileRenderStage(.wgsl(module.wgsl), entryPoint: entry.name, to: output)
                artifact = compiled.artifact
                reflection = .render(compiled)
                emittedEntryPoint = compiled.entryPoint
            case "compute":
                let compiled = try compiler.compileCompute(.wgsl(module.wgsl), entryPoint: entry.name, to: output)
                artifact = compiled.artifact
                reflection = .compute(compiled)
                emittedEntryPoint = compiled.entryPoint
            default:
                throw ShaderFailure.unsupported("WESL backend stage '\(entry.stage)'")
            }
            return Stage(
                sourceEntryPoint: entry.name,
                entryPoint: emittedEntryPoint,
                stage: entry.stage,
                reflection: reflection,
                data: encode(artifact)
            )
        }
    }

    /// Minimum sizes of the uniform buffers statically reachable by one WebGPU entry point.
    /// This intentionally does not infer material property names or member layouts from source text.
    public struct UniformBufferLayout: Sendable {
        public let group: UInt32
        public let binding: UInt32
        public let minimumByteSize: UInt64
    }

    /// Reads SAGA-validated IR layouts without generating replacement WGSL or allocating Metal slots.
    /// Only fixed uniform types are supported; unresolved layouts fail closed.
    public static func webGPUUniformBuffers(
        _ module: WESLHostCompiler.Artifact,
        entryPoint: WESLHostCompiler.EntryPoint
    ) throws -> [UniformBufferLayout] {
        let ir = try IndependentShaderCompiler().parseAndValidate(.wgsl(module.wgsl)).module
        guard let entry = ir.entryPoints.first(where: { $0.name == entryPoint.name && $0.stage.rawValue == entryPoint.stage }) else {
            throw ShaderFailure.unsupported("Unknown WESL uniform-reflection entry point '\(entryPoint.name)'")
        }
        var pending = [entry.function]
        var visited: Set<Int> = []
        var globals: Set<Int> = []
        // Match SAGA's static resource model: references in every reachable function's IR arena.
        while let handle = pending.popLast() {
            try Task.checkCancellation()
            guard visited.insert(handle.index).inserted else { continue }
            let function = try ir.functions.value(for: handle)
            for statement in function.statements.values {
                if case .call(let callee, _, _) = statement.kind { pending.append(callee) }
            }
            for expression in function.expressions.values {
                if case .globalVariable(let global) = expression.kind { globals.insert(global.index) }
            }
        }
        return try ir.globalVariables.values.enumerated().compactMap { index, global in
            guard globals.contains(index), global.space == .uniform, let binding = global.binding else {
                return nil
            }
            let type = try ir.types.value(for: global.type).kind
            let size: UInt64
            switch type {
            case .structure(_, let span): size = UInt64(span)
            case .scalar(let scalar): size = UInt64(scalar.width)
            case let .vector(count, scalar): size = UInt64(count.rawValue) * UInt64(scalar.width)
            case let .matrix(columns, rows, scalar):
                let columnStride = UInt64(rows == .two ? 2 : 4) * UInt64(scalar.width)
                size = UInt64(columns.rawValue) * columnStride
            case let .array(_, .constant(count), stride): size = UInt64(count) * UInt64(stride)
            default:
                throw ShaderFailure.unsupported("WESL uniform type requires a fixed runtime layout adapter")
            }
            guard size > 0, size <= 65_536 else {
                throw ShaderFailure.unsupported("WESL uniform byte size is outside the supported buffer range")
            }
            return UniformBufferLayout(group: binding.group, binding: binding.binding, minimumByteSize: size)
        }
    }

    private static func encode(_ artifact: ShaderArtifact) -> Data {
        switch artifact {
        case .text(_, let source):
            return Data(source.utf8)
        case .spirv(let words):
            var data = Data(capacity: words.count * MemoryLayout<UInt32>.size)
            for word in words {
                var littleEndian = word.littleEndian
                withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
            }
            return data
        }
    }
}
#endif
