@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) @testable import AdaRender
import AdaScriptCompilerCore
import AdaTilemap
@_spi(Internal) import AdaUI
import AdaUtils
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor
@Suite(.serialized)
struct EditorFileTemplateMenuTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            let app = AppWorlds(main: World(name: "EditorFileTemplateMenuTests"))
            RenderWorldPlugin().setup(in: app)
        }
    }

    @Test("tree context menu creates every template beside the clicked file")
    func contextMenuCreatesTemplates() async throws {
        let root = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeViewModel(root: root)
        let container = makeSidebar(model)
        var presentation: ContextMenuPresentation?
        let previousPresenter = ContextMenuPresentationCenter.present
        ContextMenuPresentationCenter.present = { presentation = $0 }
        defer { ContextMenuPresentationCenter.present = previousPresenter }

        for kind in EditorNewFileKind.allCases {
            let row = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.Existing.swift"))
            container.onMouseEvent(
                MouseEvent(
                    window: RID(),
                    button: .right,
                    mousePosition: Point(row.absoluteFrame.midX, row.absoluteFrame.midY),
                    phase: .began,
                    modifierKeys: [],
                    time: 0
                )
            )
            let menu = try #require(presentation?.items.first)
            #expect(menu.title == "New…")
            let openPicker = try #require(menu.action)
            openPicker()
            #expect(!model.isNewFileKindPreselected)
            let picker = makeDialog(model)
            _ = try picker.uiScrollToNode(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.New.\(kind.rawValue)"))
            picker.layoutIfNeeded()
            _ = try picker.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.New.\(kind.rawValue)"))
            #expect(model.isNewFileKindPreselected)
            #expect(model.newFileKind == kind)
            #expect(model.newFileDestinationRelativePath == "Sources/Game")
            model.newFileName = "Created-\(kind.rawValue)"
            let expectedPath = "Sources/Game/Created-\(kind.rawValue).\(kind.fileExtension)"
            #expect(model.newFilePreviewPath == expectedPath)
            #expect(model.createNewFile())
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(expectedPath).path))
            #expect(model.workbench.activeDocument?.relativePath == expectedPath)
            container.layoutIfNeeded()
        }

        let background = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.Background"))
        container.onMouseEvent(
            MouseEvent(
                window: RID(),
                button: .right,
                mousePosition: Point(background.absoluteFrame.minX + 5, background.absoluteFrame.maxY - 5),
                phase: .began,
                modifierKeys: [],
                time: 1
            )
        )
        let action = try #require(presentation?.items.first?.action)
        action()
        #expect(model.newFileDestinationRelativePath.isEmpty)
        model.newFileKind = .scene
        model.newFileName = "RootScene"
        #expect(model.createNewFile())
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("RootScene.ascn").path))
    }

    @Test("New button offers templates before opening the name dialog")
    func toolbarSelectsTemplateAndDismissesMenu() async throws {
        let root = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeViewModel(root: root)
        let folder = try #require(model.projectSidebar.items.first { $0.relativePath == "Sources/Game" })
        model.projectSidebar.select(folder)
        let container = makeSidebar(model)

        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.NewFile"))
        container.layoutIfNeeded()
        #expect(model.isNewFileDialogPresented)
        #expect(!model.isNewFileKindPreselected)
        let dialog = makeDialog(model)
        for group in EditorNewFileGroup.allCases {
            _ = try dialog.uiNode(matching: .accessibilityIdentifier("AdaEditor.NewFile.Group.\(group.rawValue)"))
        }
        _ = try dialog.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.New.script"))
        for _ in 0..<10 {
            await Task.yield()
            dialog.layoutIfNeeded()
        }
        #expect(model.newFileKind == .script)
        #expect(model.newFileDestinationRelativePath == "Sources/Game")
        #expect(model.isNewFileKindPreselected)
        #expect(dialog.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.New.Menu")).isEmpty)
        _ = try dialog.uiNode(matching: .accessibilityIdentifier("AdaEditor.NewFile.Name"))
        model.newFileName = "Movement"
        try await waitForPreview(in: dialog)
        _ = try dialog.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.NewFile.Create"))
        #expect(!model.isNewFileDialogPresented)
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Game/Movement.ada"), encoding: .utf8)
        #expect(source.contains("class MovementSystem"))
        model.presentNewFileDialog()
        #expect(!model.isNewFileKindPreselected)
        let reopenedDialog = UIContainerView(rootView: EditorNewFileDialog(viewModel: model))
        reopenedDialog.frame = dialog.frame
        reopenedDialog.bounds.size = dialog.bounds.size
        reopenedDialog.layoutIfNeeded()
        #expect(!reopenedDialog.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.New.scene")).isEmpty)
        reopenedDialog.onKeyEvent(KeyEvent(window: .empty, keyCode: .escape, modifiers: [], status: .down, time: 0, isRepeated: false))
        #expect(!model.isNewFileDialogPresented)

        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.NewFile"))
        container.layoutIfNeeded()
        let dismissDialog = makeDialog(model)
        _ = try dismissDialog.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.NewFile.Cancel"))
        #expect(!model.isNewFileDialogPresented)
    }

    @Test("search filters the grouped catalog through text input")
    func searchesCatalog() async throws {
        var selected: EditorNewFileKind?
        let container = UIContainerView(rootView: EditorNewFileMenu { selected = $0 })
        container.frame = Rect(x: 0, y: 0, width: 756, height: 380)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.NewFile.Search"))
        container.onTextInputEvent(TextInputEvent(window: .empty, text: "localization", action: .insert, time: 0))
        for _ in 0..<10 {
            await Task.yield()
            container.layoutIfNeeded()
        }
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.New.script")).isEmpty)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.New.localization"))
        #expect(selected == .localization)
    }

    @Test("catalog fits narrow and wide windows", arguments: [Float(375), 768, 1440])
    func adaptivePicker(width: Float) throws {
        let root = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeViewModel(root: root)
        model.presentNewFileDialog()
        let container = makeDialog(model, width: width)
        let picker = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.NewFile.Picker")).absoluteFrame
        #expect(picker.minX >= 0 && picker.maxX <= width)
        for kind in EditorNewFileKind.allCases {
            let node = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ProjectTree.New.\(kind.rawValue)"))
            #expect(node.absoluteFrame.minX >= picker.minX)
            #expect(node.absoluteFrame.maxX <= picker.maxX)
        }
    }

    @Test("Resource templates open in the atlas editor and load as a runtime tile set")
    func resourceTemplatesLoad() async throws {
        let root = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = makeViewModel(root: root)
        for kind in [EditorNewFileKind.atlas, .tileSource] {
            #expect(kind.group == .resources)
            model.presentNewFileDialog(kind: kind)
            model.newFileName = "Resource-\(kind.rawValue)"
            #expect(model.createNewFile())
            let document = try #require(model.workbench.activeDocument)
            let path = try #require(document.absolutePath)
            if kind == .atlas {
                guard case let .asset(asset) = document else {
                    Issue.record("Atlas should open as an editable asset")
                    continue
                }
                #expect(asset.kind == .atlas)
                let editor = EditorTextureAtlasEditorModel(document: asset)
                #expect(editor.isEditable)
                #expect(editor.descriptor.images.isEmpty)
            } else {
                guard case let .asset(asset) = document else {
                    Issue.record("Tile set should open in its visual editor")
                    continue
                }
                #expect(asset.kind == .tileSource)
                #expect(EditorTileSourceEditorModel(document: asset).isEditable)
                let handle = try await AssetsManager.load(TileSet.self, at: path)
                let tiles = try #require(handle.asset)
                #expect(tiles.tileSize == PointInt(x: 16, y: 16))
                #expect(tiles.sources.isEmpty)
            }
        }
    }

    @Test("AdaScript templates compile and UI Script builds native views")
    func scriptTemplatesCompile() throws {
        for kind in EditorNewFileGroup.adaScript.templates {
            let source = kind.initialContent(fileName: "Template.ada")
            _ = try AdaScriptSchemaParser.parse(sources: [.init(path: "Template.ada", source: source)])
            if kind == .scriptableObject {
                #expect(source.contains("func update(context: AdaScriptableContext)"))
            } else if kind == .script {
                #expect(source.contains("func update(context: AdaSystemContext)"))
            }
        }
        _ = try AdaScriptPlugin(
            sources: [
                .init(path: "System.ada", source: EditorNewFileKind.script.initialContent(fileName: "Template.ada")),
                .init(path: "Empty.ada", source: EditorNewFileKind.emptyScript.initialContent(fileName: "Empty.ada")),
            ],
            name: "TemplateModule"
        )
        let objectSource = AdaScriptSource(path: "TemplateObject.ada", source: EditorNewFileKind.scriptableObject.initialContent(fileName: "TemplateObject.ada"))
        let schema = try #require(AdaScriptSchemaParser.parseScriptables(sources: [objectSource]).first)
        try AdaScriptObjectRegistration.register(
            schemas: [.init(identifier: schema.id, className: schema.name, version: schema.version, aliases: schema.aliases, fields: [:])],
            sources: [objectSource],
            moduleName: "TemplateObjects"
        )
        _ = try ScriptableObjectRegistry.make(named: schema.id)
        let view = try AdaScriptView(sources: [.init(path: "Template.ada", source: EditorNewFileKind.uiScript.initialContent(fileName: "Template.ada"))], identifier: "TemplateView")
        let container = UIContainerView(rootView: view)
        container.frame = Rect(x: 0, y: 0, width: 300, height: 200)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        #expect(!container.uiTreeRoots().isEmpty)
    }

    @Test("shader templates compile to SPIR-V")
    func shaderTemplatesCompile() throws {
        for (kind, stage) in [(EditorNewFileKind.vertexShader, ShaderStage.vertex), (.fragmentShader, .fragment), (.computeShader, .compute)] {
            let source = try ShaderSource(source: kind.initialContent(fileName: "Template.glsl"))
            let result = try ShaderCompiler(shaderSource: source).compileSpirvBin(for: stage, ignoreCache: true)
            #expect(!result.data.isEmpty)
        }
    }

    @Test("localization template resolves from a real language bundle")
    func localizedTemplateResolves() throws {
        let root = try makeProjectDirectory().appendingPathComponent("Translations.bundle")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let language = root.appendingPathComponent("en.lproj")
        try FileManager.default.createDirectory(at: language, withIntermediateDirectories: true)
        try EditorNewFileKind.localization.initialContent(fileName: "Localizable.strings")
            .write(to: language.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        let bundle = try #require(Bundle(path: root.path))
        #expect(LocalizedStringKey("hello", bundle: bundle).resolve() == "Hello")
    }

    private func makeDialog(_ model: EditorViewModel, width: Float = 900) -> UIContainerView<EditorNewFileDialog> {
        let container = UIContainerView(rootView: EditorNewFileDialog(viewModel: model))
        container.frame = Rect(x: 0, y: 0, width: width, height: 700)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        return container
    }

    private func waitForPreview<Content: View>(in dialog: UIContainerView<Content>) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let preview = UINodeSelector.accessibilityIdentifier("AdaEditor.NewFile.Preview")
        while ContinuousClock.now < deadline {
            dialog.update(1.0 / 60.0)
            dialog.layoutIfNeeded()
            if !dialog.uiFindNodes(matching: preview).isEmpty {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!dialog.uiFindNodes(matching: preview).isEmpty, "The dialog should reflect the entered file name")
    }

    private func makeViewModel(root: URL) -> EditorViewModel {
        EditorViewModel(
            project: EditorProjectReference(name: "Templates", path: root.path),
            sourceControlService: GitRepositoryService(processRunner: TemplateMenuGitRunner())
        )
    }

    private func makeSidebar(_ model: EditorViewModel) -> UIContainerView<some View> {
        let container = UIContainerView(
            rootView: EditorProjectSidebar(
                viewModel: model.projectSidebar,
                projectRootItem: model.projectRootSidebarItem,
                onOpenItem: { model.openProjectItem($0) },
                onOpenRawItem: { model.openProjectItemAsRaw($0) },
                onNewFile: { model.presentNewFileDialog(kind: $0) },
                onImportAssets: {},
                onDropFiles: { model.importDroppedFiles(from: $0) },
                onRevealItem: { _ in },
                onOpenInDefaultApplication: { _ in },
                onOpenInTerminal: { _ in },
                onFindInFolder: { _ in },
                onFindInProjectRoot: {},
                onCopyPath: { _, _ in },
                onDeleteItem: { _ in }
            )
        )
        container.frame = Rect(x: 0, y: 0, width: 320, height: 600)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        return container
    }

    private func makeProjectDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TemplateMenu-\(UUID().uuidString)")
        let sources = root.appendingPathComponent("Sources/Game")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try "import AdaEngine\n".write(to: sources.appendingPathComponent("Existing.swift"), atomically: true, encoding: .utf8)
        return root
    }
}

// These filesystem/UI fixtures have no Git repository; avoid unrelated background processes.
private struct TemplateMenuGitRunner: EditorProcessRunning {
    func run(_ command: EditorProcessCommand) async -> EditorProcessResult {
        EditorProcessResult(command: command, exitCode: 128, standardOutput: "", standardError: "Not a git repository")
    }

    func cancelAll() async {}
}
