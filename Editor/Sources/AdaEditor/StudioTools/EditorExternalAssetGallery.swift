@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorExternalAssetGallery: View {
    typealias Item = EditorExternalAssetLibrary.Listing
    typealias Store = EditorExternalAssetLibrary.Store

    let host: EditorStudioToolHost
    let library: EditorExternalAssetLibrary
    @Environment(\.theme) private var theme
    @State private var items: [Item] = []
    @State private var models: [UUID: URL] = [:]
    @State private var thumbnails: [UUID: Image] = [:]
    @State private var queued: [UUID] = []
    @State private var query = ""
    @State private var source = ""
    @State private var selected: UUID?
    @State private var compactDetails = false
    @State private var showsLocalFiles = false
    @State private var isAdding = false
    @State private var title = ""
    @State private var link = ""
    @State private var confirmRemoval: UUID?
    @State private var start = 0
    @State private var message: String?
    @State private var loading: Task<Void, Never>?
    @State private var operation: Task<Void, Never>?
    @State private var cacheWrite: Task<Void, Never>?

    private var active: Item? { items.first { $0.id == selected } }
    private var page: ArraySlice<Item> { items.dropFirst(start).prefix(24) }

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 700
            let contentWidth = max(1, geometry.size.width - 28)
            let inspectorWidth: Float = 286
            let gridWidth = wide && active != nil ? contentWidth - inspectorWidth - 16 : contentWidth
            let showingCompactDetails = !wide && compactDetails && active != nil
            VStack(alignment: .leading, spacing: 0) {
                filters(width: contentWidth)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 12)
                if isAdding {
                    form.frame(width: contentWidth).padding(.horizontal, 14).padding(.bottom, 12)
                }
                if let message {
                    Text(L10n.tr(message)).font(.system(size: 12)).foregroundColor(theme.editorColors.text)
                        .padding(.horizontal, 14).padding(.bottom, 12)
                }
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        if showingCompactDetails, let active {
                            action("Back to assets") {
                                compactDetails = false
                                showsLocalFiles = false
                                confirmRemoval = nil
                            }
                            .accessibilityIdentifier("studio.external-assets.back")
                            details(active, width: contentWidth)
                        } else if items.isEmpty {
                            empty
                        } else {
                            HStack(alignment: .top, spacing: 16) {
                                assetGrid(width: gridWidth, showsInspector: wide && active != nil)
                                if wide, let active {
                                    details(active, width: inspectorWidth)
                                }
                            }
                        }
                    }
                    .frame(width: contentWidth, alignment: .topLeading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
                .id(showingCompactDetails)
                .frame(maxHeight: .infinity)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .background(theme.editorColors.background)
        .onAppear { refresh(recover: true) }
        .onDisappear {
            loading?.cancel()
            operation?.cancel()
            cacheWrite?.cancel()
            loading = nil
            operation = nil
            cacheWrite = nil
        }
        .onChange(of: query) { _, _ in start = 0; refresh() }
        .onChange(of: source) { _, _ in start = 0; refresh() }
        .accessibilityIdentifier("studio.external-assets.gallery")
    }

    private func filters(width: Float) -> some View {
        let addWidth: Float = 138
        let storeWidth: Float = 144
        return VStack(alignment: .leading, spacing: 9) {
            if width >= 500 {
                HStack(alignment: .bottom, spacing: 10) {
                    searchField.frame(width: width - storeWidth - addWidth - 20)
                    storeFilter(width: storeWidth)
                    addListing.frame(width: addWidth)
                }
            } else {
                searchField.frame(width: width)
                if width >= storeWidth + addWidth + 10 {
                    HStack(alignment: .bottom, spacing: 0) {
                        storeFilter(width: storeWidth)
                        Spacer(minLength: 10)
                        addListing.frame(width: addWidth)
                    }
                    .frame(width: width)
                } else {
                    storeFilter(width: min(storeWidth, width))
                    addListing.frame(width: min(addWidth, width))
                }
            }
        }
        .accessibilityIdentifier("studio.external-assets.filters")
    }

    private var searchField: some View {
        field("Asset name", placeholder: "Search by name…", icon: "\u{E8B6}", identifier: "studio.external-assets.search", value: $query)
    }

    private func storeFilter(width: Float) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            caption("Store")
            DropDown(
                selection: $source,
                options: [.init(label: L10n.text("All stores"), value: "")] + Store.allCases.map { .init(label: $0.title, value: $0.rawValue) },
                identifier: "studio.external-assets.store"
            ) {
                HStack(spacing: 5) {
                    Text(Store(rawValue: source)?.title ?? L10n.text("All stores")).font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 0)
                    symbol("\u{E5CF}", size: 15)
                }
                .frame(width: max(1, width - 16))
            }
            .buttonStyle(EditorExternalAssetActionStyle(theme: theme, primary: false))
        }
    }

    private var addListing: some View {
        action("Add listing", symbol: "\u{E145}", fillsWidth: true) { isAdding.toggle() }
            .accessibilityIdentifier("studio.external-assets.add")
    }

    private func assetGrid(width: Float, showsInspector: Bool) -> some View {
        let spacing: Float = 10
        let minimumCard: Float = showsInspector ? 194 : 155
        let columns = max(1, Int((width + spacing) / (minimumCard + spacing)))
        let cardWidth = (width - Float(columns - 1) * spacing) / Float(columns)
        let previewHeight = min(184, max(110, cardWidth * 0.69))
        return VStack(spacing: 12) {
            Grid(columns: columns, horizontalSpacing: spacing, verticalSpacing: spacing) {
                ForEach(Array(page)) { item in card(item, previewHeight: previewHeight) }
            }
            if start > 0 || items.count > start + 24 {
                HStack {
                    action("Previous page") { changePage(by: -24) }.disabled(start == 0)
                    action("Next page") { changePage(by: 24) }.disabled(items.count <= start + 24)
                }
            }
        }
        .frame(width: width, alignment: .topLeading)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Asset title", value: $title)
            field("Listing link", value: $link)
            HStack {
                action("Save listing") {
                    perform {
                        let item = try await library.add(title: title, link: link)
                        select(item)
                        isAdding = false
                        title = ""
                        link = ""
                        query = ""
                        source = ""
                    }
                }
                .disabled(operation != nil || title.isEmpty || link.isEmpty)
                action("Cancel") { isAdding = false }
            }
        }
        .padding(12)
        .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surfaceElevated))
        .overlay { border(radius: 6) }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            if query.isEmpty, source.isEmpty {
                Text(L10n.text("Save a store listing to start your asset library."))
                HStack {
                    ForEach(Store.allCases, id: \.rawValue) { store in
                        action(store.title) { if let home = store.home { open(home) } }
                    }
                }
            } else {
                Text(L10n.text("No matching assets"))
                action("Clear asset search") { query = ""; source = "" }
            }
        }
        .padding(10)
    }

    private func card(_ item: Item, previewHeight: Float) -> some View {
        let hasFile = models[item.id] != nil
        let isSelected = selected == item.id
        return Button {
            select(item)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    RoundedRectangleShape(cornerRadius: 4).fill(theme.editorColors.surfaceElevated)
                    if let image = thumbnails[item.id] {
                        image.resizable().scaledToFit()
                    } else if queued.first == item.id, let file = models[item.id], let revision = item.model {
                        EditorExternalAssetModelView(
                            file: file,
                            interactive: false,
                            capture: { image in saveThumbnail(image, item: item, revision: revision) },
                            onFailure: { advanceThumbnail(item.id) }
                        )
                        .id(revision)
                        .allowsHitTesting(false)
                    } else {
                        symbol("\u{E3F4}", size: 24)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: previewHeight, maxHeight: previewHeight)
                .mask(RoundedRectangleShape(cornerRadius: 4))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 3) {
                        Text(item.store.title).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(hasFile ? "GLB" : L10n.text("No file")).fixedSize()
                    }
                    .font(.system(size: 10))
                    .foregroundColor(theme.editorColors.muted)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 6)
            }
            .padding(5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(EditorExternalAssetCardStyle(theme: theme, selected: isSelected))
        .accessibilityIdentifier("studio.external-assets.item." + item.id.uuidString)
    }

    private func details(_ item: Item, width: Float) -> some View {
        let hasFile = models[item.id] != nil
        return VStack(alignment: .leading, spacing: 10) {
            Text(item.title).font(.system(size: 16, weight: .semibold))
            HStack {
                Text(item.store.title)
                Spacer()
                Text(hasFile ? "GLB" : L10n.text("No local file"))
            }
            .font(.system(size: 11))
            .foregroundColor(theme.editorColors.muted)
            if let file = models[item.id], let revision = item.model {
                EditorExternalAssetModelView(file: file, interactive: true)
                    .frame(height: min(310, max(222, (width - 24) * 0.85)))
                    .id(revision)
                action("Import into project", primary: true, fillsWidth: true) {
                    guard let destination = host.externalAssetDestination else {
                        return
                    }
                    perform {
                        _ = try await library.modelImport(listing: item.id, assets: destination)
                        try Task.checkCancellation()
                        guard host.externalAssets === library else {
                            return
                        }
                        try host.finishExternalAssetImport()
                        message = "Asset imported into the project."
                    }
                }
                .disabled(operation != nil)
            } else {
                if let image = thumbnails[item.id] {
                    image.resizable().scaledToFit().frame(height: 160)
                }
                action("Add local model", primary: true, fillsWidth: true) { attach(item, cover: false) }
                    .disabled(operation != nil)
            }
            action("Open in store", fillsWidth: true) { open(item.url) }
            RectangleShape().fill(theme.editorColors.border).frame(height: 1).allowsHitTesting(false)
            Button {
                showsLocalFiles.toggle()
                confirmRemoval = nil
            } label: {
                HStack(spacing: 6) {
                    Text(L10n.text("Local files")).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    symbol(showsLocalFiles ? "\u{E5CE}" : "\u{E5CF}", size: 15)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(EditorExternalAssetActionStyle(theme: theme, primary: false))
            .accessibilityIdentifier("studio.external-assets.local-files")
            if showsLocalFiles {
                localFileActions(item, hasFile: hasFile)
            }
        }
        .padding(12)
        .frame(width: width, alignment: .topLeading)
        .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surfaceElevated))
        .overlay { border(radius: 6) }
    }

    private func localFileActions(_ item: Item, hasFile: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if hasFile {
                action("Replace model", fillsWidth: true) { attach(item, cover: false) }.disabled(operation != nil)
            }
            action("Add cover image", fillsWidth: true) { attach(item, cover: true) }.disabled(operation != nil)
            if hasFile {
                if confirmRemoval == item.id {
                    Text(L10n.text("Remove the local model copy for \(item.title)?")).font(.system(size: 12))
                    action("Cancel", fillsWidth: true) { confirmRemoval = nil }
                }
                action("Remove local copy", fillsWidth: true) {
                    guard confirmRemoval == item.id else {
                        confirmRemoval = item.id
                        return
                    }
                    perform {
                        try await library.removeModel(listing: item.id)
                        confirmRemoval = nil
                    }
                }
                .disabled(operation != nil)
                .accessibilityIdentifier("studio.external-assets.remove-local")
            }
        }
    }

    private func action(
        _ title: String,
        primary: Bool = false,
        symbol glyph: String? = nil,
        fillsWidth: Bool = false,
        run: @escaping () -> Void
    ) -> some View {
        Button(action: run) {
            HStack(spacing: 6) {
                if let glyph { symbol(glyph, size: 15) }
                Text(L10n.tr(title)).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(EditorExternalAssetActionStyle(theme: theme, primary: primary))
    }

    private func field(_ key: String, placeholder: String = "", icon: String? = nil, identifier: String = "", value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            caption(key)
            HStack(spacing: 7) {
                if let icon { symbol(icon, size: 15).allowsHitTesting(false) }
                TextField(L10n.tr(placeholder), text: value)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 12))
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .accessibilityIdentifier(identifier)
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(RoundedRectangleShape(cornerRadius: 4).fill(theme.editorColors.surfaceElevated))
            .overlay { border(radius: 4) }
        }
    }

    private func caption(_ key: String) -> some View {
        Text(L10n.tr(key)).font(.system(size: 11, weight: .semibold)).foregroundColor(theme.editorColors.muted)
    }

    private func symbol(_ glyph: String, size: Double) -> some View {
        Text(glyph).font(AdaEditorMaterialSymbolFont.font(size: size)).foregroundColor(theme.editorColors.muted)
    }

    private func border(radius: Float) -> some View {
        RoundedRectangleShape(cornerRadius: radius).stroke(theme.editorColors.border, lineWidth: 1).allowsHitTesting(false)
    }

    private func open(_ url: URL) {
        if Application.shared?.openURL(url) != true { message = "Could not open the store." }
    }

    private func attach(_ item: Item, cover: Bool) {
        perform {
            guard let file = await EditorStudioPluginPicker.pick(
                title: cover ? "Add cover image" : "Add local model",
                extensions: cover ? ["png", "jpg", "jpeg"] : ["glb"]
            ) else {
                return
            }
            try Task.checkCancellation()
            guard host.externalAssets === library else {
                return
            }
            let finishAccess = EditorStudioPluginPicker.openAccess(file)
            defer { finishAccess() }
            try await library.attach(file, listing: item.id, cover: cover)
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard operation == nil else {
            return
        }
        operation = Task {
            message = nil
            defer { if !Task.isCancelled { operation = nil } }
            do {
                try await action()
                try Task.checkCancellation()
                refresh()
            } catch is CancellationError {
                return
            } catch { message = error.localizedDescription }
        }
    }

    private func refresh(recover: Bool = false) {
        loading?.cancel()
        loading = Task {
            do {
                if recover { try await library.reconcile() }
                let matches = try await library.search(query, store: Store(rawValue: source))
                var files: [UUID: URL] = [:]
                var images: [UUID: Image] = [:]
                var waiting: [UUID] = []
                for item in matches.dropFirst(start).prefix(24) {
                    try Task.checkCancellation()
                    files[item.id] = await library.modelURL(for: item)
                    if let cache = await library.thumbnailURL(for: item), let image = await library.image(at: cache) {
                        images[item.id] = image
                    } else {
                        if let cover = await library.coverURL(for: item) { images[item.id] = await library.image(at: cover) }
                        if files[item.id] != nil, images[item.id] == nil { waiting.append(item.id) }
                    }
                }
                try Task.checkCancellation()
                models = files
                thumbnails = images
                queued = waiting
                items = matches
                if let selected, !matches.contains(where: { $0.id == selected }) {
                    select(nil)
                }
            } catch is CancellationError {
                return
            } catch { message = error.localizedDescription }
        }
    }

    private func saveThumbnail(_ image: Image, item: Item, revision: UUID) {
        guard queued.first == item.id else {
            return
        }
        thumbnails[item.id] = image
        cacheWrite?.cancel()
        cacheWrite = Task {
            guard host.externalAssets === library, !Task.isCancelled else {
                return
            }
            try? await library.cacheThumbnail(image, listing: item.id, revision: revision)
            if !Task.isCancelled { advanceThumbnail(item.id) }
        }
    }

    private func advanceThumbnail(_ id: UUID) {
        if queued.first == id { queued.removeFirst() }
    }

    private func select(_ item: Item?) {
        selected = item?.id
        compactDetails = item != nil
        showsLocalFiles = false
        confirmRemoval = nil
    }

    private func changePage(by count: Int) {
        start += count
        select(nil)
        refresh()
    }
}

