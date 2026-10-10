#if os(iOS)
@_spi(AdaEngine) import AdaEngine
import Foundation

struct MobileEditorPublishScreen: View {
    @Environment(\.theme) private var theme
    @State private var draft: EditorPublicationDraft
    @State private var busy = false
    @State private var message = ""
    @State private var submitted = false
    let projectURL: URL
    let close: () -> Void
    private let account = EditorCloudAccount.shared

    init(projectURL: URL, title: String, close: @escaping () -> Void) {
        self.projectURL = projectURL
        self.close = close
        _draft = State(initialValue: EditorPublicationDraft.load(at: projectURL, title: title))
    }

    var body: some View {
        MobileEditorPageScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Publish").font(MobileEditorFont.navigationFont(size: 24))
                    Spacer()
                    Button("Close", action: close).disabled(busy)
                        .accessibilityIdentifier("AdaEditor.Mobile.Publish.Close")
                }
                detail("Submit your app to Community review. The current public app is updated after approval.")
                Text("Title").font(MobileEditorFont.font(size: 14))
                TextField("App title", text: Binding(get: { draft.title }, set: { draft.title = $0 }))
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(MobileEditorFont.font(size: 17))
                    .frame(height: 44)
                    .accessibilityIdentifier("AdaEditor.Mobile.Publish.Title")
                Text("Description").font(MobileEditorFont.font(size: 14))
                TextEditor(text: Binding(get: { draft.description }, set: { draft.description = $0 }), showsLineNumbers: false, showsScrollIndicators: true, wrapsLines: true)
                    .font(MobileEditorFont.font(size: 16))
                    .textEditorColors(TextEditorColors(
                        background: theme.editorColors.surface,
                        border: theme.editorColors.border,
                        focusedBorder: theme.editorColors.blue,
                        gutter: .clear,
                        gutterRule: .clear,
                        currentLineBackground: .clear,
                        selection: theme.editorColors.blue.opacity(0.24)
                    ))
                    .frame(height: 160)
                    .accessibilityIdentifier("AdaEditor.Mobile.Publish.Description")
                Text("Cover").font(MobileEditorFont.font(size: 14))
                if let cover = draft.cover { imageRow(cover, remove: { draft.cover = nil }) }
                Button(draft.cover == nil ? "Choose cover" : "Replace cover") { pickImages(cover: true) }
                    .frame(minHeight: 44).accessibilityIdentifier("AdaEditor.Mobile.Publish.Cover")
                Text("Screenshots (\(draft.screenshots.count)/5)").font(MobileEditorFont.font(size: 14))
                ForEach(draft.screenshots, id: \.absoluteString) { url in
                    imageRow(url, remove: { draft.screenshots.removeAll { $0 == url } })
                }
                Button("Add screenshots") { pickImages(cover: false) }
                    .frame(minHeight: 44).disabled(draft.screenshots.count >= 5)
                    .accessibilityIdentifier("AdaEditor.Mobile.Publish.Screenshots")
                if account.accountID == nil {
                    MobileEditorPrimaryButton(title: "Sign in to Ada Cloud") {
                        run { try await account.signInOnWebsite() }
                    }
                } else {
                    detail("Community publishing requires Cloud Pro.")
                    if !account.pro {
                        Button("Refresh Cloud plan") { run { try await account.refreshPlan() } }.frame(minHeight: 44)
                        Button("Get Cloud Pro") { run { try await account.buyPro() } }.frame(minHeight: 44)
                    }
                    MobileEditorPrimaryButton(title: busy ? "Submitting…" : "Submit for review") { publish() }
                        .disabled((try? draft.validate()) == nil || submitted || !account.pro)
                        .accessibilityIdentifier("AdaEditor.Mobile.Publish.Submit")
                }
                if !message.isEmpty {
                    detail(message).accessibilityIdentifier("AdaEditor.Mobile.Publish.Status")
                }
            }
            .foregroundColor(theme.editorColors.text)
            .padding(22)
            .disabled(busy)
        }
        .background(theme.editorColors.background.ignoresSafeArea())
        .onChange(of: draft.title) { _, _ in submitted = false }
        .onChange(of: draft.description) { _, _ in submitted = false }
        .onChange(of: draft.cover) { _, _ in submitted = false }
        .onChange(of: draft.screenshots) { _, _ in submitted = false }
        .onDisappear { try? draft.save(at: projectURL) }
    }

    private func detail(_ value: String) -> some View {
        Text(value).font(MobileEditorFont.font(size: 13)).foregroundColor(theme.editorColors.muted)
    }

    private func imageRow(_ url: URL, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            if let image = try? Image(contentsOf: url) {
                image.resizable().scaledToFit().frame(width: 100, height: 75)
            }
            detail(url.lastPathComponent).lineLimit(2)
            Spacer()
            Button("Remove", action: remove).frame(minHeight: 44)
        }
    }

    private func pickImages(cover: Bool) {
        ProjectOpenPicker.presentAgentPhotoPicker { result in
            guard case .selected(let urls) = result else {
                if case .unavailable(let error) = result { message = error }
                return
            }
            do {
                let folder = projectURL.appendingPathComponent(".ada/publication-images")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let selected = cover ? Array(urls.prefix(1)) : Array(urls.prefix(max(0, 5 - draft.screenshots.count)))
                let copied = try selected.map { url -> URL in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 0, size <= 5_000_000 else { throw EditorPublicationError("Choose images up to 5 MB each.") }
                    let destination = folder.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
                    try FileManager.default.copyItem(at: url, to: destination)
                    return destination
                }
                if cover { draft.cover = copied.first } else { draft.screenshots += copied }
                try draft.save(at: projectURL)
            } catch { message = error.localizedDescription }
        }
    }

    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else {
            return
        }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await action() } catch { message = error.localizedDescription }
        }
    }

    private func publish() {
        guard let owner = account.accountID else {
            return
        }
        let origin = account.server, submission = draft
        message = "Preparing app and uploading images…"
        run {
            let release = try await EditorProjectPublisher.shared.submit(projectURL: projectURL, draft: submission, owner: owner, server: origin)
            submitted = true
            message = release["status"].string == "approved"
                ? "Version \(release["number"].int ?? 1) is already approved."
                : "Version \(release["number"].int ?? 1) submitted for review."
        }
    }
}
#endif
