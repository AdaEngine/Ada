@_spi(AdaEngine) import AdaEngine
import AdaScriptCompilerCore
import Foundation
import Observation

@MainActor
@Observable
final class EditorLibrariesViewModel {
    var repository = ""
    var revision = ""
    var status = ""
    var isWorking = false
    var lock = AdaScriptLibraryLock()
    private var projectURL: URL?
    private var onChange: (@MainActor (URL) -> Void)?
    private let manager: EditorAdaScriptLibraryManager

    init(manager: EditorAdaScriptLibraryManager = .shared) {
        self.manager = manager
    }

    func load(for editorViewModel: EditorViewModel?) {
        load(at: editorViewModel?.projectURL)
        onChange = { [weak editorViewModel] projectURL in
            guard let editorViewModel, editorViewModel.projectURL == projectURL else {
                return
            }
            editorViewModel.reloadScriptableObjectSupport()
        }
    }

    func load(at url: URL?) {
        projectURL = url
        do {
            lock = try url.map { try AdaScriptLibraryLock.load(at: $0) } ?? AdaScriptLibraryLock()
            status = ""
        } catch {
            lock = AdaScriptLibraryLock()
            status = error.localizedDescription
        }
    }

    func install() async {
        await perform {
            let source = try GitHubAdaScriptLibraryProvider.source(repository: self.repository, revision: self.revision)
            return try await self.manager.install(source, at: $0)
        }
    }

    func remove(_ id: String) async {
        await perform { try await self.manager.remove(id, at: $0) }
    }

    func restore() async {
        await perform { try await self.manager.restore(at: $0) }
    }

    private func perform(_ operation: @MainActor (URL) async throws -> AdaScriptLibraryLock) async {
        guard !isWorking, let projectURL else {
            return
        }
        isWorking = true
        status = "Updating libraries…"
        defer { isWorking = false }
        do {
            let updated = try await operation(projectURL)
            guard self.projectURL == projectURL else {
                return
            }
            lock = updated
            status = "Libraries saved. Rebuild or restart Play to apply."
            onChange?(projectURL)
        } catch {
            if self.projectURL == projectURL {
                status = error.localizedDescription
            }
        }
    }
}

struct EditorLibrariesView: View {
    let viewModel: EditorLibrariesViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ADASCRIPT LIBRARIES")
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.blue)
            Divider()
            Text("Install a public GitHub library using a tag or commit. Dependencies are pinned automatically.")
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
            installControls
            installedLibraries
            if !viewModel.status.isEmpty {
                Text(viewModel.status)
                    .font(.system(size: 11))
                    .accessibilityIdentifier("AdaEditor.Libraries.Status")
            }
        }
    }

    private var installControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            libraryField(
                "owner/repository or GitHub URL",
                text: Binding(
                    get: { viewModel.repository },
                    set: { viewModel.repository = $0 }
                )
            )
            .accessibilityIdentifier("AdaEditor.Libraries.Repository")
            libraryField(
                "Tag or commit (e.g. v1.0.0)",
                text: Binding(
                    get: { viewModel.revision },
                    set: { viewModel.revision = $0 }
                )
            )
            .accessibilityIdentifier("AdaEditor.Libraries.Revision")
            VStack(alignment: .leading, spacing: 8) {
                Button("Install / Update") { Task { await viewModel.install() } }
                    .accessibilityIdentifier("AdaEditor.Libraries.Install")
                Button("Restore Locked Libraries") { Task { await viewModel.restore() } }
                    .accessibilityIdentifier("AdaEditor.Libraries.Restore")
            }
            .font(.system(size: 12))
            .buttonStyle(DefaultButtonStyle())
            .disabled(viewModel.isWorking)
        }
    }

    private var installedLibraries: some View {
        ForEach(viewModel.lock.libraries, id: \.manifest.id) { library in
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(library.manifest.id) · \(library.manifest.version)")
                        .font(.system(size: 12))
                    Text("\(library.source.location) @ \(String(library.source.revision.prefix(12)))")
                        .font(.system(size: 11))
                        .foregroundColor(theme.editorColors.muted)
                }
                Spacer()
                if viewModel.lock.roots.contains(library.manifest.id) {
                    Button("Remove") { Task { await viewModel.remove(library.manifest.id) } }
                        .disabled(viewModel.isWorking)
                } else {
                    Text("Dependency").font(.system(size: 11))
                }
            }
        }
    }

    private func libraryField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 12))
            .foregroundColor(theme.editorColors.text)
            .padding(.horizontal, 10)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 34, maxHeight: 34)
            .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface))
            .overlay {
                RoundedRectangleShape(cornerRadius: 6).stroke(theme.editorColors.border, lineWidth: 1)
            }
            .textFieldStyle(PlainTextFieldStyle())
    }
}
