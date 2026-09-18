@_spi(AdaEngine) import AdaEngine
import Foundation
import Observation
import Yams

@Observable
@MainActor
final class EditorTextureAtlasEditorModel {
    private(set) var atlasImage: Image?
    private(set) var descriptor = NamedTextureAtlas.Descriptor(images: [])
    private(set) var isEditable = true
    private(set) var isLoadingPreview = false
    private(set) var statusMessage = "Loading atlas…"

    @ObservationIgnored
    private let document: EditorAssetDocument
    @ObservationIgnored
    private var lastSavedData: Data?
    @ObservationIgnored
    private var previewTask: Task<Void, Never>?

    init(document: EditorAssetDocument) {
        self.document = document
        loadDescriptor()
    }

    var canAddImages: Bool {
        isEditable && document.absolutePath != nil
    }

    func loadPreviewIfNeeded() {
        guard previewTask == nil else {
            return
        }
        reloadPreview()
    }

    func presentImagePicker() {
        guard canAddImages else {
            return
        }
        ProjectOpenPicker.presentAtlasImagePicker { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case let .selected(urls):
                self.addImages(from: urls)
            case .cancelled:
                break
            case let .unavailable(message):
                self.statusMessage = message
            }
        }
    }

    func addImages(from sourceURLs: [URL]) {
        guard let atlasURL = fileURL else {
            statusMessage = "Atlas has no writable file path."
            return
        }
        guard isEditable else {
            statusMessage = "Fix the atlas descriptor before adding images."
            return
        }

        var updatedDescriptor = descriptor
        var copiedURLs: [URL] = []
        var addedCount = 0

        do {
            for sourceURL in sourceURLs where sourceURL.pathExtension.lowercased() == "png" {
                let referencedURL = try prepareReference(
                    to: sourceURL,
                    for: atlasURL,
                    copiedURLs: &copiedURLs
                )
                guard !containsReference(to: referencedURL, in: updatedDescriptor, atlasURL: atlasURL) else {
                    continue
                }

                let path = relativePath(
                    from: atlasURL.deletingLastPathComponent(),
                    to: referencedURL
                )
                let defaultKey = referencedURL.deletingPathExtension().lastPathComponent
                let key = uniqueKey(defaultKey, in: updatedDescriptor)
                updatedDescriptor.images.append(
                    NamedTextureAtlas.Source(
                        path: path,
                        key: key == defaultKey ? nil : key
                    )
                )
                addedCount += 1
            }

            guard addedCount > 0 else {
                statusMessage = "No new PNG images were added."
                return
            }

            try save(updatedDescriptor, to: atlasURL)
            descriptor = updatedDescriptor
            statusMessage = addedCount == 1 ? "Added 1 image" : "Added \(addedCount) images"
            reloadPreview()
        } catch {
            for copiedURL in copiedURLs {
                try? FileManager.default.removeItem(at: copiedURL)
            }
            statusMessage = "Add failed: \(error.localizedDescription)"
        }
    }

    func removeImage(at index: Int) {
        guard descriptor.images.indices.contains(index), let atlasURL = fileURL else {
            return
        }

        var updatedDescriptor = descriptor
        updatedDescriptor.images.remove(at: index)
        do {
            try save(updatedDescriptor, to: atlasURL)
            descriptor = updatedDescriptor
            statusMessage = "Removed image"
            reloadPreview()
        } catch {
            statusMessage = "Remove failed: \(error.localizedDescription)"
        }
    }

    func displayKey(for source: NamedTextureAtlas.Source) -> String {
        source.key ?? URL(fileURLWithPath: source.path).deletingPathExtension().lastPathComponent
    }

    var fileURL: URL? {
        document.absolutePath.map { URL(fileURLWithPath: $0, isDirectory: false) }
    }

    private func loadDescriptor() {
        guard let fileURL else {
            isEditable = false
            statusMessage = "Sample atlas cannot be edited."
            return
        }

        do {
            let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                isEditable = false
                statusMessage = "Symbolic-link atlases are read-only."
                return
            }

            let data = try Data(contentsOf: fileURL)
            lastSavedData = data
            if data.isEmpty {
                descriptor = NamedTextureAtlas.Descriptor(images: [])
            } else {
                descriptor = try YAMLDecoder(encoding: .utf8)
                    .decode(
                        NamedTextureAtlas.Descriptor.self,
                        from: data
                    )
            }
            statusMessage = descriptor.images.isEmpty ? "Add PNG images to build the atlas." : "Loaded \(descriptor.images.count) images"
        } catch {
            isEditable = false
            statusMessage = "Unable to read atlas: \(error.localizedDescription)"
        }
    }

    private func reloadPreview() {
        previewTask?.cancel()
        atlasImage = nil

        guard !descriptor.images.isEmpty, let fileURL else {
            isLoadingPreview = false
            previewTask = nil
            return
        }

        isLoadingPreview = true
        let resourcePath = fileURL.path
        previewTask = Task { [weak self] in
            do {
                await AssetsManager.unload(NamedTextureAtlas.self, at: resourcePath)
                let handle = try await AssetsManager.load(NamedTextureAtlas.self, at: resourcePath)
                guard !Task.isCancelled, let atlas = handle.asset else {
                    return
                }
                let image = Image(texture: atlas.texture)
                guard !Task.isCancelled else {
                    return
                }
                self?.atlasImage = image
                self?.isLoadingPreview = false
                self?.previewTask = nil
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self?.isLoadingPreview = false
                self?.statusMessage = "Preview failed: \(error.localizedDescription)"
                self?.previewTask = nil
            }
        }
    }

    private func save(_ descriptor: NamedTextureAtlas.Descriptor, to url: URL) throws {
        let currentData = try Data(contentsOf: url)
        guard currentData == lastSavedData else {
            loadDescriptor()
            throw EditorTextureAtlasEditingError.fileChangedOnDisk
        }

        var yaml = try YAMLEncoder().encode(descriptor)
        if !yaml.hasSuffix("\n") {
            yaml.append("\n")
        }
        let data = Data(yaml.utf8)
        try data.write(to: url, options: .atomic)
        lastSavedData = data
    }

    private func prepareReference(
        to sourceURL: URL,
        for atlasURL: URL,
        copiedURLs: inout [URL]
    ) throws -> URL {
        let sourceURL = sourceURL.standardizedFileURL
        if let assetsRoot = assetsRoot(containing: atlasURL), isDescendant(sourceURL, of: assetsRoot) {
            return sourceURL
        }

        let importDirectory = atlasURL.deletingLastPathComponent()
            .appendingPathComponent(
                "\(atlasURL.deletingPathExtension().lastPathComponent).images",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        let existingDestinationURL = importDirectory.appendingPathComponent(sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: existingDestinationURL.path),
            try Data(contentsOf: existingDestinationURL) == Data(contentsOf: sourceURL) {
            return existingDestinationURL
        }
        let destinationURL = uniqueDestination(for: sourceURL, in: importDirectory)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        copiedURLs.append(destinationURL)
        return destinationURL
    }

    private func assetsRoot(containing atlasURL: URL) -> URL? {
        var candidate = atlasURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if candidate.lastPathComponent.caseInsensitiveCompare("Assets") == .orderedSame {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else {
                return nil
            }
            candidate = parent
        }
    }

    private func isDescendant(_ url: URL, of rootURL: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = rootURL.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : "\(rootPath)/")
    }

    private func containsReference(
        to url: URL,
        in descriptor: NamedTextureAtlas.Descriptor,
        atlasURL: URL
    ) -> Bool {
        let targetPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        return descriptor.images.contains { source in
            resolvedURL(for: source.path, atlasURL: atlasURL).resolvingSymlinksInPath().standardizedFileURL.path == targetPath
        }
    }

    private func resolvedURL(for path: String, atlasURL: URL) -> URL {
        if path.hasPrefix("@res://"), let assetsRoot = assetsRoot(containing: atlasURL) {
            return assetsRoot.appendingPathComponent(String(path.dropFirst("@res://".count)))
        }
        if path.hasPrefix("file://"), let url = URL(string: path) {
            return url
        }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path, isDirectory: false)
        }
        return atlasURL.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
    }

    private func relativePath(from baseURL: URL, to targetURL: URL) -> String {
        let baseComponents = baseURL.standardizedFileURL.pathComponents
        let targetComponents = targetURL.standardizedFileURL.pathComponents
        var commonCount = 0
        while commonCount < min(baseComponents.count, targetComponents.count),
            baseComponents[commonCount] == targetComponents[commonCount] {
            commonCount += 1
        }

        let parents = Array(repeating: "..", count: baseComponents.count - commonCount)
        return (parents + targetComponents.dropFirst(commonCount)).joined(separator: "/")
    }

    private func uniqueKey(_ baseKey: String, in descriptor: NamedTextureAtlas.Descriptor) -> String {
        let existingKeys = Set(descriptor.images.map(displayKey))
        guard existingKeys.contains(baseKey) else {
            return baseKey
        }

        var counter = 2
        while existingKeys.contains("\(baseKey)_\(counter)") {
            counter += 1
        }
        return "\(baseKey)_\(counter)"
    }

    private func uniqueDestination(for sourceURL: URL, in directoryURL: URL) -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let pathExtension = sourceURL.pathExtension
        var destinationURL = directoryURL.appendingPathComponent(sourceURL.lastPathComponent)
        var counter = 2

        while FileManager.default.fileExists(atPath: destinationURL.path) {
            destinationURL = directoryURL.appendingPathComponent("\(baseName)-\(counter).\(pathExtension)")
            counter += 1
        }
        return destinationURL
    }
}

