import AdaAssets
import AdaCorePipelines
import AdaRender
import AdaSprite
import AdaWGSLCompiler
import Foundation
#if os(Windows)
import CRT
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Host-only export tool. It uses the renderer's actual templates and compiler;
/// the browser receives immutable WGSL and reflection, never a GLSL compiler.
@main
struct AdaShaderGraphBaker {
    static func main() {
        do { try bake() } catch {
            FileHandle.standardError.write(Data("Shader Graph export [WebGPU]: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func bake() throws {
        let args = CommandLine.arguments
        guard args.count == 2 else { throw BakeError.message("Usage: AdaShaderGraphBaker <GameAssets>") }
        let root = URL(fileURLWithPath: args[1]).standardizedFileURL
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.sorted { $0.path < $1.path }
        var graphs: [String: ShaderGraph] = [:]
        var inline: [ShaderGraph] = []
        var paths = Set<String>()
        var references = Set<String>()
        var textureMasks: Set<UInt32> = [0]
        for file in files {
            if file.pathExtension == "shadergraph" {
                do { graphs[resource(file, root: root)] = try AssetsManager.loadFreshSync(ShaderGraphAsset.self, at: file.path).graph } catch {
                    throw BakeError.message("\(resource(file, root: root)): \(error)")
                }
            }
            if ["ascn", "gltf", "glb"].contains(file.pathExtension), let object = try json(file) {
                try collect(object, graphs: &inline, paths: &paths, references: &references, textureMasks: &textureMasks)
            }
        }
        for reference in references where graphs[reference] == nil {
            throw BakeError.message("Missing packaged Shader Graph: \(reference)")
        }
        guard !graphs.isEmpty || !inline.isEmpty else {
            return
        }
        var fragments: [ShaderGraphArchive.Fragment] = []
        var seen = Set<String>()
        for (path, graph) in graphs.sorted(by: { $0.key < $1.key }) + inline.enumerated().map({ ("inline:\($0.offset)", $0.element) }) {
            do {
                let program = try graph.compileGLSL()
                for texture in program.textures {
                    guard let texturePath = texture.path else { continue }
                    let resolved: String
                    if texturePath.hasPrefix("@res://") { resolved = texturePath } else if !texturePath.hasPrefix("/"), path.hasPrefix("@res://"), let slash = path.lastIndex(of: "/") {
                        resolved = String(path[...slash]) + texturePath
                    } else { throw BakeError.message("Texture needs a packaged resource path: \(texturePath)") }
                    paths.insert(resolved)
                }
                let templates: [(String, [String])]
                if graph.target == .sprite {
                    templates = try [false, true].map { (try SpriteGraphPipeline.fragmentTemplate(instanced: $0), []) }
                } else {
                    var variants: [(String, [String])] = []
                    for mask in textureMasks.sorted() {
                        for layers: UInt32 in 0..<8 {
                            for morph: UInt32 in [0, 1 << 11] {
                                let features = ShaderGraphBakeVariants.features(textureMask: mask, layers: layers, morph: morph != 0)
                                variants.append((try ShaderGraph3DPipeline.fragmentTemplate(), features.enablingMacros))
                            }
                        }
                    }
                    for name in ["directional_shadow_3d", "motion_3d"] {
                        for morph in [false, true] {
                            variants.append((try ShaderGraph3DPipeline.fragmentTemplate(path: "Shaders/\(name).glsl"), morph ? ["ADA_MORPH"] : []))
                        }
                    }
                    templates = variants
                }
                for (template, macros) in templates {
                    let source = program.inserting(in: template)
                    let identity = source + "\u{0}" + macros.sorted().joined(separator: ",")
                    guard seen.insert(identity).inserted else { continue }
                    let shader = ShaderSource()
                    shader.setSource(source, for: .fragment)
                    let compiler = ShaderCompiler(shaderSource: shader)
                    compiler.setMacro("ADA_SHADER_GRAPH", value: "1", for: .fragment)
                    for macro in macros { compiler.setMacro(macro, value: "1", for: .fragment) }
                    let binary = try compiler.exportFragment()
                    let wgsl = try AdaWGSLCompiler.compile(spirv: binary.data, entryPoint: binary.entryPoint, stage: .fragment)
                    fragments.append(.init(
                        source: source,
                        defines: Dictionary(uniqueKeysWithValues: macros.map { ($0, "1") }),
                        entryPoint: binary.entryPoint,
                        wgsl: wgsl,
                        reflection: binary.reflection
                    ))
                }
            } catch { throw BakeError.message("Shader Graph \(path) [\(graph.target.rawValue)]: \(error)") }
        }
        for path in paths {
            guard path.hasPrefix("@res://") else { throw BakeError.message("Texture is outside packaged resources: \(path)") }
            let file = root.appendingPathComponent(String(path.dropFirst(7))).standardizedFileURL
            guard file.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: file.path) else {
                throw BakeError.message("Missing packaged Shader Graph texture: \(path)")
            }
        }
        let archive = ShaderGraphArchive(graphs: graphs, fragments: fragments, texturePaths: paths.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let output = root.appendingPathComponent("shaders.shadergraphlib")
        try encoder.encode(archive).write(to: output, options: .atomic)
        print(output.path)
    }

    private static func resource(_ file: URL, root: URL) -> String { "@res://" + file.path.dropFirst(root.path.count + 1) }

    private static func json(_ file: URL) throws -> Any? {
        var data = try Data(contentsOf: file)
        if file.pathExtension == "glb" {
            guard data.count >= 20 else { throw BakeError.message("Invalid GLB: \(file.path)") }
            let length = data[12..<16].enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
            guard length <= data.count - 20 else { throw BakeError.message("Invalid GLB JSON chunk: \(file.path)") }
            data = data.subdata(in: 20..<(20 + length))
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private static func collect(_ object: Any, graphs: inout [ShaderGraph], paths: inout Set<String>, references: inout Set<String>, textureMasks: inout Set<UInt32>) throws {
        if let dictionary = object as? [String: Any] {
            if let path = dictionary["path"] as? String, path.hasSuffix(".shadergraph") { references.insert(path) }
            if dictionary["target"] != nil, dictionary["nodes"] != nil {
                graphs.append(try JSONDecoder().decode(ShaderGraph.self, from: JSONSerialization.data(withJSONObject: dictionary)))
            }
            if let textures = dictionary["textures"] as? [String: String] { paths.formUnion(textures.values) }
            // glTF extension texture combinations used by imported PBR materials.
            if let extensions = dictionary["extensions"] as? [String: [String: Any]] {
                let fields = [
                    "clearcoatTexture", "clearcoatRoughnessTexture", "clearcoatNormalTexture", "sheenColorTexture",
                    "sheenRoughnessTexture", "anisotropyTexture", "specularTexture", "specularColorTexture"
                ]
                let keys = Set(extensions.values.flatMap(\.keys))
                let mask = fields.enumerated().reduce(UInt32(0)) { keys.contains($1.element) ? $0 | (1 << UInt32(3 + $1.offset)) : $0 }
                textureMasks.insert(mask)
            }
            for value in dictionary.values { try collect(value, graphs: &graphs, paths: &paths, references: &references, textureMasks: &textureMasks) }
        } else if let list = object as? [Any] {
            for value in list { try collect(value, graphs: &graphs, paths: &paths, references: &references, textureMasks: &textureMasks) }
        } else if let text = object as? String {
            if let data = Data(base64Encoded: text), let nested = try? JSONSerialization.jsonObject(with: data) {
                try collect(nested, graphs: &graphs, paths: &paths, references: &references, textureMasks: &textureMasks)
            }
        }
    }

    private enum BakeError: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            switch self {
            case .message(let message): message
            }
        }
    }
}
