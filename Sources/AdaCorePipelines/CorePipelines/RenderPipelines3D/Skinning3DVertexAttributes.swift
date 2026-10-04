import AdaRender

func configureSkinningAttributes(_ descriptor: inout VertexDescriptor) {
    if !descriptor.attributes.containsAttribute(by: MeshDescriptor.textureCoordinates1.id.name) {
        descriptor.attributes[15] = .attribute(.vector2, name: "defaultTextureCoordinate1", bufferIndex: 4, offset: 64)
    }
    if !descriptor.attributes.containsAttribute(by: MeshDescriptor.colors.id.name) {
        descriptor.attributes[3] = .attribute(.vector4, name: "defaultVertexColor", bufferIndex: 4, offset: 80)
    }
    if !descriptor.attributes.containsAttribute(by: MeshDescriptor.jointIndices.id.name) {
        descriptor.attributes[13] = .attribute(.vector4, name: "defaultJointIndices", bufferIndex: 4, offset: 32)
    }
    if !descriptor.attributes.containsAttribute(by: MeshDescriptor.jointWeights.id.name) {
        descriptor.attributes[14] = .attribute(.vector4, name: "defaultJointWeights", bufferIndex: 4, offset: 48)
    }
}
