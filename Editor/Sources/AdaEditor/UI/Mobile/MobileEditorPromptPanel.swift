#if os(iOS)
@_spi(AdaEngine) import AdaEngine
import Foundation

struct MobileEditorPromptPanel: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Binding var text: String
    @State private var isExpanded = false
    @State private var focusRequestID = 0

    let attachmentURLs: [URL]
    let removeAttachment: (URL) -> Void
    let pasteImages: @MainActor () -> Bool
    let isAgentRunning: Bool
    let pickFiles: @MainActor () -> Void
    let pickPhotos: @MainActor () -> Void
    let submit: () -> Void
    let openVoice: () -> Void

    private static let promptIdentifier = "AdaEditor.Mobile.BuildPrompt"
    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var canSend: Bool { (hasText || !attachmentURLs.isEmpty) && !isAgentRunning }

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
                    .frame(width: max(0, min(620, geometry.size.width - 32)))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
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
                        withTransaction(Transaction()) {
                            if value.translation.height < -20 { isExpanded = true }
                            if value.translation.height > 20 { isExpanded = false }
                            focusRequestID &+= 1
                        }
                    })
                    Spacer()
                }

                HStack {
                    Spacer()
                    iconButton("\u{E5CD}", identifier: "AdaEditor.Mobile.ClosePrompt", action: close)
                }

                ZStack(anchor: .topLeading) {
                    TextEditor(text: _text, showsLineNumbers: false, showsScrollIndicators: true, wrapsLines: true)
                        .textEditorAutofocus(requestID: focusRequestID)
                        .onTextEditorPaste(pasteImages)
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

                if !attachmentURLs.isEmpty {
                    MobileEditorAttachmentPreviews(urls: attachmentURLs, remove: removeAttachment)
                }
                HStack(spacing: 8) {
                    iconButton("\u{E145}", identifier: "AdaEditor.Mobile.AddAttachment") {
                        ProjectOpenPicker.presentAgentAttachmentSourcePicker(
                            pickFiles: pickFiles,
                            pickPhotos: pickPhotos
                        )
                    }
                    Spacer()
                    controlButton(identifier: "AdaEditor.Mobile.DictatePrompt", action: {
                        openVoice()
                    }) {
                        MobileEditorVoiceOrb()
                            .frame(width: 44, height: 44)
                            .allowsHitTesting(false)
                    }
                    if hasText || !attachmentURLs.isEmpty {
                        Button {
                            guard canSend else {
                                return
                            }
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
        dismiss()
    }

    private func toggleExpansion() {
        withTransaction(Transaction()) {
            isExpanded.toggle()
            focusRequestID &+= 1
        }
    }
}
#endif
