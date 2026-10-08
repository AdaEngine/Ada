import AdaA2UI
import AdaEngine
@_spi(Internal) import AdaPlatform
import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

@main
struct A2UIFormDemo: App {
    var body: some AppScene {
        WindowGroup { FormDemoView() }
            .window(with: UIWindow.Configuration(title: "AdaUI · A2UI Forms", frame: Rect(x: 160, y: 140, width: 760, height: 820)))
    }
}

@MainActor @Observable
private final class FormDemoModel {
    let client = A2UIClient()
    var status = "Waiting for the agent stream…"
    var lastAction = "Submit the form to inspect its action payload."
    var started = false
    var lastEvent: A2UIClientEvent?

    init() {
        client.onEvent = { [weak self] event in
            guard let self else { return }
            if case let .object(envelope) = event.envelope, envelope["action"] != nil {
                self.lastEvent = event
                self.lastAction = (try? String(decoding: JSONEncoder().encode(event.envelope), as: UTF8.self)) ?? "Action received"
                demoLog("A2UI action: \(self.lastAction)")
            } else {
                self.status = self.client.lastError?.message ?? "Invalid message rejected"
            }
        }
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            guard let url = Bundle.module.url(forResource: "form", withExtension: "jsonl", subdirectory: "Fixtures") else {
                throw A2UIValidationError(message: "Demo fixture missing.")
            }
            let data = try Data(contentsOf: url)
            var decoder = A2UIJSONLDecoder()
            // Byte chunks exercise the same framing path a network adapter would use.
            for offset in stride(from: 0, to: data.count, by: 53) {
                let chunk = data.subdata(in: offset..<min(offset + 53, data.count))
                for frame in decoder.append(chunk) { try client.receive(frame.get()) }
                try await Task.sleep(for: .milliseconds(30))
            }
            if let frame = decoder.finish() { try client.receive(frame) }
            status = "Agent form ready. Edits stay local until submission."
            demoLog("A2UI demo stream ready")
            if ProcessInfo.processInfo.arguments.contains("--verify") {
                try await verify()
            }
        } catch {
            status = error.localizedDescription
            demoLog("A2UI demo verification FAIL: \(error.localizedDescription)")
        }
    }

    private func verify() async throws {
        try await Task.sleep(for: .milliseconds(150))
        guard let window = Application.shared.windowManager.activeWindow ?? Application.shared.windowManager.windows.values.first?.value,
              let container = window.uiInspectableContainers().first,
              let view = container as? UIView
        else { throw A2UIValidationError(message: "Mounted UI container missing.") }
        let input = UINodeSelector.accessibilityIdentifier("a2ui.form.name")
        _ = try container.uiTapNode(matching: input)
        view.onKeyEvent(KeyEvent(window: window.id, keyCode: .a, modifiers: [.control], status: .down, time: 0, isRepeated: false))
        view.onTextInputEvent(TextInputEvent(window: window.id, text: "Local NPC", action: .insert, time: 0))
        try await Task.sleep(for: .milliseconds(100))
        let before = try container.uiLayoutDiagnostics(matching: input, subtreeDepth: 1).focusedNode?.runtimeId
        view.onKeyEvent(KeyEvent(window: window.id, keyCode: .a, modifiers: [.control], status: .down, time: 0, isRepeated: false))
        updateHeading()
        try await Task.sleep(for: .milliseconds(100))
        let after = try container.uiLayoutDiagnostics(matching: input, subtreeDepth: 1).focusedNode?.runtimeId
        guard before != nil, before == after else { throw A2UIValidationError(message: "Focus was lost during streaming.") }
        view.onTextInputEvent(TextInputEvent(window: window.id, text: "Verified NPC", action: .insert, time: 0))
        try await Task.sleep(for: .milliseconds(100))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("a2ui.form.enabled"))
        try await Task.sleep(for: .milliseconds(100))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("a2ui.form.role.option.merchant"))
        try await Task.sleep(for: .milliseconds(100))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("a2ui.form.health"))
        try await Task.sleep(for: .milliseconds(100))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("a2ui.form.submit"))
        guard case let .object(envelope) = lastEvent?.envelope,
              case let .object(action) = envelope["action"],
              action["context"] == .object(["name": .string("Verified NPC"), "dialogEnabled": .bool(false), "role": .string("merchant"), "health": .number(51)])
        else { throw A2UIValidationError(message: "Input, selection, toggle, or action payload verification failed.") }
        guard let surface = client.surfaces["form"] else { throw A2UIValidationError(message: "Surface missing.") }
        // Use native keyboard deletion to make the required field invalid.
        lastEvent = nil
        _ = try container.uiTapNode(matching: input)
        view.onKeyEvent(KeyEvent(window: window.id, keyCode: .a, modifiers: [.control], status: .down, time: 0, isRepeated: false))
        view.onTextInputEvent(TextInputEvent(window: window.id, text: "", action: .deleteBackward, time: 1))
        try await Task.sleep(for: .milliseconds(100))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("a2ui.form.submit"))
        guard lastEvent == nil else { throw A2UIValidationError(message: "Invalid form submitted.") }
        _ = try container.uiTapNode(matching: input)
        view.onTextInputEvent(TextInputEvent(window: window.id, text: "Verified NPC", action: .insert, time: 0))
        try await Task.sleep(for: .milliseconds(100))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("a2ui.form.submit"))
        guard lastEvent != nil else { throw A2UIValidationError(message: "Valid form stayed disabled.") }
        let previous = surface.scene.document
        rejectMalformed()
        guard surface.scene.document == previous else { throw A2UIValidationError(message: "Malformed update replaced the UI.") }
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--proof-directory"), arguments.indices.contains(index + 1) {
            let directory = URL(fileURLWithPath: arguments[index + 1])
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(container.uiTreeRoots()).write(to: directory.appendingPathComponent("ui-tree.json"))
            try surface.snapshot().encodedYAML().write(to: directory.appendingPathComponent("NPCProfile.ui"), atomically: true, encoding: .utf8)
            if let lastEvent { try JSONEncoder().encode(lastEvent.envelope).write(to: directory.appendingPathComponent("action.json")) }
        }
        status = "Verified: streaming, focus, selection, toggle, picker, slider, validation, action, recovery, and .ui export."
        demoLog("A2UI demo verification PASS")
    }

    func updateHeading() {
        do {
            try client.receive(json: #"{"version":"v0.9.1","updateComponents":{"surfaceId":"form","components":[{"id":"heading","component":"Text","text":"Profile updated by the agent"}]}}"#)
            status = "Heading updated; your form values were retained."
        } catch { status = error.localizedDescription }
    }

    func rejectMalformed() {
        do {
            try client.receive(json: #"{"version":"v0.9.1","updateComponents":{"surfaceId":"form","components":[{"id":"heading","component":"InventedControl"}]}}"#)
        } catch { status = "Rejected: \(error.localizedDescription)" }
    }

    func save() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "NPCProfile.ui"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let surface = client.surfaces["form"] else { return }
            try surface.snapshot().encodedYAML().write(to: url, atomically: true, encoding: .utf8)
            status = "Saved \(url.lastPathComponent). Open it in Ada Studio’s UI designer."
        } catch { status = error.localizedDescription }
        #endif
    }
}

