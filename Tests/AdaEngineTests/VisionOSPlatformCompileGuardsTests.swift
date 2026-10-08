import Foundation
import Testing

@Suite("visionOS platform compile guards")
struct VisionOSPlatformCompileGuardsTests {
    @Test func embeddedUIKitPlatformFilesIncludeVisionOS() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let files = [
            "Sources/AdaPlatform/AppPlatformPlugin.swift",
            "Sources/AdaPlatform/Apple/AppleEmbedded/AppleEmbeddedApplication.swift",
            "Sources/AdaPlatform/Apple/AppleEmbedded/AppleEmbeddedAppDelegate.swift",
            "Sources/AdaPlatform/Apple/AppleEmbedded/AppleEmbeddedSceneDelegate.swift",
            "Sources/AdaPlatform/Apple/MetalView.swift",
            "Sources/AdaPlatform/Apple/AppleEmbedded/MetalView+iOS.swift",
        ]

        for file in files {
            let contents = try String(contentsOf: root.appending(path: file), encoding: .utf8)
            #expect(contents.contains("os(visionOS)") || contents.contains("VISIONOS"), "\(file) should compile into the visionOS platform path")
        }
    }
}