private struct EditorExternalAssetActionStyle: ButtonStyle {
    let theme: Theme
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        let colors = theme.editorColors
        let pressed = configuration.isPressed
        let hovered = configuration.isHighlighted
        let focused = configuration.state.contains(.focused)
        let shape = RoundedRectangleShape(cornerRadius: 4)
        let fill = primary ? colors.blue.opacity(pressed ? 0.8 : hovered ? 0.67 : 0.52)
            : pressed ? colors.border : hovered ? colors.border.opacity(0.74) : colors.surface
        return configuration.label
            .foregroundColor(colors.text)
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(shape.fill(fill))
            .overlay { shape.stroke(focused || primary ? colors.blue : colors.border, lineWidth: focused ? 2 : 1).allowsHitTesting(false) }
            .opacity(configuration.state.isEnabled ? 1 : 0.42)
    }
}

private struct EditorExternalAssetCardStyle: ButtonStyle {
    let theme: Theme
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        let colors = theme.editorColors
        let highlighted = configuration.isHighlighted || configuration.isPressed
        let focused = configuration.state.contains(.focused)
        let shape = RoundedRectangleShape(cornerRadius: 6)
        return configuration.label
            .background {
                shape.fill(colors.surface)
                    .overlay {
                        shape.fill(selected ? colors.blue.opacity(highlighted ? 0.24 : 0.13) : colors.text.opacity(highlighted ? 0.08 : 0))
                    }
            }
            .overlay { shape.stroke(selected || focused ? colors.blue : colors.border, lineWidth: focused ? 2 : 1).allowsHitTesting(false) }
    }
}

