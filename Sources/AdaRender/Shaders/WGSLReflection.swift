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

        let layouts = WGSLLayout(source: source)
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
                    size: layouts.size(of: type),
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

/// Sizes of WGSL types in the uniform address space, so material uniform buffers can be allocated for generated sidecars.
/// A type that cannot be resolved (unknown name, `@size`/`@align` attributes, runtime arrays) reports 0 instead of a guess.
private struct WGSLLayout {
    private struct Layout {
        let size: Int
        let alignment: Int
    }

    private var structs: [String: String] = [:]
    private var cache: [String: Layout?] = [:]

    init(source: String) {
        guard let regex = try? NSRegularExpression(pattern: #"struct\s+([A-Za-z_][A-Za-z0-9_]*)\s*\{([^}]*)\}"#) else { return }
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let nameRange = Range(match.range(at: 1), in: source), let bodyRange = Range(match.range(at: 2), in: source) else { continue }
            structs[String(source[nameRange])] = Self.removingComments(from: String(source[bodyRange]))
        }
    }

    /// Comments can hold text that looks like a member (`// fade: f32`); drop `//` and `/* */` before reading members.
    private static func removingComments(from text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if text[index] == "/", next < text.endIndex, text[next] == "/" {
                while index < text.endIndex, text[index] != "\n" { index = text.index(after: index) }
            } else if text[index] == "/", next < text.endIndex, text[next] == "*" {
                index = text.index(next, offsetBy: 1, limitedBy: text.endIndex) ?? text.endIndex
                while index < text.endIndex {
                    let after = text.index(after: index)
                    if text[index] == "*", after < text.endIndex, text[after] == "/" {
                        index = text.index(after: after)
                        break
                    }
                    index = after
                }
                result.append(" ")
            } else {
                result.append(text[index])
                index = next
            }
        }
        return result
    }

    func size(of type: String) -> Int {
        var visiting: Set<String> = []
        return layout(of: type.trimmingCharacters(in: .whitespacesAndNewlines), visiting: &visiting)?.size ?? 0
    }

    private func layout(of type: String, visiting: inout Set<String>) -> Layout? {
        if let scalar = Self.scalar(type) { return Layout(size: scalar, alignment: scalar) }
        if let vector = Self.vector(type) { return vector }
        if let matrix = Self.matrix(type) { return matrix }
        if type.hasPrefix("array<"), type.hasSuffix(">") {
            return arrayLayout(String(type.dropFirst(6).dropLast()), visiting: &visiting)
        }
        guard let body = structs[type], visiting.insert(type).inserted else { return nil }
        defer { visiting.remove(type) }
        var offset = 0
        var alignment = 1
        for member in Self.members(of: body) {
            let declaration = member.trimmingCharacters(in: .whitespacesAndNewlines)
            if declaration.isEmpty { continue }
            guard !declaration.contains("@"), let colon = declaration.firstIndex(of: ":") else { return nil }
            let memberType = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let memberLayout = layout(of: memberType, visiting: &visiting) else { return nil }
            offset = Self.roundUp(offset, to: memberLayout.alignment) + memberLayout.size
            alignment = max(alignment, memberLayout.alignment)
        }
        guard offset > 0 else { return nil }
        return Layout(size: Self.roundUp(offset, to: alignment), alignment: alignment)
    }

    private func arrayLayout(_ arguments: String, visiting: inout Set<String>) -> Layout? {
        // Split at the last top-level comma: the element type can itself contain commas, such as `vec4<f32>`.
        var depth = 0
        var split: String.Index?
        for index in arguments.indices {
            switch arguments[index] {
            case "<": depth += 1
            case ">": depth -= 1
            case "," where depth == 0: split = index
            default: break
            }
        }
        guard let split,
              let count = Int(arguments[arguments.index(after: split)...].trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "iu"))),
              count > 0,
              let element = layout(of: arguments[..<split].trimmingCharacters(in: .whitespacesAndNewlines), visiting: &visiting)
        else { return nil }
        return Layout(size: Self.roundUp(element.size, to: element.alignment) * count, alignment: element.alignment)
    }

    /// Struct members are separated by commas outside template arguments such as `array<vec4f, 4>`.
    private static func members(of body: String) -> [String] {
        var members: [String] = []
        var current = ""
        var depth = 0
        for character in body {
            switch character {
            case "<": depth += 1
            case ">": depth -= 1
            case "," where depth == 0:
                members.append(current)
                current = ""
                continue
            default: break
            }
            current.append(character)
        }
        members.append(current)
        return members
    }

    private static func roundUp(_ value: Int, to alignment: Int) -> Int {
        (value + alignment - 1) / alignment * alignment
    }

    private static func scalar(_ type: String) -> Int? {
        switch type {
        case "f32", "i32", "u32": 4
        case "f16": 2
        default: nil
        }
    }

    /// `vec3f`, `vec3<f32>`: size is components times the scalar size; alignment is that of a vec2 or vec4.
    private static func vector(_ type: String) -> Layout? {
        guard let (components, scalarSize) = vectorShape(type, prefix: "vec") else { return nil }
        let alignment = (components == 2 ? 2 : 4) * scalarSize
        return Layout(size: components * scalarSize, alignment: alignment)
    }

    private static func matrix(_ type: String) -> Layout? {
        // `mat4x4f`, `mat3x2<f32>`: columns by rows. A column is a vector of the row count.
        guard type.hasPrefix("mat"), type.count > 6 else { return nil }
        let chars = Array(type)
        guard let columns = chars[3].wholeNumberValue, chars[4] == "x", let rows = chars[5].wholeNumberValue,
              (2...4).contains(columns), (2...4).contains(rows),
              let scalarSize = scalarSuffix(String(chars[6...])) else { return nil }
        let alignment = (rows == 2 ? 2 : 4) * scalarSize
        return Layout(size: columns * roundUp(rows * scalarSize, to: alignment), alignment: alignment)
    }

    private static func vectorShape(_ type: String, prefix: String) -> (Int, Int)? {
        guard type.hasPrefix(prefix), let components = type.dropFirst(prefix.count).first?.wholeNumberValue,
              (2...4).contains(components),
              let scalarSize = scalarSuffix(String(type.dropFirst(prefix.count + 1))) else { return nil }
        return (components, scalarSize)
    }

    /// `f`, `i`, `u`, `h` aliases or `<f32>`-style template arguments.
    private static func scalarSuffix(_ suffix: String) -> Int? {
        switch suffix {
        case "f", "i", "u", "<f32>", "<i32>", "<u32>": 4
        case "h", "<f16>": 2
        default: nil
        }
    }
}
