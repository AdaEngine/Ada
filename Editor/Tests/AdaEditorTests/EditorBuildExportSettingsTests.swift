@testable import AdaEditor
@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Testing

@MainActor
@Suite("Build and export settings", .serialized)
struct EditorBuildExportSettingsTests {
    @Test(arguments: [false, true])
    func platformPagesRenderWithAndWithoutProject(hasProject: Bool) async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "BuildExportSettings")))
        }
        let model = EditorSettingsWindowViewModel(
            editorViewModel: hasProject ? EditorViewModel(project: nil) : nil,
            selectedSection: .buildExport
        )
        #expect(!model.pages(in: .general).contains("ANDROID"))
        #expect(model.pages(in: .buildExport) == EditorBuildPlatform.allCases.map(\.rawValue))
        let container = UIContainerView(rootView: EditorSettingsWindowView(viewModel: model).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 1000, height: 720)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        for platform in EditorBuildPlatform.allCases {
            model.selectPage(platform.rawValue, in: .buildExport)
            for _ in 0..<6 {
                await Task.yield()
                container.update(1 / 60)
                container.layoutIfNeeded()
            }
            let page = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.BuildExport.Page." + platform.rawValue))
            #expect(page.absoluteFrame.width > 300)
            let field = try #require(platform.fields.first)
            let input = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.BuildExport." + platform.rawValue + "." + field.id))
            #expect(input.absoluteFrame.height > 20)
            if platform == .android {
                let ndk = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.BuildExport.ANDROID.ANDROID_NDK_HOME"))
                let jdk = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.BuildExport.ANDROID.JAVA_HOME"))
                #expect(abs(input.absoluteFrame.width - ndk.absoluteFrame.width) < 1)
                #expect(abs(input.absoluteFrame.width - jdk.absoluteFrame.width) < 1)
            }
        }
        model.searchText = "JDK"
        #expect(model.filteredSections == [.buildExport])
        #expect(model.visiblePages(in: .buildExport) == ["ANDROID"])
    }

    @Test
    func savedPathsReloadAndMigrateAndroidPreferences() throws {
        let name = "BuildExportTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["ANDROID_HOME": "/SDK/Android"], forKey: EditorAndroidConfiguration.preferenceKey)
        let model = EditorSettingsWindowViewModel(editorViewModel: nil, selectedSection: .buildExport, buildExportDefaults: defaults)
        #expect(model.buildExportConfiguration.value("ANDROID_HOME", for: .android) == "/SDK/Android")
        model.buildToolBinding("JAVA_HOME", platform: .android).wrappedValue = " /Tools/JDK "
        model.buildToolBinding("SWIFT_EXECUTABLE", platform: .macOS).wrappedValue = "/Tools/Swift/bin/swift"
        model.buildToolBinding("DEVELOPER_DIR", platform: .iOS).wrappedValue = "/Tools/Xcode/Contents/Developer"
        model.buildToolBinding("SDKROOT", platform: .xr).wrappedValue = "/Tools/visionOS.sdk"
        model.buildExportConfiguration.save(defaults: defaults)
        let reloaded = EditorBuildExportConfiguration.load(defaults: defaults)
        #expect(reloaded.value("JAVA_HOME", for: .android) == "/Tools/JDK")
        #expect(reloaded.swiftExecutable(for: .macOS) == "/Tools/Swift/bin/swift")
        #expect(reloaded.environment(for: .iOS)["DEVELOPER_DIR"] == "/Tools/Xcode/Contents/Developer")
        #expect(reloaded.environment(for: .xr)["SDKROOT"] == "/Tools/visionOS.sdk")
        let android = EditorAndroidConfiguration.load(environment: [:], preferences: defaults.dictionary(forKey: EditorAndroidConfiguration.preferenceKey) as? [String: String])
        #expect(android.environment["JAVA_HOME"] == "/Tools/JDK")
        #expect(android.environment["PATH"]?.contains("/Tools/JDK/bin") == true)
    }

    @Test
    func commandsConsumeSelectedNativeAndWebTools() {
        var settings = EditorBuildExportConfiguration()
        settings.values[EditorBuildPlatform.host.rawValue] = ["SWIFT_EXECUTABLE": "/Tools/Native/swift", "DEVELOPER_DIR": "/Tools/Xcode/Developer"]
        settings.values[EditorBuildPlatform.web.rawValue] = [
            "ADA_WEB_SWIFT_EXECUTABLE": "/Tools/WASM/swift",
            "ADA_WEB_SWIFT_SDK": "custom-wasm-sdk",
            "TINT_EXECUTABLE": "/Tools/Tint/tint"
        ]
        let service = SwiftPMWorkspaceService()
        let root = URL(fileURLWithPath: "/tmp/Game")
        let toolchain = SwiftToolchain(swiftExecutablePath: "/usr/bin/swift", sourceKitLSPExecutablePath: nil)
        let native = service.makeCommand(.build(target: nil, buildTests: false), projectURL: root, toolchain: toolchain, buildSettings: settings)
        #expect(native.executablePath == "/Tools/Native/swift")
        let web = service.makeCommand(.runWeb(target: "Game", outputPath: "dist/web", serve: true), projectURL: root, toolchain: toolchain, buildSettings: settings)
        #expect(web.executablePath == "/Tools/WASM/swift")
        #expect(web.arguments.suffix(2) == ["--swift-sdk", "custom-wasm-sdk"])
        #expect(web.environment["TINT_EXECUTABLE"] == "/Tools/Tint/tint")
        #expect(web.environment["BUILD_WASM"] == "1")
        #expect(web.environment["DEVELOPER_DIR"] == nil)
    }

    @Test
    func pathChecksDistinguishExecutableAndDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BuildTools." + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = root.appendingPathComponent("swift")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        var settings = EditorBuildExportConfiguration()
        settings.values[EditorBuildPlatform.macOS.rawValue] = ["SWIFT_EXECUTABLE": tool.path, "DEVELOPER_DIR": root.path]
        #expect(settings.pathStatus(EditorBuildToolField("SWIFT_EXECUTABLE", "Swift", .executable), for: .macOS) == "Available")
        #expect(settings.pathStatus(EditorBuildToolField("DEVELOPER_DIR", "Xcode", .directory), for: .macOS) == "Available")
        settings.values[EditorBuildPlatform.macOS.rawValue]?["SWIFT_EXECUTABLE"] = root.path
        #expect(settings.pathStatus(EditorBuildToolField("SWIFT_EXECUTABLE", "Swift", .executable), for: .macOS) == "Executable not found")
        settings.values[EditorBuildPlatform.macOS.rawValue]?["DEVELOPER_DIR"] = tool.path
        #expect(settings.pathStatus(EditorBuildToolField("DEVELOPER_DIR", "Xcode", .directory), for: .macOS) == "Directory not found")
    }
}
