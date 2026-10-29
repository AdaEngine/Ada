import AdaInput
@_spi(Internal) @testable import AdaRender
import AdaScripting
import AdaUI
import AdaUtils
import Foundation
import Math
import Testing

@Suite("Inventory board interaction", .serialized)
@MainActor
struct ItemBoardIntegrationTests {
    init() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
    }
    private func makeBoard(size: Size = Size(width: 1000, height: 600)) throws -> (UIContainerView<UISceneView>, UIBindingContext) {
        let snapshot = #"{"width":1000,"height":600,"elements":[{"id":"stash:pistol","kind":"item","rect":[10,10,80,80],"draggable":true,"category":"pistol"},{"id":"pistol","kind":"zone","rect":[500,100,200,100],"accepts":["pistol"],"columns":2},{"id":"back","kind":"button","rect":[20,500,120,50],"text":"Back"}]}"#
        let context = UIBindingContext(values: ["snapshot": .string(snapshot), "intent": .string("")])
        let document = UISceneDocument(root: .init(type: "ItemBoard", arguments: [
            "snapshot": .init(binding: "snapshot"), "command": .init(binding: "intent")
        ]))
        let root = FileManager.default.temporaryDirectory
        let session = try UISceneInstance(document: document, context: context, resources: UISceneResources(rootURL: root))
        let container = UIContainerView(rootView: UISceneView(session: session))
        container.frame = Rect(origin: .zero, size: size)
        container.layoutSubviews()
        return (container, context)
    }
    private func send(_ board: UIContainerView<UISceneView>, _ x: Float, _ y: Float, _ phase: MouseEvent.Phase) {
        board.onMouseEvent(MouseEvent(window: .empty, button: .left, mousePosition: Point(x,y), phase: phase, modifierKeys: [], time: 0))
    }
    @Test func crossRegionDragPublishesDestinationCellOnlyOnRelease() throws {
        let (board, context) = try makeBoard()
        send(board,40,40,.began);send(board,650,150,.changed)
        #expect(context.value("intent")?.string == "")
        send(board,650,150,.ended)
        let text = try #require(context.value("intent")?.string)
        let fields = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any])
        #expect(fields[1] as? String == "move")
        #expect(fields[2] as? String == "stash:pistol")
        #expect(fields[3] as? String == "pistol")
        #expect(fields[4] as? Int == 1)
    }
    @Test func cancellingOrDroppingOutsideDoesNotPublish() throws {
        let (board, context) = try makeBoard()
        send(board,40,40,.began);send(board,650,150,.changed);send(board,650,150,.cancelled)
        #expect(context.value("intent")?.string == "")
        send(board,40,40,.began);send(board,850,400,.changed);send(board,850,400,.ended)
        #expect(context.value("intent")?.string == "")
    }
    @Test func lateSnapshotsRefreshTheMountedBoard() throws {
        let (board, context) = try makeBoard()
        context.set("snapshot", to: .string(#"{"width":1000,"height":600,"elements":[{"id":"late","kind":"button","rect":[700,300,200,100],"text":"Late"}]}"#))
        board.update(1.0 / 60.0)
        send(board,750,350,.began);send(board,750,350,.ended)
        let text = try #require(context.value("intent")?.string)
        let fields = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any])
        #expect(fields[1] as? String == "action")
        #expect(fields[2] as? String == "late")
    }
    @Test func textKeepsLogicalPixelScaleInsideWideLabels() throws {
        let (board, context) = try makeBoard()
        context.set("snapshot", to: .string(##"{"width":1000,"height":600,"elements":[{"id":"title","kind":"text","rect":[38,25,340,45],"text":"СКЛАД","font":28,"color":"#eee8dcff"}]}"##))
        board.update(1.0 / 60.0)
        let graphics = UIGraphicsContext()
        board.draw(in: board.bounds, with: graphics)
        var glyphs = 0
        for command in graphics.getDrawCommands() {
            if case let .drawGlyph(_, transform, _) = command {
                glyphs += 1
                #expect(abs(transform.x.xyz.length - 1) < 0.001)
                #expect(abs(transform.y.xyz.length - 1) < 0.001)
            }
            if case .drawText = command { Issue.record("Board text must not scale glyph geometry by its label rectangle.") }
        }
        #expect(glyphs == 5)
    }
    @Test func resizedViewportPreservesHitCoordinatesAndButtonActions() throws {
        let (board, context) = try makeBoard(size: Size(width: 1200,height: 600))
        send(board,140,40,.began);send(board,750,150,.changed);send(board,750,150,.ended)
        #expect(context.value("intent")?.string?.contains("stash:pistol") == true)
        send(board,140,525,.began);send(board,140,525,.ended)
        let text = try #require(context.value("intent")?.string)
        let fields = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any])
        #expect(fields[0] as? Int == 2)
        #expect(fields[1] as? String == "action")
        #expect(fields[2] as? String == "back")
    }
    @Test func actualGameLoadoutRules() throws {
        guard let path = ProcessInfo.processInfo.environment["ADAENGINE_LAST_AUTUMN_PATH"] else { return }
        let root = URL(fileURLWithPath: path)
        let results = try AdaScriptTestProject.run(directory: root, matching: "loadout", testTimeout: .seconds(30))
        print(AdaScriptTestReport.summary(results))
        #expect(results.count >= 6)
        #expect(results.allSatisfy { $0.outcome == .passed })
        try AdaScriptTestReport.json(results).write(to: root.appendingPathComponent("Evidence/RaidUI/loadout-tests.json"), atomically: true, encoding: .utf8)
    }
}
