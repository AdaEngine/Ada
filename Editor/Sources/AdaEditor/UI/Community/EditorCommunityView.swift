@_spi(AdaEngine) import AdaEngine
import Foundation

/// Shared AdaUI discovery and navigation. Browser launching is an injected platform action.
struct EditorCommunityView: View {
    @Environment(\.theme) private var theme
    @State private var model: EditorCommunityModel
    @State private var path = NavigationPath()
    let openGame: @MainActor @Sendable (URL) -> Bool

    init(
        client: EditorCommunityClient,
        openGame: @escaping @MainActor @Sendable (URL) -> Bool = { Application.shared?.openURL($0) ?? false }
    ) {
        self._model = State(wrappedValue: EditorCommunityModel(client: client))
        self.openGame = openGame
    }

    init(model: EditorCommunityModel, openGame: @escaping @MainActor @Sendable (URL) -> Bool = { _ in false }) {
        self._model = State(wrappedValue: model)
        self.openGame = openGame
    }

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geometry in
                let width = min(1000, geometry.size.width)
                catalog(width: width, columns: width >= 700 ? 2 : 1)
            }
            .navigationTitle("Community")
            .navigationTitleFont(AdaEditorTitleFont.font(size: 24))
            .navigationTitlePosition(.leading)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarColor(theme.editorColors.background)
            .navigationBarTrailingItems {
                Button { Task { @MainActor in await model.reload() } } label: {
                    Text("\u{E863}")
                        .font(AdaEditorMaterialSymbolFont.font(size: 24))
                        .foregroundColor(theme.editorColors.text)
                        .frame(width: 44, height: 44)
                }
                .disabled(model.loading)
                .accessibilityIdentifier("AdaEditor.Community.Refresh")
            }
            .navigate(for: EditorCommunityGame.self) { game in
                EditorCommunityDetailView(game: game, client: model.client, openGame: openGame)
            }
        }
        .background(theme.editorColors.background.ignoresSafeArea())
        .task { await model.reload() }
    }

    private func catalog(width: Float, columns: Int) -> some View {
        let rows = rows(columns: columns)
        let cardWidth = max(0, (width - 44 - Float(columns - 1) * 18) / Float(columns))
        return MobileEditorPageScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Discover worlds")
                        .font(AdaEditorTitleFont.font(size: 32))
                        .foregroundColor(theme.editorColors.text)
                    Text("Games created by the community.")
                        .font(.system(size: 15))
                        .foregroundColor(theme.editorColors.muted)
                }
                TextField("Search worlds and tags", text: Binding(get: { model.query }, set: { model.query = $0 }))
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 15))
                    .foregroundColor(theme.editorColors.text)
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangleShape(cornerRadius: 14).fill(theme.editorColors.surface))
                    .accessibilityIdentifier("AdaEditor.Community.Search")
                HStack(spacing: 10) {
                    sortButton("Recently added", popular: false)
                    sortButton("Most liked", popular: true)
                }
                if model.loading && model.games.isEmpty {
                    status("Loading worlds…", detail: "Connecting to the community.")
                } else if let error = model.error {
                    status("Couldn’t load the community", detail: error)
                    Button("Try again") { Task { @MainActor in await model.reload() } }
                        .font(.system(size: 16))
                        .foregroundColor(theme.editorColors.blue)
                        .disabled(model.loading)
                        .accessibilityIdentifier("AdaEditor.Community.Retry")
                } else if model.results.isEmpty {
                    status(
                        model.games.isEmpty ? "New worlds are on their way" : "No worlds found",
                        detail: model.games.isEmpty ? "Published games from the community will appear here." : "Try another name or tag."
                    )
                }
                LazyVStack(rows.indices, id: \.self, alignment: .leading, spacing: 22, estimatedRowHeight: 320) { row in
                    HStack(alignment: .top, spacing: 18) {
                        ForEach(rows[row]) { game in
                            gameCard(game).frame(width: cardWidth)
                        }
                        if rows[row].count < columns { Spacer() }
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 120)
            .frame(width: width)
            .frame(maxWidth: .infinity)
        }
        .background(theme.editorColors.background)
    }

    private func rows(columns: Int) -> [[EditorCommunityGame]] {
        let games = model.results
        return stride(from: 0, to: games.count, by: columns).map {
            Array(games[$0..<min(games.count, $0 + columns)])
        }
    }

    private func sortButton(_ title: String, popular: Bool) -> some View {
        Button { model.popularFirst = popular } label: {
            Text(title)
                .font(.system(size: 13))
                .foregroundColor(model.popularFirst == popular ? theme.editorColors.text : theme.editorColors.muted)
                .frame(height: 40)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangleShape(cornerRadius: 12).fill(model.popularFirst == popular ? theme.editorColors.surface : theme.editorColors.background))
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier(popular ? "AdaEditor.Community.Sort.Popular" : "AdaEditor.Community.Sort.Recent")
    }

    private func status(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 20)).foregroundColor(theme.editorColors.text)
            Text(detail).font(.system(size: 14)).foregroundColor(theme.editorColors.muted).lineLimit(4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
        .accessibilityIdentifier("AdaEditor.Community.Status")
    }

    private func gameCard(_ game: EditorCommunityGame) -> some View {
        Button { path.append(game) } label: {
            VStack(alignment: .leading, spacing: 14) {
                EditorCommunityArtwork(url: game.coverURL, height: 180)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(game.title).font(.system(size: 20)).foregroundColor(theme.editorColors.text).lineLimit(2)
                        Text(game.description).font(.system(size: 13)).foregroundColor(theme.editorColors.muted).lineLimit(2)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    Text("\u{E5CC}").font(AdaEditorMaterialSymbolFont.font(size: 20)).foregroundColor(theme.editorColors.purple)
                }
                HStack {
                    Text(game.tags.prefix(3).joined(separator: " · ")).lineLimit(1)
                    Spacer()
                    Text("\(game.likes) likes")
                }
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.muted)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangleShape(cornerRadius: 18).fill(theme.editorColors.surface))
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.Community.Game.\(game.id)")
    }
}

