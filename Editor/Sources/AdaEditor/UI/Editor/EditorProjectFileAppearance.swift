@_spi(AdaEngine) import AdaEngine
import Foundation

/// Visual identity is independent of the editor used to open a file.
enum EditorProjectFileAppearance: Equatable {
    case folder, scene, image, audio, tileSet, tileMap, atlas, font, material, mesh, shader, ui, code, configuration, document, generic

    static func resolve(for item: EditorProjectSidebarViewModel.Item) -> Self {
        if item.isFolder {
            return .folder
        }

        // Resource formats can also be classified as text or generic assets.
        switch URL(fileURLWithPath: item.title).pathExtension.lowercased() {
        case "tileset": return .tileSet
        case "tilemap": return .tileMap
        case "atlas": return .atlas
        case "ttf", "otf", "woff", "woff2": return .font
        case "mat": return .material
        case "mesh", "obj", "gltf", "glb", "fbx", "usdz": return .mesh
        case "ui": return .ui
        default: break
        }

        switch item.kind {
        case .folder: return .folder
        case .scene: return .scene
        case .image: return .image
        case .audio: return .audio
        case let .text(language):
            switch language {
            case .glsl, .wgsl, .metal: return .shader
            case .json, .yaml: return .configuration
            case .markdown, .plainText: return .document
            default: return .code
            }
        case .genericAsset, .unsupported: return .generic
        }
    }

    var symbol: String {
        switch self {
        case .folder: EditorProjectTreeIcon.folder
        case .scene: EditorProjectTreeIcon.scene
        case .image: EditorProjectTreeIcon.image
        case .audio: EditorProjectTreeIcon.audioFile
        case .tileSet: EditorProjectTreeIcon.tileSet
        case .tileMap: EditorProjectTreeIcon.tileMap
        case .atlas: EditorProjectTreeIcon.atlas
        case .font: EditorProjectTreeIcon.font
        case .material: EditorProjectTreeIcon.material
        case .mesh: EditorProjectTreeIcon.mesh
        case .shader: EditorProjectTreeIcon.shader
        case .ui: EditorProjectTreeIcon.ui
        case .code: EditorProjectTreeIcon.code
        case .configuration: EditorProjectTreeIcon.configuration
        case .document: EditorProjectTreeIcon.article
        case .generic: EditorProjectTreeIcon.description
        }
    }

    func color(in colors: EditorThemeColors) -> Color {
        switch self {
        case .folder, .generic: colors.muted
        case .scene: colors.purple
        case .image, .code: colors.blue
        case .audio: Color.fromHex(0xE99A69)
        case .tileSet: Color.fromHex(0x5BC2B3)
        case .tileMap: Color.fromHex(0x83C174)
        case .atlas: Color.fromHex(0xE6BB65)
        case .font: Color.fromHex(0xDA8EC4)
        case .material: Color.fromHex(0x6CC5D9)
        case .mesh: Color.fromHex(0xA99AE8)
        case .shader: Color.fromHex(0xE4A85F)
        case .ui: Color.fromHex(0x82B3E8)
        case .configuration: Color.fromHex(0xB6BC78)
        case .document: colors.text.opacity(0.72)
        }
    }
}
