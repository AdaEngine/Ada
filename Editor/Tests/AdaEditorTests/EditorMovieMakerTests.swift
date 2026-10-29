@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Editor Movie Maker settings", .serialized)
struct EditorMovieMakerTests {
    @Test func settingsPersistPerProjectAndResolveRelativePaths() throws {
        let root = try movieEditorFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = EditorMovieMakerSettings()
        settings.framesPerSecond = "30"
        settings.duration = "1,25"
        settings.outputPath = "Movies/First Take.png"
        try settings.save(in: root)
        let restored = try EditorMovieMakerSettings.load(in: root)
        #expect(restored == settings)
        let config = try restored.configuration(in: root)
        #expect(config.outputURL == root.appendingPathComponent("Movies/First Take.png"))
        #expect(config.frameCount == 38)
        let model = EditorMovieMakerModel(projectURL: root)
        #expect(model.settings == settings && model.validationMessage == nil)
    }

    @Test(arguments: [
        ("framesPerSecond", "0"), ("framesPerSecond", "59"), ("framesPerSecond", "text"),
        ("width", "0"), ("height", "8193"), ("duration", "-1"), ("duration", "nan"),
        ("duration", "1e100"), ("outputPath", "clip.mp4"), ("outputPath", "")
    ])
    func rejectsInvalidSettings(field: String, value: String) {
        var settings = EditorMovieMakerSettings()
        switch field {
        case "framesPerSecond": settings.framesPerSecond = value
        case "width": settings.width = value
        case "height": settings.height = value
        case "duration": settings.duration = value
        default: settings.outputPath = value
        }
        #expect(throws: EditorMovieMakerError.self) {
            try settings.configuration(in: FileManager.default.temporaryDirectory)
        }
    }

    @Test func toolbarOpensMovieSettings() async throws {
        prepareMovieEditorUI()
        let root = try movieEditorFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = EditorMovieMakerModel(projectURL: root)
        let toolbar = EditorTopToolbar(
            project: EditorProjectReference(name: "Movie", path: root.path), isProjectSwitcherPresented: false,
            isRunDestinationMenuPresented: false, viewModel: EditorToolbarViewModel(), runDestination: .windows,
            isRunEnabled: true, isStopEnabled: false, onToggleRunDestinationMenu: {}, onToggleProjectSwitcher: {},
            onRun: {}, onStop: {}, movieMaker: model, onMovieMaker: { model.isPresented = true }
        )
        let container = UIContainerView(rootView: toolbar.theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 1200, height: 50)
        container.bounds.size = container.frame.size
        await settleMovieUI(container)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Toolbar.MovieMaker"))
        #expect(model.isPresented)
    }
}

@MainActor
extension EditorLocalizationTests {
    @Test("Movie settings stay editable and fit the mounted dialog in both languages")
    func movieMakerDialog() async throws {
        prepareMovieEditorUI()
        let root = try movieEditorFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let previous = EditorLocalization.shared.preference
        defer { EditorLocalization.shared.preference = previous }
        let model = EditorMovieMakerModel(projectURL: root)
        var starts = 0
        let dialog = EditorMovieMakerDialog(model: model, canStart: true, onStart: { starts += 1 }, onBrowse: {}, onClose: {}, onReveal: {})
        let container = UIContainerView(rootView: dialog.theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 700, height: 760)
        container.bounds.size = container.frame.size
        await settleMovieUI(container)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.MovieMaker.Resolution.720p"))
        #expect(model.settings.width == "1280" && model.settings.height == "720")
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.MovieMaker.FPS"))
        #expect(container.uiPerformTextEditingCommand(.selectAll))
        for character in ["2", "4"] {
            container.onTextInputEvent(.init(window: .empty, text: character, action: .insert, time: 0))
            await settleMovieUI(container)
        }
        #expect(model.settings.framesPerSecond == "24")
        for language in [EditorLanguage.english, .russian] {
            EditorLocalization.shared.preference = language
            await settleMovieUI(container)
            for id in ["FPS", "Width", "Height", "Duration", "Path", "Start", "Close", "Browse"] {
                let node = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.MovieMaker.\(id)"))
                #expect(node.absoluteFrame.minX >= 0 && node.absoluteFrame.maxX <= 700)
                #expect(node.absoluteFrame.width > 0 && node.absoluteFrame.maxY <= 760)
            }
            #expect(model.settings.framesPerSecond == "24")
        }
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.MovieMaker.Start"))
        #expect(starts == 1)
    }
}

@MainActor
private func prepareMovieEditorUI() {
    if unsafe RenderEngine.shared == nil {
        unsafe RenderEngine.configurations.preferredBackend = .headless
        RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "MovieEditorUI")))
    }
}

@MainActor
private func settleMovieUI<Content: View>(_ container: UIContainerView<Content>) async {
    for _ in 0..<10 { await Task.yield(); container.update(1 / 60); container.layoutIfNeeded() }
}

func movieEditorFixtureDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Movie Editor \(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
