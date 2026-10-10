@_spi(AdaEngine) import AdaEngine
import Foundation
import Observation

extension EditorWorkbenchViewModel {
    func textureSettingsModel(for document: EditorAssetDocument) -> EditorTextureSettingsModel {
        if let model = textureSettingsModels[document.id] {
            return model
        }
        let model = EditorTextureSettingsModel(
            document: document,
            canWrite: { [weak self] url in
                self?.openDocuments.contains { $0.absolutePath == url.path && $0.isDirty } != true
            }
        )
        textureSettingsModels[document.id] = model
        return model
    }
}

@Observable
@MainActor
final class EditorTextureSettingsModel {
    var settings = TextureImportSettings()
    var previewLevel = 0
    var previewFace = 0
    private(set) var sourceImage: Image?
    private(set) var imported: ImportedTextureData?
    private(set) var isApplying = false
    private(set) var isEditable = false
    private(set) var statusMessage = ""
    private(set) var hasError = false

    @ObservationIgnored private let document: EditorAssetDocument
    @ObservationIgnored private let canWrite: (URL) -> Bool
    @ObservationIgnored private var sourceData: Data?
    @ObservationIgnored private var lastSavedData: Data?
    @ObservationIgnored private var savedSettings = TextureImportSettings()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadingGeneration: Int?

    init(document: EditorAssetDocument, canWrite: @escaping (URL) -> Bool = { _ in true }) {
        self.document = document
        self.canWrite = canWrite
        reload()
    }

    var imageURL: URL? { document.absolutePath.map { URL(fileURLWithPath: $0) } }
    var isDirty: Bool { settings != savedSettings }
    var levelCount: Int { imported?.faces.first?.count ?? 1 }
    var faceCount: Int { imported?.faces.count ?? 1 }
    var previewImage: Image? {
        guard let imported else {
            return sourceImage
        }
        let faces = imported.faces
        let face = faces[min(max(0, previewFace), faces.count - 1)]
        var image = face[min(max(0, previewLevel), face.count - 1)]
        image.samplerDescription = imported.settings.sampler
        // This preview uploads the selected level as an independent single-level image.
        image.samplerDescription.mipFilter = .notMipmapped
        image.samplerDescription.lodMinClamp = 0
        image.samplerDescription.lodMaxClamp = 0
        return image
    }

    func reload() {
        guard !isApplying else {
            return
        }
        generation &+= 1
        loadingGeneration = nil
        imported = nil
        sourceImage = nil
        sourceData = nil
        previewLevel = 0
        previewFace = 0
        hasError = false
        isEditable = false
        guard let url = imageURL else {
            statusMessage = "Texture has no local file path."
            return
        }
        do {
            let data = try Data(contentsOf: url)
            sourceData = data
            let image = try Image.decode(from: data, fileExtension: url.pathExtension)
            sourceImage = image
            let sidecar = TextureImportSettings.sidecarURL(for: url)
            lastSavedData = FileManager.default.fileExists(atPath: sidecar.path) ? try Data(contentsOf: sidecar) : nil
            settings = try lastSavedData.map { try JSONDecoder().decode(TextureImportSettings.self, from: $0) } ?? TextureImportSettings()
            if lastSavedData == nil {
                // Preserve the current linear, single-level behavior until the user applies a change.
                settings.colorSpace = .linear
                settings.sampler = image.samplerDescription
            }
            try settings.validate(for: image)
            savedSettings = settings
            let sourceIsLink = try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
            let settingsIsLink = (try? sidecar.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            isEditable = !sourceIsLink && !settingsIsLink && FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
            statusMessage = isEditable ? "Apply saves settings for the next resource load." : "Read-only texture."
            Task { await loadPreviewIfNeeded() }
        } catch {
            hasError = true
            statusMessage = error.localizedDescription
        }
    }

    func loadPreviewIfNeeded() async {
        guard imported == nil, let image = sourceImage, !hasError else {
            return
        }
        let token = generation
        guard loadingGeneration != token else {
            return
        }
        loadingGeneration = token
        defer {
            if loadingGeneration == token { loadingGeneration = nil }
        }
        do {
            let result = try await Self.prepare(image, settings: savedSettings)
            guard generation == token else {
                return
            }
            imported = result
        } catch {
            guard generation == token else {
                return
            }
            hasError = true
            statusMessage = error.localizedDescription
        }
    }

    func apply() { Task { await applySettings() } }

    @discardableResult
    func applySettings() async -> Bool {
        guard isEditable, !isApplying, let image = sourceImage, let url = imageURL else {
            return false
        }
        isApplying = true
        generation &+= 1
        defer { isApplying = false }
        let selected = settings
        do {
            let prepared = try await Self.prepare(image, settings: selected)
            let sidecar = TextureImportSettings.sidecarURL(for: url)
            guard canWrite(sidecar) else { throw Failure("Save the open texture settings document before applying.") }
            let settingsIsLink = (try? sidecar.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
            let sourceIsLink = try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
            guard !settingsIsLink && !sourceIsLink else { throw Failure("Texture or settings became a symbolic link. Reload before editing.") }
            let current = FileManager.default.fileExists(atPath: sidecar.path) ? try Data(contentsOf: sidecar) : nil
            guard current == lastSavedData, try Data(contentsOf: url) == sourceData else {
                throw Failure("Texture or settings changed on disk. Reload before applying.")
            }
            let encoded = try selected.encoded()
            try encoded.write(to: sidecar, options: .atomic)
            lastSavedData = encoded
            savedSettings = selected
            imported = prepared
            previewLevel = min(previewLevel, levelCount - 1)
            previewFace = min(previewFace, faceCount - 1)
            hasError = false
            statusMessage = "Saved. Restart Play to reload existing textures."
            return true
        } catch {
            hasError = true
            statusMessage = error.localizedDescription
            return false
        }
    }

    // CPU import owns value snapshots and runs off the UI actor; no render-device access occurs here.
    @concurrent private static func prepare(_ image: Image, settings: TextureImportSettings) async throws -> ImportedTextureData {
        try settings.prepare(image)
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
