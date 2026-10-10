import Foundation

/// Reflection for generated WGSL sidecars used by browser startup.
enum WGSLReflection {
    static func parse(from source: String, stage: ShaderStage) -> ShaderReflectionData {
        var reflection = ShaderReflectionData()
        let stageFlag = ShaderStageFlags(shaderStage: stage)
        let pattern = #"@group\(\s*(\d+)u?\s*\)\s*@binding\(\s*(\d+)u?\s*\)\s*var(?:<([^>]+)>)?\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([^;]+);"#
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
                    textureType: .texture2D,
                    descriptorSet: group,
                    arraySize: 1,
                    shaderStage: stageFlag,
                    resourceAccess: .read
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
}

private extension ShaderReflectionData {
    mutating func ensureDescriptorSet(at index: Int) {
        guard index >= descriptorSets.count else {
            return
        }

        descriptorSets.append(contentsOf: Array(repeating: ShaderResource.DescriptorSet(), count: index - descriptorSets.count + 1))
    }
}
