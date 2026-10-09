@testable import AdaPlatform
@testable import AdaUI
import AdaUtils
import Math
import Testing

@MainActor
@Suite(.serialized)
struct ToggleTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test("switch writes through its binding from both label and track")
    func switchWritesBinding() {
        let model = ToggleModel()
        let tester = ViewTester {
            Toggle("Notifications", isOn: Binding(
                get: { model.isOn },
                set: { model.isOn = $0; model.writes += 1 }
            ))
            .toggleStyle(.switch)
        }
        .setSize(Size(width: 260, height: 80))
        .performLayout()

        tap(tester, at: Point(30, 40))
        #expect(model.isOn)
        #expect(model.writes == 1)

        tap(tester, at: Point(240, 40))
        #expect(!model.isOn)
        #expect(model.writes == 2)
    }

    @Test("disabled switch does not write its binding")
    func disabledSwitch() {
        let model = ToggleModel()
        let tester = ViewTester {
            Toggle("Notifications", isOn: Binding(
                get: { model.isOn },
                set: { model.isOn = $0; model.writes += 1 }
            ))
            .disabled(true)
        }
        .setSize(Size(width: 260, height: 80))
        .performLayout()

        tap(tester, at: Point(240, 40))
        #expect(!model.isOn)
        #expect(model.writes == 0)
    }

    @Test("custom style receives binding and label visibility")
    func customStyle() {
        let model = ToggleModel()
        let tester = ViewTester {
            Toggle(isOn: Binding(
                get: { model.isOn },
                set: { model.isOn = $0 }
            )) {
                Text("Custom setting")
            }
            .toggleStyle(TestToggleStyle())
            .labelsHidden()
        }
        .setSize(Size(width: 260, height: 80))
        .performLayout()

        #expect(tester.findNodeById("custom-toggle-label") == nil)
        tap(tester, at: Point(130, 40))
        #expect(model.isOn)
    }

    @Test("padded switch keeps label and control at opposite row edges", arguments: [Float(300), Float(720)])
    func paddedSwitchLayout(width: Float) throws {
        let tester = ViewTester {
            Toggle("Setting", isOn: .constant(false))
                .toggleStyle(SwitchToggleStyle(rowHeight: 44, horizontalPadding: 12))
        }
        .setSize(Size(width: width, height: 44))
        .performLayout()

        let root = tester.containerView.viewTree.rootNode
        let label = try #require(descendants(of: TextViewNode.self, in: root).first)
        let thumb = try #require(descendants(of: ShapeViewNode<CircleShape>.self, in: root).first)
        #expect(abs(label.absoluteFrame().minX - 12) < 0.01)
        #expect(abs(thumb.absoluteFrame().minX - (width - 46)) < 0.01)
    }

    @Test("switch thumb and track animate together in both directions")
    func switchAnimation() throws {
        let model = ToggleModel()
        let tester = ViewTester {
            Toggle("Setting", isOn: Binding(get: { model.isOn }, set: { model.isOn = $0 }))
        }
        .setSize(Size(width: 300, height: 44))
        .performLayout()
        let root = tester.containerView.viewTree.rootNode
        let thumb = try #require(descendants(of: ShapeViewNode<CircleShape>.self, in: root).first)
        let track = try #require(descendants(of: OpacityViewNodeModifier.self, in: root).first)
        let offX = thumb.absoluteFrame().minX
        #expect(track.opacity == 0)

        for isOn in [true, false] {
            tap(tester, at: Point(280, 22))
            #expect(model.isOn == isOn)
            tester.invalidateContent().advanceFrame(deltaTime: 0)
            tester.advanceFrame(deltaTime: 0.09)
            #expect(thumb.absoluteFrame().minX > offX)
            #expect(thumb.absoluteFrame().minX < offX + 16)
            #expect(track.opacity > 0 && track.opacity < 1)
            tester.advanceFrame(deltaTime: 0.2)
            #expect(abs(thumb.absoluteFrame().minX - (offX + (isOn ? 16 : 0))) < 0.01)
            #expect(abs(track.opacity - (isOn ? 1 : 0)) < 0.01)
        }
    }

    private func descendants<Node: ViewNode>(of type: Node.Type, in root: ViewNode) -> [Node] {
        let matches = (root as? Node).map { [$0] } ?? []
        return matches + root.transientEnvironmentChildren.flatMap { descendants(of: type, in: $0) }
    }

    private func tap<Content: View>(_ tester: ViewTester<Content>, at point: Point) {
        tester.sendMouseEvent(at: point, phase: .began)
        tester.sendMouseEvent(at: point, phase: .ended)
    }
}

@MainActor
private final class ToggleModel {
    var isOn = false
    var writes = 0
}

private struct TestToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(action: { configuration.isOn.wrappedValue.toggle() }) {
            HStack {
                if configuration.showsLabel {
                    configuration.label.id("custom-toggle-label")
                }
                Text(configuration.isOn.wrappedValue ? "Yes" : "No")
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(DefaultButtonStyle())
    }
}
