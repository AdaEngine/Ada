@_spi(AdaEngine) import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

#if canImport(AppKit) && os(macOS)
    import AppKit
#endif

@Suite("Editor inspector")
struct EditorInspectorTests {
    #if canImport(AppKit) && os(macOS)
        @Test("platform color picker presents a real NSColorPanel")
        @MainActor
        func platformColorPickerPresentsNSColorPanel() {
            _ = NSApplication.shared
            EditorPlatformColorPicker.present(
                value: EditorInspectorColorValue(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.8),
                onChange: { _ in }
            )

            let panel = NSColorPanel.shared
            #expect(panel.showsAlpha)
            #expect(panel.isVisible)
            panel.orderOut(nil)
        }
    #endif

    @Test("component picker searches names, categories, and descriptions")
    @MainActor
    func componentPickerSearchesCatalogMetadata() {
        let viewModel = EditorInspectorSidebarViewModel()
        viewModel.selectEntity(
            EditorInspectorSidebarViewModel.SelectedEntity(
                editorID: "entity-1",
                name: "Player",
                componentNames: [],
                transformFields: [],
                components: [],
                addableComponents: [
                    .init(typeName: "Camera", displayName: "Camera", category: "Rendering", description: "Renders the scene."),
                    .init(typeName: "Light2D", displayName: "Light 2D", category: "2D", description: "Casts shadows."),
                ],
                gizmo: nil,
                hasExplicitGizmo: false
            )
        )

        #expect(viewModel.addableComponents(matching: "render").map(\.typeName) == ["Camera"])
        #expect(viewModel.addableComponents(matching: "shadow").map(\.typeName) == ["Light2D"])
        #expect(viewModel.addableComponents(matching: "2d").map(\.typeName) == ["Light2D"])
    }

    @Test("Add Component uses a full modal and adds the selected component")
    @MainActor
    func addComponentUsesFullModal() throws {
        let viewModel = EditorInspectorSidebarViewModel()
        viewModel.selectEntity(
            EditorInspectorSidebarViewModel.SelectedEntity(
                editorID: "entity-1",
                name: "Player",
                componentNames: [],
                transformFields: [],
                components: [],
                addableComponents: [
                    .init(typeName: "Camera", displayName: "Camera", category: "Rendering", description: "Renders the scene."),
                    .init(typeName: "Light2D", displayName: "Light 2D", category: "2D", description: "Casts shadows."),
                ],
                gizmo: nil,
                hasExplicitGizmo: false
            )
        )
        var addedComponent: String?
        viewModel.addComponent = { addedComponent = $0 }
        viewModel.presentComponentPicker()

        let container = UIContainerView(
            rootView: Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .fullScreenCover(isPresented: viewModel.componentPickerPresentationBinding) {
                    EditorAddComponentDialog(viewModel: viewModel)
                }
        )
        container.frame = Rect(x: 0, y: 0, width: 1024, height: 768)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        let dialog = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AddComponent.Dialog"))
        #expect(dialog.frame.width >= 600)
        #expect(dialog.frame.height >= 600)
        #expect(!container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Inspector.ComponentSearch")).isEmpty)

        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Inspector.AddComponent.Camera"))
        #expect(addedComponent == "Camera")
        #expect(!viewModel.isComponentPickerPresented)
    }

    @Test("color values round trip RGBA and hex")
    func colorValuesRoundTrip() throws {
        let value = try #require(EditorInspectorColorValue(rgbaText: "1, 0.5, 0, 0.25"))
        #expect(value.hexString == "#FF800040")

        let decoded = try #require(EditorInspectorColorValue(hexText: value.hexString))
        #expect(abs(decoded.red - 1) < 0.001)
        #expect(abs(decoded.green - Float(128) / 255) < 0.001)
        #expect(abs(decoded.blue) < 0.001)
        #expect(abs(decoded.alpha - Float(64) / 255) < 0.001)
    }

    @Test("texture picker filters project assets and resolves dropped files")
    @MainActor
    func texturePickerResolvesDroppedProjectAsset() {
        let viewModel = EditorInspectorSidebarViewModel()
        viewModel.textureAssets = [
            .init(name: "player.png", reference: "@res://Textures/player.png", absolutePath: "/tmp/Game/Assets/Textures/player.png"),
            .init(name: "sky.png", reference: "@res://Backgrounds/sky.png", absolutePath: "/tmp/Game/Assets/Backgrounds/sky.png"),
        ]

        #expect(viewModel.textureAssets(matching: "player").map(\.reference) == ["@res://Textures/player.png"])
        #expect(viewModel.textureAsset(droppedFileURL: URL(fileURLWithPath: "/tmp/Game/Assets/Textures/player.png"))?.name == "player.png")
        #expect(viewModel.textureAsset(droppedFileURL: URL(fileURLWithPath: "/tmp/outside.png")) == nil)
    }

    @Test("sprite texture and size fields are editable")
    func spriteTextureAndSizeFieldsAreEditable() throws {
        let descriptor = try #require(EditorComponentRegistry.descriptor(named: EditorBuiltInComponentType.sprite))
        #expect(descriptor.fields.first { $0.key == "texture" }?.isEditable == true)
        #expect(descriptor.fields.first { $0.key == "size" }?.isEditable == true)
        #expect(!descriptor.description.isEmpty)
    }
}