private struct FormDemoView: View {
    @State private var model = FormDemoModel()
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("AdaUI + A2UI").fontSize(26)
            Text(model.status).fontSize(14)
            A2UISurfaceView(client: model.client, surfaceID: "form")
                .frame(width: 560, height: 450, alignment: .topLeading)
            HStack(spacing: 12) {
                Button("Stream update") { model.updateHeading() }
                Button("Malformed update") { model.rejectMalformed() }
                #if os(macOS)
                Button("Save .ui…") { model.save() }
                #endif
            }
            Text(model.lastAction).fontSize(12).lineLimit(4)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.09, green: 0.11, blue: 0.15))
        .foregroundColor(.white)
        .buttonStyle(FormDemoButtonStyle())
        .textFieldStyle(FormDemoTextFieldStyle())
        .task { await model.start() }
    }
}

private func demoLog(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

private struct FormDemoTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField) -> some View {
        PlainTextFieldStyle()._body(configuration: configuration)
            .padding(.horizontal, 8)
            .background(Color(red: 0.16, green: 0.19, blue: 0.24))
            .border(Color(red: 0.34, green: 0.39, blue: 0.47), lineWidth: 1)
    }
}

private struct FormDemoButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontSize(14)
            .padding(9)
            .background(configuration.isPressed ? Color(red: 0.25, green: 0.38, blue: 0.55) : Color(red: 0.18, green: 0.26, blue: 0.37))
    }
}
