@testable import AdaA2UI
import AdaAssets
@testable import AdaPlatform
@testable import AdaUI
import AdaUIDescription
import Foundation
import Testing

/// Chat image previews: project-relative PNG/GIF components with integer nearest-neighbor zoom.
@MainActor
struct A2UIImageTests {
    init() async throws { try Application.prepareForTest() }

    @Test func imageComponentsRenderProjectFilesWithIntegerZoom() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = A2UIClient(resources: UISceneResources(rootURL: root))
        try create(client)
        try components(
            client,
            #"""
            [
                {"id":"root","component":"Column","children":["still","anim"]},
                {"id":"still","component":"Image","path":"Assets/pic.png","zoom":4},
                {"id":"anim","component":"Image","path":"Assets/walk.gif"}
            ]
            """#
        )
        let surface = try #require(client.surfaces["preview"])
        let children = surface.scene.document.root.children
        #expect(children.map(\.type) == ["A2UIImage", "A2UIImage"])
        #expect(children[0].arguments["path"]?.value == .string("Assets/pic.png"))
        #expect(children[0].arguments["zoom"]?.value == .number(4))
        #expect(children[1].arguments["zoom"]?.value == .number(0))
    }

    @Test func imageComponentRejectsUnsafePathsBindingsAndBadZoom() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = A2UIClient(resources: UISceneResources(rootURL: root))
        try create(client)
        try components(client, #"[{"id":"root","component":"Image","path":"Assets/pic.png"}]"#)
        let surface = try #require(client.surfaces["preview"])
        let previous = surface.scene.document
        for values in [
            #"[{"id":"root","component":"Image","path":"../secret.png"}]"#,
            #"[{"id":"root","component":"Image","path":"/etc/passwd.png"}]"#,
            #"[{"id":"root","component":"Image","path":"~/secret.png"}]"#,
            #"[{"id":"root","component":"Image","path":"Assets/pic.txt"}]"#,
            #"[{"id":"root","component":"Image","path":{"path":"/pic"}}]"#,
            #"[{"id":"root","component":"Image","path":"Assets/pic.png","zoom":2.5}]"#,
            #"[{"id":"root","component":"Image","path":"Assets/pic.png","zoom":0}]"#,
            #"[{"id":"root","component":"Image","path":"Assets/pic.png","zoom":17}]"#,
        ] {
            #expect(throws: A2UIValidationError.self) { try components(client, values) }
            #expect(surface.scene.document == previous)
        }
    }

    @Test func imageComponentRejectsMissingAndEscapingFilesAtomically() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = A2UIClient(resources: UISceneResources(rootURL: root))
        try create(client)
        try components(client, #"[{"id":"root","component":"Image","path":"Assets/pic.png"}]"#)
        let surface = try #require(client.surfaces["preview"])
        let previous = surface.scene.document
        // A well-formed path whose file does not exist fails the update and keeps the last working surface.
        #expect(throws: A2UIValidationError.self) {
            try components(client, #"[{"id":"root","component":"Image","path":"Assets/missing.png"}]"#)
        }
        #expect(surface.scene.document == previous)
        // A `..` traversal is rejected by the component's path validation before any file lookup.
        #expect(throws: A2UIValidationError.self) {
            try components(client, #"[{"id":"root","component":"Image","path":"Assets/../outside/pic.png"}]"#)
        }
        #expect(surface.scene.document == previous)
    }

    @Test func imageComponentWithoutResourcesReportsTheMissingContext() throws {
        let client = A2UIClient()
        try create(client)
        #expect(throws: A2UIValidationError.self) {
            try components(client, #"[{"id":"root","component":"Image","path":"Assets/pic.png"}]"#)
        }
        #expect(client.surfaces["preview"]?.scene.document.root.type == "EmptyView")
    }

    private func create(_ client: A2UIClient) throws {
        try client.receive(json: """
        {"version":"v0.9.1","createSurface":{"surfaceId":"preview","catalogId":"\(A2UIClient.catalogID)","sendDataModel":false}}
        """)
    }

    private func components(_ client: A2UIClient, _ values: String) throws {
        try client.receive(json: """
        {"version":"v0.9.1","updateComponents":{"surfaceId":"preview","components":\(values)}}
        """)
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("a2ui-image-\(UUID().uuidString)", isDirectory: true)
        let assets = root.appendingPathComponent("Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let rgba = [UInt8](repeating: 255, count: 4 * 4 * 4)
        try PNGWriter().encode(width: 4, height: 4, rgba: rgba).write(to: assets.appendingPathComponent("pic.png"))
        let palette = [PixelColor(red: 0, green: 0, blue: 0, alpha: 0), PixelColor(red: 255, green: 0, blue: 0)]
        let frames = [GIFAnimationFrame(indices: [UInt8](repeating: 1, count: 16), delayMilliseconds: 120)]
        try GIFWriter().encode(width: 4, height: 4, frames: frames, palette: palette).write(to: assets.appendingPathComponent("walk.gif"))
        return root
    }
}