private struct EditorExternalAssetModelView: View {
    let file: URL
    let interactive: Bool
    var capture: ((Image) -> Void)?
    var onFailure: (() -> Void)?
    @State private var model = EditorModelAssetPreviewModel()
    @State private var camera = EditorModelPreviewCamera()
    @State private var delivered = false
    @State private var readback: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if model.asset != nil {
                    EditorModelPreviewViewport(model: model, camera: camera, isInteractive: interactive, onFrameRendered: capture == nil ? nil : completed)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if model.error != nil {
                    Text(L10n.text("Preview unavailable"))
                } else {
                    Text(L10n.text("Loading preview…"))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onAppear {
            camera.showsGrid = interactive
            camera.showsAxes = interactive
            model.load(path: file.path, resourceRoot: file.deletingLastPathComponent())
        }
        .onDisappear {
            model.cancel()
            readback?.cancel()
            readback = nil
        }
        .onChange(of: model.error) { _, error in if error != nil { onFailure?() } }
        .accessibilityIdentifier("studio.external-assets.model-preview")
    }

    private func completed(_ texture: Texture2D) {
        // The first frame can belong to the loading label's provisional layout.
        guard !delivered, readback == nil, texture.height >= 100 else {
            return
        }
        readback = Task {
            defer { if !Task.isCancelled { readback = nil } }
            do {
                let image = unsafe try await RenderEngine.shared.renderDevice.readImage(from: texture)
                try Task.checkCancellation()
                delivered = true
                if let image, !image.data.isEmpty {
                    capture?(image)
                } else {
                    onFailure?()
                }
            } catch is CancellationError {
                return
            } catch {
                delivered = true
                onFailure?()
            }
        }
    }
}