struct EditorCommunityDetailView: View {
    @Environment(\.theme) private var theme
    @State private var checking = false
    @State private var error: String?
    @State private var openingTask: Task<Void, Never>?
    let game: EditorCommunityGame
    let client: EditorCommunityClient
    let openGame: @MainActor @Sendable (URL) -> Bool

    var body: some View {
        MobileEditorPageScrollView {
            VStack(alignment: .leading, spacing: 22) {
                EditorCommunityArtwork(url: game.coverURL, height: 240)
                Text(game.title).font(AdaEditorTitleFont.font(size: 32)).foregroundColor(theme.editorColors.text).lineLimit(3)
                Text("Community creation · \(game.likes) likes").font(.system(size: 14)).foregroundColor(theme.editorColors.muted)
                Button(action: play) {
                    Text(checking ? "Checking availability…" : "Play in browser")
                        .font(.system(size: 17))
                        .foregroundColor(.white)
                        .frame(height: 52)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangleShape(cornerRadius: 14).fill(theme.editorColors.blue))
                }
                .buttonStyle(DefaultButtonStyle())
                .disabled(checking)
                .accessibilityIdentifier("AdaEditor.Community.Play")
                if let error {
                    Text(error).font(.system(size: 14)).foregroundColor(theme.editorColors.muted).lineLimit(4)
                        .accessibilityIdentifier("AdaEditor.Community.PlayError")
                }
                Text("About this world").font(.system(size: 22)).foregroundColor(theme.editorColors.text)
                Text(game.description).font(.system(size: 16)).foregroundColor(theme.editorColors.text)
                if !game.tags.isEmpty {
                    Text(game.tags.joined(separator: " · ")).font(.system(size: 13)).foregroundColor(theme.editorColors.purple).lineLimit(3)
                }
                if !game.screenshotURLs.isEmpty {
                    Text("Screenshots").font(.system(size: 22)).foregroundColor(theme.editorColors.text)
                    ForEach(game.screenshotURLs.indices, id: \.self) { index in
                        EditorCommunityArtwork(url: game.screenshotURLs[index], height: 200)
                    }
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(theme.editorColors.background)
        .navigationTitle(game.title)
        .navigationTitleFont(AdaEditorTitleFont.font(size: 18))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarColor(theme.editorColors.background)
        .accessibilityIdentifier("AdaEditor.Community.Detail")
        .onDisappear { openingTask?.cancel() }
    }

    private func play() {
        guard !checking else { return }
        checking = true
        openingTask = Task { @MainActor in
            defer { checking = false }
            do {
                let current = try await client.game(id: game.id)
                try Task.checkCancellation()
                error = openGame(current.playURL) ? nil : "Could not open this world in your browser."
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
