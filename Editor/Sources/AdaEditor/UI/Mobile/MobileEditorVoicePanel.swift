#if os(iOS)
@_spi(AdaEngine) import AdaEngine
import Foundation

struct MobileEditorVoicePanel: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    @State private var voice = MobileEditorVoiceSession()
    @State private var awaitingReply = false
    @State private var response: String?
    @State private var submittedText: String?
    let events: [EditorAgentEvent]
    let isAgentRunning: Bool
    let agentStatus: String?
    let agentActivity: EditorAgentActivityState
    let submit: () -> Bool
    let openKeyboard: () -> Void

    private var isCapturing: Bool { voice.dictation.isStarting || voice.dictation.isRecording }

    private var activity: MobileVoiceOrbActivity {
        if voice.isSpeaking {
            return .speaking
        }
        if isCapturing {
            return .listening
        }
        return isAgentRunning ? .working : .idle
    }

    private var status: String {
        if voice.isSpeaking {
            return "Ada is speaking…"
        }
        if voice.dictation.isStarting {
            return "Starting microphone…"
        }
        if voice.dictation.isRecording {
            return "Listening…"
        }
        if isAgentRunning {
            return agentStatus ?? "Ada is working…"
        }
        return "Tap the Bubble to speak"
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 16) {
                HStack {
                    Text("Voice with Ada")
                        .font(MobileEditorFont.font(size: 18))
                    Spacer()
                    symbolButton("\u{E5CD}", identifier: "AdaEditor.Mobile.CloseVoice") {
                        voice.stop()
                        dismiss()
                    }
                }
                ZStack {
                    VStack(spacing: 16) {
                        Button(action: toggleListening) {
                            MobileEditorVoiceOrb(activity: activity, audioLevel: voice.dictation.audioLevel)
                                .frame(width: orbDiameter(geometry.size), height: orbDiameter(geometry.size))
                                .allowsHitTesting(false)
                        }
                        .buttonStyle(DefaultButtonStyle())
                        .accessibilityIdentifier("AdaEditor.Mobile.VoiceBubble")
                        Text(status)
                            .font(MobileEditorFont.font(size: 13))
                            .foregroundColor(theme.editorColors.muted)
                            .accessibilityIdentifier("AdaEditor.Mobile.VoiceStatus")
                        if !text.isEmpty || submittedText?.isEmpty == false || response?.isEmpty == false {
                            ScrollView(showsIndicators: true, contentInsets: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0)) {
                                VStack(alignment: .leading, spacing: 20) {
                                    if !(text.isEmpty ? submittedText ?? "" : text).isEmpty {
                                        Text(text.isEmpty ? submittedText ?? "" : text)
                                            .font(MobileEditorFont.font(size: 17))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .accessibilityIdentifier("AdaEditor.Mobile.VoiceTranscript")
                                    }
                                    if let response {
                                        Text(response)
                                            .font(MobileEditorFont.font(size: 15))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .accessibilityIdentifier("AdaEditor.Mobile.VoiceReply")
                                    }
                                }
                            }
                            .frame(minHeight: 50, maxHeight: 160)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("AdaEditor.Mobile.VoiceCenter")
                if let error = voice.dictation.errorMessage ?? voice.errorMessage {
                    Text(error)
                        .font(MobileEditorFont.font(size: 12))
                        .foregroundColor(theme.editorColors.muted)
                } else if !isAgentRunning, let agentStatus {
                    Text(agentStatus)
                        .font(MobileEditorFont.font(size: 12))
                        .foregroundColor(theme.editorColors.muted)
                        .lineLimit(3)
                }
                HStack(spacing: 20) {
                    symbolButton("\u{E312}", identifier: "AdaEditor.Mobile.VoiceKeyboard") {
                        voice.stop()
                        openKeyboard()
                    }
                    Spacer()
                    symbolButton(
                        isCapturing || voice.isSpeaking ? "\u{E047}" : "\u{E029}",
                        identifier: "AdaEditor.Mobile.VoiceMicrophone",
                        action: toggleListening
                    )
                    Spacer()
                    Button(action: send) {
                        Text("\u{E163}")
                            .font(AdaEditorMaterialSymbolFont.font(size: 24))
                            .foregroundColor(.white)
                            .frame(width: 52, height: 52)
                            .background(Circle().fill(theme.editorColors.blue))
                    }
                    .disabled(isAgentRunning || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("AdaEditor.Mobile.SendVoicePrompt")
                }
            }
            .padding(24)
            .frame(maxWidth: 620, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundColor(theme.editorColors.text)
        .background(theme.editorColors.background.ignoresSafeArea())
        .onAppear {
            awaitingReply = isAgentRunning
            #if DEBUG && targetEnvironment(simulator)
            if CommandLine.arguments.contains("--mobile-voice-layout-qa") {
                return
            }
            #endif
            if !isAgentRunning { listen() }
        }
        .onDisappear { voice.stop() }
        .onChange(of: isAgentRunning) { _, running in
            guard awaitingReply, !running else {
                return
            }
            awaitingReply = false
            response = MobileEditorVoiceContent.reply(in: events)
            if let response, agentActivity == .completed { voice.speak(response) }
        }
    }

    private func orbDiameter(_ size: Size) -> Float { min(260, size.width * 0.7, size.height * 0.34) }

    private func symbolButton(_ symbol: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol)
                .font(AdaEditorMaterialSymbolFont.font(size: 26))
                .frame(width: 48, height: 48)
                .background(Circle().fill(theme.editorColors.surface))
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier(identifier)
    }

    private func toggleListening() {
        if isCapturing || voice.isSpeaking {
            voice.stop()
        } else if !isAgentRunning {
            listen()
        }
    }

    private func listen() {
        voice.listen(initialText: text) { text = $0 }
    }

    private func send() {
        guard !isAgentRunning, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        voice.stop()
        response = nil
        submittedText = text
        awaitingReply = submit()
    }
}
#endif