enum EditorTextureAtlasEditingError: LocalizedError {
    case fileChangedOnDisk

    var errorDescription: String? {
        switch self {
        case .fileChangedOnDisk:
            "The atlas changed on disk. Its latest contents were reloaded; add the images again."
        }
    }
}

struct EditorTextureAtlasAssetEditor: View {
    let document: EditorAssetDocument
    private let onAddImages: (() -> Void)?

    @State private var model: EditorTextureAtlasEditorModel
    @Environment(\.theme) private var theme

    init(
        document: EditorAssetDocument,
        model: EditorTextureAtlasEditorModel? = nil,
        onAddImages: (() -> Void)? = nil
    ) {
        self.document = document
        self.onAddImages = onAddImages
        self._model = State(initialValue: model ?? EditorTextureAtlasEditorModel(document: document))
    }

    var body: some View {
        HStack(spacing: 0) {
            previewPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            sourcePane
                .frame(width: 280)
                .frame(maxHeight: .infinity)
        }
        .background(theme.editorColors.background)
        .onAppear {
            model.loadPreviewIfNeeded()
        }
        .accessibilityIdentifier("AdaEditor.AtlasEditor")
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            ZStack {
                checkerboard
                if let atlasImage = model.atlasImage {
                    atlasImage
                        .resizable()
                        .aspectRatio(Float(atlasImage.width) / Float(max(1, atlasImage.height)), contentMode: .fit)
                        .padding(28)
                } else {
                    Text(model.isLoadingPreview ? "Building atlas preview…" : "Add images to build the atlas")
                        .font(.system(size: 12))
                        .foregroundColor(theme.editorColors.muted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .mask(RoundedRectangleShape(cornerRadius: 8))
            .overlay {
                RoundedRectangleShape(cornerRadius: 8)
                    .stroke(theme.editorColors.border, lineWidth: 1)
            }
            .accessibilityIdentifier("AdaEditor.AtlasEditor.Preview")

            Text(model.statusMessage)
                .font(.system(size: 10))
                .foregroundColor(theme.editorColors.muted)
                .lineLimit(2)
        }
        .padding(16)
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(document.title)
                    .font(.system(size: 15))
                    .foregroundColor(theme.editorColors.text)
                Text(document.assetReference ?? document.relativePath)
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.muted)
            }
            Spacer()
            Text("\(model.descriptor.images.count) images")
                .font(.system(size: 10))
                .foregroundColor(theme.editorColors.blue)
        }
    }

    private var sourcePane: some View {
        VStack(alignment: .leading, spacing: 10) {
            sourcePaneHeader

            RectangleShape()
                .fill(theme.editorColors.border)
                .frame(height: 1)

            sourceList

            settingsSummary
        }
        .padding(12)
        .background(theme.editorColors.surfaceElevated)
        .overlay(anchor: .leading) {
            RectangleShape()
                .fill(theme.editorColors.border)
                .frame(width: 1)
        }
        .accessibilityIdentifier("AdaEditor.AtlasEditor.Sources")
    }

    private var sourcePaneHeader: some View {
        HStack(spacing: 8) {
            Text("Atlas Images")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(theme.editorColors.text)
            Spacer()
            Button(
                action: addImages,
                label: {
                    Text("+ Add")
                        .font(.system(size: 11))
                        .foregroundColor(theme.editorColors.blue)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.blue.opacity(0.12)))
                }
            )
            .buttonStyle(DefaultButtonStyle())
            .disabled(!model.canAddImages)
            .accessibilityIdentifier("AdaEditor.AtlasEditor.AddImages")
        }
    }

    @ViewBuilder
    private var sourceList: some View {
        if model.descriptor.images.isEmpty {
            Text("No images yet")
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
            Spacer()
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(model.descriptor.images.enumerated()), id: \.offset) { index, source in
                        sourceRow(source, index: index)
                    }
                }
            }
        }
    }

    private func sourceRow(_ source: NamedTextureAtlas.Source, index: Int) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayKey(for: source))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(theme.editorColors.text)
                    .lineLimit(1)
                Text(source.path)
                    .font(.system(size: 9))
                    .foregroundColor(theme.editorColors.muted)
                    .lineLimit(1)
            }
            Spacer()
            Button(
                action: { model.removeImage(at: index) },
                label: {
                    Text("×")
                        .font(.system(size: 13))
                        .foregroundColor(theme.editorColors.muted)
                        .frame(width: 22, height: 22)
                }
            )
            .buttonStyle(DefaultButtonStyle())
            .accessibilityIdentifier("AdaEditor.AtlasEditor.Remove.\(index)")
        }
        .padding(.horizontal, 8)
        .frame(height: 42)
        .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surface))
    }

    private var settingsSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Packing")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(theme.editorColors.text)
            Text("Margin \(model.descriptor.margin)  •  Padding \(model.descriptor.padding)  •  Extrude \(model.descriptor.extrude)")
                .font(.system(size: 9))
                .foregroundColor(theme.editorColors.muted)
            Text("Sampler \(model.descriptor.filter.rawValue)  •  Power of two \(model.descriptor.powerOfTwo ? "on" : "off")")
                .font(.system(size: 9))
                .foregroundColor(theme.editorColors.muted)
        }
        .padding(8)
        .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surface))
    }

    private var checkerboard: some View {
        Canvas { context, size in
            let tileSize: Float = 24
            context.drawRect(Rect(origin: .zero, size: size), color: theme.editorColors.surface)
            for row in 0..<max(1, Int(ceil(size.height / tileSize))) {
                for column in 0..<max(1, Int(ceil(size.width / tileSize))) where (row + column).isMultiple(of: 2) {
                    context.drawRect(
                        Rect(
                            x: Float(column) * tileSize,
                            y: Float(row) * tileSize,
                            width: min(tileSize, size.width - Float(column) * tileSize),
                            height: min(tileSize, size.height - Float(row) * tileSize)
                        ),
                        color: theme.editorColors.surfaceElevated.opacity(0.62)
                    )
                }
            }
        }
    }

    private func addImages() {
        if let onAddImages {
            onAddImages()
        } else {
            model.presentImagePicker()
        }
    }
}
