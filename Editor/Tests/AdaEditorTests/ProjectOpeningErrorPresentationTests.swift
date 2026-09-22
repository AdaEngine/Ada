@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@Suite("Project opening error presentation", .serialized)
@MainActor
struct ProjectOpeningErrorPresentationTests {
    @Test("App Store distribution explains why a SwiftPM project cannot open")
    func appStoreSwiftProjectErrorIsVisible() throws {
        prepareRenderer()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectOpeningError-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.manifest.write(
            to: root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try ProjectSystem.saveProject(
            ProjectSystem.defaultProject(projectName: "HybridGame", buildSystem: .swiftpm),
            at: root
        )

        let store = EditorProjectStore(
            storageURL: root.appendingPathComponent("recents.json"),
            distribution: .appStore
        )
        let model = ProjectOpeningViewModel(store: store)
        model.openProject(at: root)

        #expect(model.selectedProject == nil)
        #expect(model.projectToOpenInEditor == nil)
        #expect(model.validationDiagnostics.isEmpty)
        #expect(model.operationErrorMessage?.contains("AdaScript projects only") == true)

        let container = UIContainerView(
            rootView: ProjectOpeningView(autoOpenLastProject: false, viewModel: model)
                .theme(.adaEditor)
        )
        container.frame = Rect(x: 0, y: 0, width: 1_024, height: 700)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        let error = try container.uiNode(
            matching: .accessibilityIdentifier(ProjectOpeningAccessibility.operationError)
        )
        let landing = try container.uiNode(
            matching: .accessibilityIdentifier(ProjectOpeningAccessibility.landingContent)
        )
        #expect(error.absoluteFrame.width > 0)
        #expect(error.absoluteFrame.height > 0)
        #expect(error.absoluteFrame.minX >= landing.absoluteFrame.minX)
        #expect(error.absoluteFrame.maxX <= landing.absoluteFrame.maxX)
        #expect(error.absoluteFrame.minY >= landing.absoluteFrame.minY)
        #expect(error.absoluteFrame.maxY <= landing.absoluteFrame.maxY)
    }

    private func prepareRenderer() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "ProjectOpeningErrorTests")))
        }
    }

    private static let manifest = """
        // swift-tools-version: 6.2
        import PackageDescription

        let package = Package(
            name: "HybridGame",
            products: [.executable(name: "HybridGame", targets: ["HybridGame"])],
            targets: [.executableTarget(name: "HybridGame")]
        )
        """
}
