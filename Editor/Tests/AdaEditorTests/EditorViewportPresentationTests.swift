@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaUI
import Math
import Testing

@testable import AdaEditor

@MainActor
@Suite("Viewport presentation invalidation")
struct EditorViewportPresentationTests {
    @Test("Annotations display the captured frame, even when navigation has advanced")
    func annotationsFollowPresentedFrame() throws {
        let presentation = EditorViewportPresentation()
        let viewport = EditorSceneViewportModel()
        let model = EditorSceneModel.default(projectName: "Frame synchronization")
        viewport.configure(
            sceneContent: try model.encodedYAML(),
            onSelectionChanged: { _ in },
            onDocumentContentChanged: { _ in }
        )
        viewport.setViewportSize(Size(width: 640, height: 400))
        viewport.showsEntityMarkers = true
        let container = UIContainerView(rootView: EditorViewportDrawingLayer(
            viewportModel: viewport, presentation: presentation, kind: .gizmos
        ))
        container.frame = Rect(origin: .zero, size: viewport.viewportSize)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        func markerTransforms() -> [Transform3D] {
            let context = UIGraphicsContext()
            container.viewTree.rootNode.draw(with: context)
            context.commitDraw()
            return context.getDrawCommands().compactMap {
                if case let .drawQuad(transform, _, _) = $0 {
                    return transform
                }
                return nil
            }
        }

        let presentFirst = presentation.prepareFrame(viewportModel: viewport, theme: Theme())
        presentFirst()
        let first = markerTransforms()
        #expect(!first.isEmpty)
        viewport.twoDCenter = Vector2(1, 0)
        presentation.refresh(viewportModel: viewport)
        let presentSecond = presentation.prepareFrame(viewportModel: viewport, theme: Theme())
        #expect(markerTransforms() == first)
        viewport.twoDCenter = Vector2(2, 0)
        presentation.refresh(viewportModel: viewport)
        // No async yield, layout or view rebuild is needed to publish a frame.
        presentSecond()
        let second = markerTransforms()
        #expect(second.count == first.count)
        let firstMarker = try #require(first.first)
        let secondMarker = try #require(second.first)
        #expect(abs(secondMarker.origin.x - firstMarker.origin.x + viewport.twoDZoom) < 0.01)
        #expect(markerTransforms() == second)

        // While the next render target is resizing, both the old texture and
        // its annotations are stretched into the new display rectangle.
        container.frame.size = Size(width: 1_280, height: 800)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let resized = try #require(markerTransforms().first)
        #expect(abs(resized.origin.x - secondMarker.origin.x * 2) < 0.01)
        #expect(abs(resized.origin.y - secondMarker.origin.y * 2) < 0.01)
    }

    @Test("Unchanged frames reuse annotations and invalidation produces a new generation")
    func annotationGeneration() {
        let presentation = EditorViewportPresentation()
        let viewport = EditorSceneViewportModel()
        viewport.setViewportSize(Size(width: 640, height: 400))
        presentation.prepareFrame(viewportModel: viewport, theme: Theme())()
        let generation = presentation.presentedAnnotations?.generation
        presentation.prepareFrame(viewportModel: viewport, theme: Theme())()
        #expect(presentation.presentedAnnotations?.generation == generation)
        presentation.invalidateAnnotations()
        presentation.prepareFrame(viewportModel: viewport, theme: Theme())()
        #expect(presentation.presentedAnnotations?.generation != generation)
    }

    @Test("3D rotation leaves unchanged status and hidden rulers alone")
    func rotationDoesNotInvalidateLabels() {
        let presentation = EditorViewportPresentation()
        let viewport = EditorSceneViewportModel()
        viewport.setDisplayMode(.threeD)
        viewport.perspectiveBlend = 1
        presentation.refresh(viewportModel: viewport)
        let rulerRevision = presentation.rulerRevision
        let status = presentation.statusSuffix
        for _ in 0..<100 {
            viewport.rotate3D(by: Vector2(1, 1))
            presentation.refresh(viewportModel: viewport)
        }
        #expect(presentation.rulerRevision == rulerRevision)
        #expect(presentation.statusSuffix == status)
        viewport.setDisplayMode(.twoD)
        viewport.perspectiveBlend = 0
        presentation.refresh(viewportModel: viewport)
        #expect(presentation.rulerRevision > rulerRevision)
        #expect(presentation.statusSuffix != status)
    }

