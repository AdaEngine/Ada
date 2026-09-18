import AdaEngine
import AdaPlayerConnect
import Foundation
import Network
import Observation

@Observable @MainActor
final class EditorPlayerSession {
    let browser = PlayerBrowser()
    var code = ""
    var status = "Choose a device and enter its code."
    private(set) var connected = false
    private(set) var isBusy = false
    private(set) var isRunning = false
    var onOutput: ((String) -> Void)?
    var onState: ((Bool) -> Void)?
    var onConnected: (() -> Void)?
    @ObservationIgnored private var channel: PlayerConnection?
    @ObservationIgnored private var receiver: Task<Void, Never>?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var timeout: Task<Void, Never>?

    func connect(to endpoint: NWEndpoint, project: URL) {
        guard !isBusy else {
            return
        }
        disconnect()
        isBusy = true
        status = "Connecting…"
        let channel = PlayerConnection(NWConnection(to: endpoint, using: .tcp))
        self.channel = channel
        channel.start()
        timeout = Task { [weak self, weak channel] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard let self, self.channel === channel, !self.connected else {
                return
            }
            self.fail("Connection timed out. Check Wi-Fi and Local Network access.")
        }
        receiver = Task { [weak self] in
            do {
                guard let self else {
                    return
                }
                try await channel.send(PlayerMessage(.pair, text: self.code.trimmingCharacters(in: .whitespacesAndNewlines)))
                let reply = try await channel.receive(maximumBytes: 4096)
                guard reply.kind == .paired else {
                    throw PlayerConnectError.invalid(reply.text ?? "Pairing failed.")
                }
                guard self.channel === channel else {
                    return
                }
                self.timeout?.cancel()
                self.connected = true
                self.isBusy = false
                self.code = ""
                self.browser.stop()
                self.onConnected?()
                self.deploy(project)
                while !Task.isCancelled {
                    let message = try await channel.receive(maximumBytes: 64 * 1024)
                    guard self.channel === channel else {
                        return
                    }
                    switch message.kind {
                    case .log: self.onOutput?(message.text ?? "")
                    case .status:
                        self.isRunning = message.text == "running"
                        self.isBusy = false
                        self.status = self.isRunning ? "Running on AdaPlayer" : "Stopped"
                        self.onOutput?(self.status)
                        self.onState?(self.isRunning)
                    case .failure:
                        self.isBusy = false
                        self.status = message.text ?? "Device error"
                        self.onOutput?(self.status)
                    default: throw PlayerConnectError.invalid("Unexpected device response.")
                    }
                }
            } catch {
                guard let self, self.channel === channel else {
                    return
                }
                self.fail(error.localizedDescription)
            }
        }
    }

    func deploy(_ project: URL) {
        guard connected, !isBusy, let channel else {
            return
        }
        isBusy = true
        status = "Preparing device preview…"
        onOutput?(status)
        operation = Task { [weak self] in
            do {
                let snapshot = try await EditorPlayerProjectPackager.prepare(at: project)
                try Task.checkCancellation()
                try await channel.send(PlayerMessage(.deploy, project: snapshot))
                self?.status = "Launching on device…"
            } catch {
                guard let self, self.channel === channel else {
                    return
                }
                self.isBusy = false
                self.status = error.localizedDescription
                self.onOutput?(self.status)
            }
        }
    }

    func stop() {
        if isBusy {
            disconnect()
            return
        }
        guard let channel else {
            return
        }
        isBusy = true
        operation = Task { [weak self] in
            do { try await channel.send(PlayerMessage(.stop)) } catch { self?.fail(error.localizedDescription) }
        }
    }

    func disconnect() {
        operation?.cancel()
        operation = nil
        receiver?.cancel()
        receiver = nil
        timeout?.cancel()
        timeout = nil
        channel?.cancel()
        channel = nil
        connected = false
        isRunning = false
        isBusy = false
        browser.stop()
        onState?(false)
    }

    private func fail(_ message: String) {
        disconnect()
        status = message
        onOutput?(message)
        browser.start()
    }
}

struct EditorPlayerPairingView: View {
    let session: EditorPlayerSession
    let project: URL

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connect AdaPlayer")
                    .font(.system(size: 20, weight: .bold))
                Text("Open AdaPlayer on your iPhone or iPad on the same Wi-Fi.")
                    .font(.system(size: 13))
                    .foregroundColor(theme.editorColors.muted)
                codeField
                Text(session.status)
                    .font(.system(size: 12))
                    .foregroundColor(theme.editorColors.muted)
                if session.browser.devices.isEmpty {
                    Text(session.browser.status)
                        .font(.system(size: 12))
                        .foregroundColor(theme.editorColors.muted)
                }
            }
            .padding(.all, 24)

            Spacer(minLength: 16)
            actionPanel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundColor(theme.editorColors.text)
        .background(theme.editorColors.background)
        .onAppear { session.browser.start() }
        .onDisappear { session.browser.stop() }
    }

    private var codeField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pairing code")
                .font(.system(size: 12, weight: .semibold))
            TextField(
                "Six-digit code",
                text: Binding(
                    get: { session.code },
                    set: { session.code = String($0.filter(\.isNumber).prefix(6)) }
                )
            )
            .textFieldStyle(PlainTextFieldStyle())
            .font(.system(size: 16))
            .foregroundColor(theme.editorColors.text)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surfaceElevated))
            .overlay {
                RoundedRectangleShape(cornerRadius: 6)
                    .stroke(theme.editorColors.border, lineWidth: 1)
            }
            .accessibilityIdentifier("AdaPlayer.Editor.Code")
        }
    }

    private var actionPanel: some View {
        VStack(spacing: 0) {
            theme.editorColors.border.frame(height: 1)
            VStack(spacing: 10) {
                ForEach(session.browser.devices) { device in
                    Button(action: { session.connect(to: device.endpoint, project: project) }) {
                        Text("Connect and Run on \(device.name)")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(EditorUIDesignerButtonStyle(colors: theme.editorColors, selected: true, bordered: true))
                    .disabled(session.code.count != 6 || session.isBusy)
                }
                Button(action: {
                    session.browser.stop()
                    session.browser.start()
                }) {
                    Text("Search again").frame(maxWidth: .infinity)
                }
                .buttonStyle(EditorUIDesignerButtonStyle(colors: theme.editorColors, bordered: true))
                .accessibilityIdentifier("AdaPlayer.Editor.SearchAgain")
            }
            .padding(.all, 16)
        }
        .background(theme.editorColors.surface)
        .accessibilityIdentifier("AdaPlayer.Editor.Actions")
    }
}
