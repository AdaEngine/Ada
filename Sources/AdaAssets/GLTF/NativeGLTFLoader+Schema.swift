extension NativeGLTFLoader {
    /// Errors raised when a glTF document cannot be imported safely.
    public enum GLTFError: Error, Equatable, Sendable {
        case invalidNode(Int)
        case invalidSkin(Int)
        case invalidSkinningAttributes
        case unsupportedJointSet(Int)
        case invalidAnimation(Int)
        case unsupportedAnimationPath(String)
        case invalidGLB
        case missingJSONChunk
        case missingBufferURI
        case invalidDataURI
        case bufferTooShort
        case bufferOutOfBounds
        case invalidStride
        case invalidIndices
        case sparseIndexOutOfBounds
        case invalidAccessorIndex(Int)
        case invalidBufferViewIndex(Int)
        case invalidBufferIndex(Int)
        case unknownAttribute(String)
        case invalidComponentType(Int)
        case invalidAccessorType(String)
        case unsupportedRequiredExtension(String)
    }

    struct GLTF: Codable {
        struct Buffer: Codable {
            let uri: String?
            let byteLength: Int
        }

        struct BufferView: Codable {
            let buffer: Int
            let byteOffset: Int?
            let byteLength: Int
            let byteStride: Int?
            let target: Int?
        }

        struct Accessor: Codable {
            struct Sparse: Codable {
                struct Indices: Codable {
                    let bufferView: Int
                    let byteOffset: Int?
                    let componentType: Int
                }

                struct Values: Codable {
                    let bufferView: Int
                    let byteOffset: Int?
                }

                let count: Int
                let indices: Indices
                let values: Values
            }

            let bufferView: Int?
            let byteOffset: Int?
            let componentType: Int
            let normalized: Bool?
            let count: Int
            let type: String
            let min: [Float]?
            let max: [Float]?
            let sparse: Sparse?
        }

        struct Mesh: Codable {
            struct Primitive: Codable {
                let attributes: [String: Int]
                let indices: Int?
                let material: Int?
                let mode: Int?
            }

            let name: String?
            let primitives: [Primitive]
        }

        struct Material: Codable {
            struct PBR: Codable {
                struct TextureInfo: Codable {
                    let index: Int
                    let texCoord: Int?
                }

                let baseColorFactor: [Float]?
                let baseColorTexture: TextureInfo?
                let metallicFactor: Float?
                let roughnessFactor: Float?
                let metallicRoughnessTexture: TextureInfo?
            }

            struct NormalTextureInfo: Codable {
                let index: Int
                let texCoord: Int?
                let scale: Float?
            }

            let name: String?
            let pbrMetallicRoughness: PBR?
            let normalTexture: NormalTextureInfo?
        }

        struct Texture: Codable {
            let sampler: Int?
            let source: Int?
        }

        struct Image: Codable {
            let uri: String?
            let mimeType: String?
            let bufferView: Int?
        }

        struct Node: Codable {
            let name: String?
            let children: [Int]?
            let matrix: [Float]?
            let translation: [Float]?
            let rotation: [Float]?
            let scale: [Float]?
            let mesh: Int?
            let camera: Int?
            let skin: Int?
        }

        struct Skin: Codable {
            let name: String?
            let joints: [Int]
            let skeleton: Int?
            let inverseBindMatrices: Int?
        }

        struct Animation: Codable {
            struct Sampler: Codable {
                let input: Int
                let output: Int
                let interpolation: String?
            }

            struct Channel: Codable {
                struct Target: Codable {
                    let node: Int?
                    let path: String
                }
                let sampler: Int
                let target: Target
            }

            let name: String?
            let samplers: [Sampler]
            let channels: [Channel]
        }

        struct Scene: Codable {
            let nodes: [Int]?
            let name: String?
        }

        let asset: Asset
        let scene: Int?
        let scenes: [Scene]?
        let nodes: [Node]?
        let skins: [Skin]?
        let animations: [Animation]?
        let meshes: [Mesh]?
        let accessors: [Accessor]?
        let bufferViews: [BufferView]?
        let buffers: [Buffer]?
        let materials: [Material]?
        let textures: [Texture]?
        let images: [Image]?
        let extensionsUsed: [String]?
        let extensionsRequired: [String]?

        struct Asset: Codable {
            let version: String
        }
    }
}
