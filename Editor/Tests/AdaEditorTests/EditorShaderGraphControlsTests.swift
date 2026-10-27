@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@MainActor @Suite("Shader Graph controls", .serialized)
struct EditorShaderGraphControlsTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World()))
        }
    }

    @Test func dropdownKeepsItsSymbolFontInsideInspectorTextStyles() {
        let root = UIContainerView(rootView: EditorEnumField(cases: ["Constant"], selection: .constant("Constant"))
            .font(.system(size: 12)).theme(.adaEditor))
        root.frame = Rect(x: 0, y: 0, width: 300, height: 30)
        root.bounds.size = root.frame.size
        root.layoutIfNeeded()
        let context = UIGraphicsContext()
        root.viewTree.rootNode.draw(with: context)
        let fonts = context.getDrawCommands().flatMap { command -> [Font] in
            switch command {
            case let .drawGlyph(glyph, _, _): return [glyph.attributes.font]
            case let .drawText(layout, _, _): return layout.textLines.flatMap { $0.flatMap { $0.map { $0.attributes.font } } }
            default: return []
            }
        }
        #expect(AdaEditorMaterialSymbolFont.font(size: 16) != Font.system(size: 16))
        #expect(fonts.contains(AdaEditorMaterialSymbolFont.font(size: 16)))
    }

    @Test func colorChannelsEditIndependentlyRetainFractionalDraftsAndPersist() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GraphControls-\(UUID()).shadergraph")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(EditorShaderGraphTemplates.initialContent(target: .pbrSurface).utf8).write(to: url)
        let model = EditorShaderGraphModel(url: url)
        let node = try #require(model.graph?.nodes.first { $0.id == "tint" })
        let root = UIContainerView(rootView: EditorShaderGraphValueEditor(model: model, node: node).theme(.adaEditor))
        root.frame = Rect(x: 0, y: 0, width: 300, height: 140)
        root.bounds.size = root.frame.size
        func settle() async {
            for _ in 0..<8 { await Task.yield(); root.update(1 / 60); root.layoutIfNeeded() }
        }
        root.layoutIfNeeded()
        await settle()
        let picker = try root.uiNode(matching: .accessibilityIdentifier("AdaEditor.ShaderGraph.ColorPicker"))
        #expect(picker.absoluteFrame.width > 200)
        var frames: [Rect] = []
        for index in 0..<4 {
            frames.append(try root.uiNode(matching: .accessibilityIdentifier("AdaEditor.ShaderGraph.Value.\(index)")).absoluteFrame)
        }
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.maxX < $1.minX })
        #expect(frames.allSatisfy { $0.width >= 50 && $0.height >= 28 })
        _ = try root.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.ShaderGraph.Value.1"))
        #expect(root.uiPerformTextEditingCommand(.selectAll))
        for character in ["0", ".", "2", "5"] {
            root.onTextInputEvent(.init(window: .empty, text: character, action: .insert, time: 0))
            await settle()
        }
        #expect(model.graph?.nodes.first { $0.id == "tint" }?.value == [1, 0.25, 1, 1])
        #expect(model.save())
        #expect(EditorShaderGraphModel(url: url).graph?.nodes.first { $0.id == "tint" }?.value == [1, 0.25, 1, 1])
        model.undo()
        await settle()
        #expect(model.graph?.nodes.first { $0.id == "tint" }?.value == [1, 0.2, 1, 1])
    }
}
