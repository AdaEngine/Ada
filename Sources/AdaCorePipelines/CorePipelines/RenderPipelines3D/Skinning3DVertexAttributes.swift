import AdaRender

func configureSkinningAttributes(_ descriptor: inout VertexDescriptor) {
    if !descriptor.attributes.containsAttribute(by: MeshDescriptor.jointIndices.id.name) {
        descriptor.attributes[13] = .attribute(.vector4, name: "defaultJointIndices", bufferIndex: 4, offset: 32)
    }
    if !descriptor.attributes.containsAttribute(by: MeshDescriptor.jointWeights.id.name) {
        descriptor.attributes[14] = .attribute(.vector4, name: "defaultJointWeights", bufferIndex: 4, offset: 48)
    }
}
