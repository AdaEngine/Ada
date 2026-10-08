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
