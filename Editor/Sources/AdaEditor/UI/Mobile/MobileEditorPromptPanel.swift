#if os(iOS)
@_spi(AdaEngine) import AdaEngine
import Foundation

struct MobileEditorPromptPanel: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    @State private var isExpanded = false
    @State private var dictation = MobileEditorPromptDictation()
    @State private var focusTask: Task<Void, Never>?

    let attachmentNames: [String]
    let isAgentRunning: Bool
    let pickFiles: @MainActor () -> Void
    let pickPhotos: @MainActor () -> Void
    let submit: () -> Void

    private static let promptIdentifier = "AdaEditor.Mobile.BuildPrompt"
    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSend: Bool { (hasText || !attachmentNames.isEmpty) && !isAgentRunning }

    var body: some View {
        GeometryReader { geometry in
            ZStack(anchor: .bottom) {
                Button(action: close) {
                    Color.black.opacity(0.48)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.Mobile.DismissPromptBackdrop")

                panel(height: max(180, isExpanded ? geometry.size.height - 24 : min(300, geometry.size.height - 24)))
                    .frame(maxWidth: 620)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .onAppear { focusPrompt() }
        .onDisappear {
            focusTask?.cancel()
            dictation.stop()
        }
    }

    private func panel(height: Float) -> some View {
        EditorAgentComposerSurface(cornerRadius: 28, horizontalInset: 16, topInset: 8, bottomInset: 12, usesGlass: true) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer()
                    Button(action: toggleExpansion) {
                        CapsuleShape().fill(theme.editorColors.muted.opacity(0.45))
                            .frame(width: 40, height: 5)
                            .padding(.vertical, 10)
                            .padding(.horizontal, 20)
                    }
                    .buttonStyle(DefaultButtonStyle())
                    .accessibilityIdentifier("AdaEditor.Mobile.PromptGrabber")
                    .gesture(DragGesture(minimumDistance: 12).onEnded { value in
                        if value.translation.height < -20 { isExpanded = true }
                        if value.translation.height > 20 { isExpanded = false }
                        focusPrompt()
                    })
                    Spacer()
                }

                HStack {
                    Spacer()
                    iconButton("\u{E5CD}", identifier: "AdaEditor.Mobile.ClosePrompt", action: close)
                }

                ZStack(anchor: .topLeading) {
                    TextEditor(text: _text, showsLineNumbers: false, showsScrollIndicators: isExpanded)
                        .font(MobileEditorFont.font(size: 16))
                        .foregroundColor(theme.editorColors.text)
                        .textEditorColors(TextEditorColors(
                            background: .clear,
                            border: .clear,
                            focusedBorder: .clear,
                            gutter: .clear,
                            gutterRule: .clear,
                            currentLineBackground: .clear,
                            selection: theme.editorColors.blue.opacity(0.24)
                        ))
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 40, maxHeight: .infinity)
                        .accessibilityIdentifier(Self.promptIdentifier)
                    if text.isEmpty {
                        Text("Plan, ask, build…")
                            .font(MobileEditorFont.font(size: 16))
                            .foregroundColor(theme.editorColors.muted)
                            .padding(.horizontal, 10)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 40, maxHeight: .infinity)

                if !attachmentNames.isEmpty {
                    Text(attachmentNames.joined(separator: ", "))
                        .font(MobileEditorFont.font(size: 11))
                        .foregroundColor(theme.editorColors.muted)
                        .lineLimit(1)
                }
                if let error = dictation.errorMessage {
                    Text(error)
                        .font(MobileEditorFont.font(size: 11))
                        .foregroundColor(theme.editorColors.muted)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    iconButton("\u{E145}", identifier: "AdaEditor.Mobile.AddAttachment") {
                        dictation.stop()
                        focusTask?.cancel()
                        ProjectOpenPicker.presentAgentAttachmentSourcePicker(
                            pickFiles: pickFiles,
                            pickPhotos: pickPhotos
                        )
                    }
                    if dictation.isRecording || dictation.isStarting {
                        Text(dictation.isStarting ? "Starting…" : "Listening…")
                            .font(MobileEditorFont.font(size: 12))
                            .foregroundColor(theme.editorColors.muted)
                    }
                    Spacer()
                    if dictation.isRecording || dictation.isStarting || !hasText {
                        controlButton(identifier: "AdaEditor.Mobile.DictatePrompt", action: {
                            if dictation.isRecording || dictation.isStarting {
                                dictation.stop()
                            } else {
                                dictation.start { text = $0 }
                            }
                            focusPrompt()
                        }) {
                            if dictation.isRecording || dictation.isStarting {
                                Text("\u{E047}").font(AdaEditorMaterialSymbolFont.font(size: 24))
                            } else {
                                MobileEditorPromptSymbol(kind: .microphone)
                            }
                        }
                    }
                    if hasText || !attachmentNames.isEmpty {
                        Button {
                            guard canSend else {
                                return
                            }
                            dictation.stop()
                            focusTask?.cancel()
                            submit()
                        } label: {
                            Text("\u{E163}")
                                .font(AdaEditorMaterialSymbolFont.font(size: 22))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .background(Circle().fill(theme.editorColors.blue))
                        }
                        .buttonStyle(DefaultButtonStyle())
                        .disabled(!canSend)
                        .accessibilityIdentifier("AdaEditor.Mobile.BuildSubmit")
                    }
                }
            }
            .frame(height: max(150, height - 20))
        }
        .accessibilityIdentifier("AdaEditor.Mobile.PromptPanel")
    }

    private func iconButton(_ symbol: String, identifier: String, action: @escaping () -> Void) -> some View {
        controlButton(identifier: identifier, action: action) {
            Text(symbol)
                .font(AdaEditorMaterialSymbolFont.font(size: 24))
        }
    }

    private func controlButton<Label: View>(identifier: String, action: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .foregroundColor(theme.editorColors.text)
                .frame(width: 44, height: 44)
                .background(Circle().fill(theme.editorColors.background.opacity(0.4)))
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier(identifier)
    }

    private func close() {
        focusTask?.cancel()
        dictation.stop()
        dismiss()
    }

    private func toggleExpansion() {
        isExpanded.toggle()
        focusPrompt()
    }

    /// Wait for the modal's first layout, then focus the real AdaUI editor node.
    private func focusPrompt() {
        focusTask?.cancel()
        focusTask = Task { @MainActor in
            for _ in 0..<10 {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let window = UIWindowManager.shared?.activeWindow else { continue }
                for container in window.uiInspectableContainers() {
                    guard let prompt = try? container.uiNode(matching: .accessibilityIdentifier(Self.promptIdentifier)),
                          let editor = container.uiHitTest(at: Point(prompt.absoluteFrame.minX + 12, prompt.absoluteFrame.minY + 12))?.node else { continue }
                    if (try? container.uiFocusNode(matching: .runtimeID(editor.runtimeId))) != nil {
                        return
                    }
                }
            }
        }
    }
}
#endif
