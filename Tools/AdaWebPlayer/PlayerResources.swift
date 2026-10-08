import AdaEngine
import AdaScriptCompilerCore
import Foundation
#if canImport(JavaScriptKit)
import JavaScriptEventLoop
import JavaScriptKit
#endif

/// Per-project cache. Resource IDs, rather than host paths, cross the AdaScript boundary.
@MainActor
final class PlayerResources {
    let project: AdaWebPlayerProject
    let directory: URL
    private var materials: [String: RuntimeWGSLMaterial] = [:]
    private var textures: [String: Texture2D] = [:]
    private var fonts: [String: Font] = [:]

    init(project: AdaWebPlayerProject, directory: URL) {
        self.project = project; self.directory = directory
    }

    func catalog() throws -> UICatalog {
        try UICatalog.standard.adding(views: [
            .init(signature: .init(id: "Player.Material", name: "Material", parameters: [
                .init("material", type: .string), .init("amount", type: .number)
            ])) { [self] inputs in
                let material = try material(inputs.string("material"))
                let amount = Float(inputs.number("amount"))
                guard amount.isFinite else { throw AdaWebPlayerProjectError.invalid("Material amount must be finite.") }
                material.setParameters(Vector4(amount, 0, 0, 0))
                return AnyView(Canvas { context, size in
                    context.drawShaderEffect(Rect(origin: .zero, size: size), material: material)
                })
            },
            .init(signature: .init(id: "Player.Text", name: "Text", parameters: [
                .init("font", type: .string), .init("text", type: .string), .init("size", type: .number)
            ])) { [self] inputs in
                var font = try font(inputs.string("font"))
                font.pointSize = max(1, min(100, inputs.number("size", 24)))
                return AnyView(Text(inputs.string("text")).font(font))
            },
            .init(signature: .init(id: "Player.Audio", name: "Audio", parameters: [.init("audio", type: .string)])) { [self] inputs in
                let id = inputs.string("audio")
                _ = try asset(id, kind: .audio)
                return AnyView(PlayerAudioButton(id: id))
            }
        ])
    }

    private func asset(_ id: String, kind: AdaWebPlayerAsset.Kind) throws -> AdaWebPlayerAsset {
        guard let asset = project.assets?.first(where: { $0.id == id && $0.kind == kind }) else {
            throw AdaWebPlayerProjectError.invalid("Missing \(kind.rawValue) resource '\(id)'.")
        }
        return asset
    }

    private func material(_ id: String) throws -> RuntimeWGSLMaterial {
        if let cached = materials[id] { return cached }
        guard let descriptor = project.materials?.first(where: { $0.id == id }) else {
            throw AdaWebPlayerProjectError.invalid("Unknown material '\(id)'.")
        }
        let shader = try asset(descriptor.shader, kind: .shader)
        let textureAsset = try asset(descriptor.texture, kind: .texture)
        let texture: Texture2D
        if let cached = textures[textureAsset.id] { texture = cached }
        else {
            texture = try Texture2D(image: Image(contentsOf: project.resourceURL(textureAsset.path, at: directory)))
            textures[textureAsset.id] = texture
        }
        let shaderURL = try project.resourceURL(shader.path, at: directory)
        let result = try RuntimeWGSLMaterial(fragmentSource: String(contentsOf: shaderURL, encoding: .utf8), texture: texture)
        materials[id] = result
        print("[AdaWebPlayer] Material \(id): \(shader.path), texture \(textureAsset.path)")
        return result
    }

    private func font(_ id: String) throws -> Font {
        if let cached = fonts[id] { return cached }
        let asset = try asset(id, kind: .font)
        let url = try project.resourceURL(asset.path, at: directory)
        guard let font = Font.dynamic(fontPath: url, size: 24) else {
            throw AdaWebPlayerProjectError.invalid("Unable to load font '\(id)'.")
        }
        fonts[id] = font
        print("[AdaWebPlayer] Font \(id): \(font.name)")
        return font
    }
}

@MainActor
private struct PlayerAudioButton: View {
    let id: String
    @State private var status = "Play / stop music"

    var body: some View {
        Button(status) {
            #if canImport(JavaScriptKit)
            if let action = JSObject.global.__adaPlayerAudio.object?.toggle.function,
               let promise = JSPromise.construct(from: action(id)) {
                status = "Loading music…"
                Task { @MainActor in
                    do { status = try await promise.value(isolation: MainActor.shared).string ?? "Play / stop music" }
                    catch { status = "Audio failed: \(error)" }
                }
            } else { status = "Web Audio unavailable" }
            #else
            status = "Music requires Web Player"
            #endif
        }
        .padding(12)
        .background(Color(0.8, 0.8, 1, 1))
    }
}
