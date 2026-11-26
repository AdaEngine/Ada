@_spi(AdaEngine) @testable import AdaEngine
import Testing

@testable import AdaEditor

@MainActor
extension EditorSceneAssetCacheTests {
    @Test("Scene loading ends when a frame of the current installation is published")
    func loadingWaitsForCurrentSceneFrame() async throws {
        var model = EditorSceneModel(
            scene: EditorSceneMetadata(id: "fixture", name: "Preview"),
            entities: (0..<129).map { index in
                EditorSceneEntity(id: "\(index)", name: "Owner \(index)", enabled: true, parent: nil, components: [:])
            }
        )
        let viewport = EditorSceneViewportModel()
        func configure(_ content: String, replacesDocument: Bool = false) {
            viewport.configure(
                sceneContent: content,
                model: model,
                replacesDocument: replacesDocument,
                onSelectionChanged: { _ in },
                onDocumentContentChanged: { _ in }
            )
        }
        configure("first scene")
        let world = World()
        var loading: [Bool] = []
        var installations = 0
        viewport.loadSceneWorld(world, waitsForLoadedSceneFrame: true, onLoadingChanged: { loading.append($0) }, onLoaded: { _ in installations += 1 })
        defer { viewport.disconnect() }

        #expect(viewport.prepareLoadedScenePresentation() == nil)
        for _ in 0..<400 where installations == 0 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(installations == 1)
        #expect(loading == [true])
        let publishOld = try #require(viewport.prepareLoadedScenePresentation())

        model.entities[0].id = "replacement"
        configure("replacement scene", replacesDocument: true)
        for _ in 0..<400 where installations < 2 { try await Task.sleep(for: .milliseconds(5)) }
        try #require(installations == 2)
        let publishCurrent = try #require(viewport.prepareLoadedScenePresentation())
        publishOld()
        #expect(loading == [true, true])
        publishCurrent()
        publishCurrent()
        #expect(loading == [true, true, false])
        #expect(viewport.prepareLoadedScenePresentation() == nil)
    }
}