    @Test("Camera changes refresh rulers and status without rebuilding their host")
    func cameraChangesStayLocal() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "ViewportPresentationTests")))
        }
        let presentation = EditorViewportPresentation()
        let viewport = EditorSceneViewportModel()
        viewport.setViewportSize(Size(width: 640, height: 400))
        presentation.refresh(viewportModel: viewport)
        let builds = HostBuildCounter()
        let host = PresentationHost(presentation: presentation, viewport: viewport, builds: builds)
        let container = UIContainerView(rootView: host)
        container.frame = Rect(x: 0, y: 0, width: 640, height: 400)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let initialBuilds = builds.count
        let initialGeometryBuilds = builds.geometryCount
        let initialLabels = labels(in: container)
        let initialRulerRevision = presentation.rulerRevision
        let initialStatusRevision = presentation.statusRevision
        #expect(initialLabels.contains("Loaded 1 entities · "))
        #expect(presentation.statusSuffix == viewport.statusSuffix)

        viewport.twoDZoom = 75
        viewport.twoDCenter = Vector2(3, 2)
        host.requestRedraw()
        for _ in 0..<10 {
            await Task.yield()
            container.update(0)
            container.layoutIfNeeded()
        }
        let updatedLabels = labels(in: container)
        #expect(builds.count == initialBuilds)
        #expect(builds.geometryCount == initialGeometryBuilds)
        #expect(updatedLabels.contains("Loaded 1 entities · "))
        #expect(presentation.rulerRevision > initialRulerRevision)
        #expect(presentation.statusRevision > initialStatusRevision)
        #expect(presentation.statusSuffix == viewport.statusSuffix)
        #expect(updatedLabels != initialLabels)
    }

    @Test("Viewport annotation commands persist until navigation changes them")
    func annotationDrawingIsRetained() async throws {
        let presentation = EditorViewportPresentation()
        let viewport = EditorSceneViewportModel()
        let container = UIContainerView(rootView: EditorViewportDrawingLayer(
            viewportModel: viewport, presentation: presentation, kind: .grid
        ))
        container.frame = Rect(x: 0, y: 0, width: 640, height: 400)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()

        func layerRevision() throws -> UInt64 {
            let context = UIGraphicsContext()
            container.viewTree.rootNode.draw(with: context)
            context.commitDraw()
            return try #require(context.getDrawCommands().compactMap { command -> UInt64? in
                if case let .beginLayer(_, version, cacheable) = command, cacheable {
                    return version
                }
                return nil
            }.first)
        }

        let initial = try layerRevision()
        #expect(try layerRevision() == initial)
        viewport.twoDZoom = 75
        presentation.revision &+= 1
        for _ in 0..<3 {
            await Task.yield()
            container.layoutIfNeeded()
            container.update(0)
        }
        let navigated = try layerRevision()
        #expect(navigated > initial)
        #expect(try layerRevision() == navigated)
    }

    private func labels(in container: UIContainerView<PresentationHost>) -> Set<String> {
        Set(container.viewTree.rootNode.uiCollectNodes { $0.content is Text }
            .compactMap { ($0.content as? Text)?.plainText })
    }
}

@MainActor
private final class HostBuildCounter {
    var count = 0
    var geometryCount = 0
}

private struct PresentationHost: View {
    @State var presentation: EditorViewportPresentation
    let viewport: EditorSceneViewportModel
    let builds: HostBuildCounter

    init(presentation: EditorViewportPresentation, viewport: EditorSceneViewportModel, builds: HostBuildCounter) {
        self._presentation = State(wrappedValue: presentation)
        self.viewport = viewport
        self.builds = builds
    }

    func requestRedraw() { presentation.refresh(viewportModel: viewport) }

    var body: some View {
        builds.count += 1
        return GeometryReader { _ in
            builds.geometryCount += 1
            return VStack {
                EditorViewportRulerLayer(viewportModel: viewport, presentation: presentation)
                EditorViewportStatusLabel(presentation: presentation, viewportModel: viewport, warning: nil, entityCount: 1)
            }
        }
    }
}
