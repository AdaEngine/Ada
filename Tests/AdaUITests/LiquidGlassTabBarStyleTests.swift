import AdaCorePipelines
import AdaECS
@testable import AdaPlatform
@_spi(Internal) import AdaRender
import AdaText
@testable import AdaUI
import AdaUtils
import Math
import Testing

private struct LiquidGlassNavigationTabRoot: View {
    @State var selected = 0
    var thirdTabPlacement: TabPlacement = .bar

    var body: some View {
        NavigationStack {
            TabView(selection: $selected) {
                Tab("First", value: 0) {
                    Text("First content")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("glass-content-0")
                }
                Tab("Second", value: 1) {
                    ScrollView {
                        Text("Second content").accessibilityIdentifier("glass-content-1")
                    }
                    .accessibilityIdentifier("glass-scroll")
                }
                Tab("Third", value: 2, placement: thirdTabPlacement) {
                    Text("Third content")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("glass-content-2")
                }
            }
            .tabViewPosition(.bottom)
            .tabViewStyle(LiquidGlassTabBarStyle())
            .mask(RectangleShape())
            .background(Color.black)
            .navigationTitle("Project")
            .navigationBarColor(.red)
        }
        .frame(width: 320, height: 480)
    }
}

@MainActor
struct LiquidGlassTabBarStyleTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func switchingTabsKeepsSelectedContentAndNavigationChrome() async throws {
        let root = LiquidGlassNavigationTabRoot()
        let tester = ViewTester(rootView: root)
            .setSize(Size(width: 320, height: 480))
            .performLayout()
        let rect = Rect(origin: .zero, size: Size(width: 320, height: 480))
        let world = makeRenderWorld()

        for selected in [0, 1, 2, 0, 2, 1, 0] {
            let point = Point(82 + Float(selected) * 78, 426)
            tester.sendMouseEvent(at: point, phase: .began)
            tester.sendMouseEvent(at: point, phase: .ended)
            await Task.yield()
            tester.advanceFrame(deltaTime: 0.4).performLayout()

            #expect(root.selected == selected)
            #expect(tester.collectHitAccessibilityIdentifiers(in: rect).contains("glass-content-\(selected)"))
            let title = try #require(tester.findNodeByAccessibilityIdentifier("AdaUI.NavigationBar.Title"))
            #expect(title.frame.height > 0)
            if selected == 1 {
                let scroll = try #require(tester.findNodeByAccessibilityIdentifier("glass-scroll") as? ScrollViewNode)
                #expect(scroll.environment.safeAreaInsets.top == 92)
                #expect(scroll.absoluteFrame().minY == 0)
            }
            let context = UIGraphicsContext()
            tester.containerView.draw(in: rect, with: context)
            #expect(context.getDrawCommands().contains { command in
                if case let .drawLinearGradient(_, _, _, stops) = command {
                    return stops.first?.color == Color.red.opacity(0.98)
                }
                return false
            })
            var pending = PendingUIGraphicsContext()
            pending.graphicContexts.append(context)
            world.insertResource(pending)
            world.insertResource(UIRenderBuildState())
            await world.runScheduler(.update)
            let items = try #require(world.getResource(RenderItems<UITransparentRenderItem>.self)).items
            #expect(items.contains { !$0.drawData.gradientVertexBuffer.elements.isEmpty })
        }
    }

    @Test
    func floatingTabSelectsItsContentAndReturnsToMainTabs() async throws {
        let root = LiquidGlassNavigationTabRoot(thirdTabPlacement: .floating)
        let tester = ViewTester(rootView: root)
            .setSize(Size(width: 320, height: 480))
            .performLayout()
        let rect = Rect(origin: .zero, size: Size(width: 320, height: 480))
        let floating = try #require(tester.findNodeByAccessibilityIdentifier("AdaUI.TabView.Floating.2"))
        let frame = floating.absoluteFrame()
        #expect(frame.width == 68)
        #expect(frame.height == 68)
        #expect(frame.minX > 200)

        for (selected, point) in [(2, Point(frame.midX, frame.midY)), (1, Point(159, 426)), (2, Point(frame.midX, frame.midY)), (0, Point(81, 426))] {
            tester.sendMouseEvent(at: point, phase: .began)
            tester.sendMouseEvent(at: point, phase: .ended)
            await Task.yield()
            tester.advanceFrame(deltaTime: 0.4).performLayout()

            #expect(root.selected == selected)
            #expect(tester.collectHitAccessibilityIdentifiers(in: rect).contains("glass-content-\(selected)"))
            #expect(tester.findNodeByAccessibilityIdentifier("AdaUI.NavigationBar.Title") != nil)
        }
    }

    private func makeRenderWorld() -> World {
        let world = World(name: "LiquidGlassTabBarStyleTests")
        world.setSchedulers([.update])
        world.insertResource(RenderDeviceHandler(renderDevice: unsafe RenderEngine.shared.renderDevice))
        world.insertResource(RenderPipelines(configurator: TextPipeline()))
        world.insertResource(RenderPipelines(configurator: QuadPipeline()))
        world.insertResource(RenderPipelines(configurator: CirclePipeline()))
        world.insertResource(RenderPipelines(configurator: LinePipeline()))
        world.insertResource(RenderPipelines(configurator: LinearGradientPipeline()))
        world.insertResource(RenderPipelines(configurator: GlassPipeline()))
        world.insertResource(UIRenderPipelines(from: world))
        world.insertResource(RenderItems<UITransparentRenderItem>())
        world.insertResource(UIDrawPass())
        world.insertResource(UILayerDrawCache())
        world.insertResource(PendingUIGraphicsContext())
        world.insertResource(UIRenderBuildState())
        world.addSystem(UIRenderTesselationSystem.self)
        return world
    }
}
