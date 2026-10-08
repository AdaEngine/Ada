@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor @Suite(.serialized)
struct EditorUIExportIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADA_UI_EXPORT_INTEGRATION"] == "1"))
    func compilesSwiftProviderAndRendersNestedInventory() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            let app = AppWorlds(main: World(name: "UIExportIntegration"))
            RenderWorldPlugin().setup(in: app)
        }
        let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let project = engine.appendingPathComponent("Documentation/Examples/UIScenes")
        let toolchain = await SwiftToolchainLocator.locate()
        let result = await EditorProcessRunner()
            .run(
                .init(
                    executablePath: toolchain.swiftExecutablePath,
                    arguments: ["package", "describe", "--type", "json"],
                    workingDirectory: project
                )
            )
        #expect(result.succeeded, Comment(rawValue: result.combinedOutput))
        let package = try #require(SwiftPackageModel.parse(from: result.standardOutput))
        let loader = EditorUIExportLoader()
        let catalog = try await loader.load(projectURL: project, packageModel: package, builder: EditorPreviewBuilder())
        #expect(catalog.views["Game.Badge"] != nil)
        var actions = 0
        let context = UIBindingContext()
        context.on("selectItem") { _ in actions += 1 }
        let resources = UISceneResources(rootURL: project.appendingPathComponent("Assets"))
        let source = try resources.resolve("Inventory.ui")
        let session = try UISceneInstance(document: resources.load(source), context: context, catalog: catalog, resources: resources, sourceURL: source)
        let container = UIContainerView(rootView: UISceneView(session: session))
        container.frame = Rect(x: 0, y: 0, width: 800, height: 600)
        container.layoutSubviews()
        func flatten(_ nodes: [UINodeSnapshot]) -> [UINodeSnapshot] { nodes.flatMap { [$0] + flatten($0.children) } }
        let buttons = flatten(container.uiTreeRoots()).filter { $0.sceneNodeID == "use-item" }
        #expect(buttons.count == 3)
        let first = try #require(buttons.first)
        _ = try container.uiTapNode(matching: .runtimeID(first.runtimeId))
        #expect(actions == 1)
        context.set("items", to: .array([.object(["id": .string("potion"), "name": .string("Potion")])]))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            container.layoutSubviews()
            if flatten(container.uiTreeRoots()).filter({ $0.sceneNodeID == "use-item" }).count == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(flatten(container.uiTreeRoots()).filter { $0.sceneNodeID == "use-item" }.count == 1)
    }
}
