import Foundation

/// Reflection for generated WGSL sidecars used by browser startup.
enum WGSLReflection {
    static func parse(from source: String, stage: ShaderStage, entryPoint: String? = nil) -> ShaderReflectionData {
        var reflection = ShaderReflectionData()
        let usedNames = entryPoint.map { reachableNames(in: source, entryPoint: $0) }
        let stageFlag = ShaderStageFlags(shaderStage: stage)
        let pattern = #"@\s*group\s*\(\s*(\d+)u?\s*\)\s*@\s*binding\s*\(\s*(\d+)u?\s*\)\s*var(?:\s*<([^>]+)>)?\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([^;]+);"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return reflection
        }

        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        for match in matches {
            guard
                let groupRange = Range(match.range(at: 1), in: source),
                let bindingRange = Range(match.range(at: 2), in: source),
                let nameRange = Range(match.range(at: 4), in: source),
                let typeRange = Range(match.range(at: 5), in: source),
                let group = Int(source[groupRange]),
                let binding = Int(source[bindingRange])
            else {
                continue
            }

            let addressSpace: String
            if let addressRange = Range(match.range(at: 3), in: source) {
                addressSpace = String(source[addressRange]).trimmingCharacters(in: .whitespaces)
            } else {
                addressSpace = ""
            }
            let name = String(source[nameRange])
            if let usedNames, !usedNames.contains(name) {
                continue
            }
            let type = String(source[typeRange])

            reflection.ensureDescriptorSet(at: group)

            if addressSpace == "uniform" {
                let buffer = ShaderResource.ShaderBuffer(
                    name: name,
                    size: 0,
                    shaderStage: stageFlag,
                    binding: binding,
                    resourceAccess: .read,
                    members: [:]
                )
                reflection.shaderBuffers[name] = buffer
                reflection.descriptorSets[group].uniformsBuffers[binding] = buffer
            } else if type.hasPrefix("texture") {
                let resource = ShaderResource.ImageSampler(
                    name: name,
                    binding: binding,
                    textureType: textureType(for: type),
                    descriptorSet: group,
                    arraySize: 1,
                    shaderStage: stageFlag,
                    resourceAccess: .read,
                    isDepth: type.hasPrefix("texture_depth_") ? true : nil
                )
                reflection.resources[name] = resource
                reflection.descriptorSets[group].sampledImages[binding] = resource
            } else if type.hasPrefix("sampler") {
                let sampler = ShaderResource.Sampler(
                    name: name,
                    binding: binding,
                    shaderStage: stageFlag
                )
                reflection.samplers[name] = sampler
                reflection.descriptorSets[group].samplers[binding] = sampler
            }
        }

        return reflection
    }

    private static func textureType(for declaration: String) -> Texture.TextureType {
        let name = declaration.prefix { !$0.isWhitespace && $0 != "<" }
        return switch name {
        case "texture_1d": .texture1D
        case "texture_2d_array", "texture_depth_2d_array": .texture2DArray
        case "texture_3d": .texture3D
        case "texture_cube", "texture_depth_cube": .textureCube
        default: .texture2D
        }
    }

    /// Dawn's automatic layout includes only globals statically accessed by this entry point.
    /// Tint emits ordinary named functions; traverse their token references rather than
    /// treating declarations in dead helper functions as live bindings.
    private static func reachableNames(in source: String, entryPoint: String) -> Set<String> {
        let chars = Array(source)
        var tokens: [String] = []
        var cursor = 0
        while cursor < chars.count {
            if chars[cursor] == "/", cursor + 1 < chars.count, chars[cursor + 1] == "/" {
                while cursor < chars.count, chars[cursor] != "\n" { cursor += 1 }
            } else if chars[cursor] == "/", cursor + 1 < chars.count, chars[cursor + 1] == "*" {
                cursor += 2
                var depth = 1
                while cursor + 1 < chars.count, depth > 0 {
                    if chars[cursor] == "/", chars[cursor + 1] == "*" {
                        depth += 1; cursor += 2
                    } else if chars[cursor] == "*", chars[cursor + 1] == "/" {
                        depth -= 1; cursor += 2
                    } else {
                        cursor += 1
                    }
                }
            } else if chars[cursor].isLetter || chars[cursor] == "_" {
                let start = cursor
                cursor += 1
                while cursor < chars.count, chars[cursor].isLetter || chars[cursor].isNumber || chars[cursor] == "_" { cursor += 1 }
                tokens.append(String(chars[start..<cursor]))
            } else {
                if chars[cursor] == "{" || chars[cursor] == "}" { tokens.append(String(chars[cursor])) }
                cursor += 1
            }
        }
        var bodies: [String: Set<String>] = [:]
        cursor = 0
        while cursor + 1 < tokens.count {
            guard tokens[cursor] == "fn" else { cursor += 1; continue }
            let name = tokens[cursor + 1]
            cursor += 2
            while cursor < tokens.count, tokens[cursor] != "{" { cursor += 1 }
            var depth = 0
            var names: Set<String> = []
            repeat {
                guard cursor < tokens.count else { break }
                let token = tokens[cursor]
                if token == "{" { depth += 1 } else if token == "}" { depth -= 1 } else { names.insert(token) }
                cursor += 1
            } while depth > 0
            bodies[name] = names
        }
        var pending = [entryPoint]
        var visited: Set<String> = []
        var result: Set<String> = []
        while let name = pending.popLast() {
            guard visited.insert(name).inserted, let body = bodies[name] else { continue }
            result.formUnion(body)
            pending.append(contentsOf: body.filter { bodies[$0] != nil && !visited.contains($0) })
        }
        return result
    }
}

private extension ShaderReflectionData {
    mutating func ensureDescriptorSet(at index: Int) {
        guard index >= descriptorSets.count else {
            return
        }

        descriptorSets.append(contentsOf: Array(repeating: ShaderResource.DescriptorSet(), count: index - descriptorSets.count + 1))
    }
}
