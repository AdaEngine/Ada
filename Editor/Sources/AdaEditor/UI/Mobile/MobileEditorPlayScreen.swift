#if os(iOS)
@_spi(AdaEngine) import AdaEngine
import Foundation

struct MobileEditorPlayScreen: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var runtimeID = UUID()
    @State private var screenshot: Image?
    @State private var isCapturing = false
    @State private var captureError: String?
    @State private var captureTimeout: Task<Void, Never>?

    let project: MobileEditorProject
    let artifact: EditorAdaScriptProjectBuildArtifact?
    let capture: EditorProjectPreviewCapture?
    let message: String?
    let isAgentRunning: Bool
    let submitFeedback: (Image, EditorGameScreenshotMarkup, String) async throws -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                toolbar
                game
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                if let captureError {
                    Text(captureError)
                        .font(MobileEditorFont.font(size: 12))
                        .foregroundColor(theme.editorColors.muted)
                        .padding(12)
                }
            }
            .allowsHitTesting(screenshot == nil)
            if let screenshot {
                MobileEditorScreenshotPrompt(
                    image: screenshot,
                    isAgentRunning: isAgentRunning,
                    cancel: { self.screenshot = nil },
                    submit: { markup, text in try await submitFeedback(screenshot, markup, text) }
                )
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(theme.editorColors.background.ignoresSafeArea())
        .accessibilityIdentifier("AdaEditor.Mobile.FullScreenPlay")
        .onDisappear {
            captureTimeout?.cancel()
            capture?.stop()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            MobileEditorPlayControl(symbol: "\u{E5CD}", identifier: "ClosePlay") { dismiss() }
            Text(project.title)
                .font(MobileEditorFont.navigationFont(size: 16))
                .foregroundColor(theme.editorColors.text)
                .lineLimit(1)
            Spacer()
            MobileEditorPlayControl(symbol: "\u{E5D5}", identifier: "RestartPlay") {
                capture?.cancelFrameRequest()
                captureTimeout?.cancel()
                isCapturing = false
                runtimeID = UUID()
            }
            Button(action: captureFrame) {
                HStack(spacing: 6) {
                    Text(isCapturing ? "Capturing…" : "Ask Ada")
                        .font(MobileEditorFont.font(size: 12))
                }
                .foregroundColor(theme.editorColors.text)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(CapsuleShape().fill(theme.editorColors.surface))
            }
            .buttonStyle(DefaultButtonStyle())
            .disabled(isCapturing || isAgentRunning || capture == nil)
            .accessibilityIdentifier("AdaEditor.Mobile.CaptureGameFeedback")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var game: some View {
        if let artifact, let runtime = try? EditorAdaScriptProjectRuntimeView(artifact: artifact, previewCapture: capture) {
            runtime.id(runtimeID)
        } else {
            MobileEditorPlayEmptyScreen(message: message) { dismiss() }
        }
    }

    private func captureFrame() {
        captureError = nil
        guard let capture else { return }
        isCapturing = true
        capture.requestFrame { image in
            captureTimeout?.cancel()
            isCapturing = false
            screenshot = image
        }
        captureTimeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            capture.cancelFrameRequest()
            isCapturing = false
            captureError = "The game frame is not ready. Try again."
        }
    }
}

private struct MobileEditorPlayControl: View {
    @Environment(\.theme) private var theme
    let symbol: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if symbol == "\u{E5D5}" {
                    Text("Restart").font(MobileEditorFont.font(size: 11))
                } else {
                    Text(symbol).font(AdaEditorMaterialSymbolFont.font(size: 22))
                }
            }
            .foregroundColor(theme.editorColors.text)
            .frame(width: symbol == "\u{E5D5}" ? 68 : 44, height: 44)
            .background(CapsuleShape().fill(theme.editorColors.surface))
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.Mobile.\(identifier)")
    }
}

private struct MobileEditorScreenshotPrompt: View {
    @Environment(\.theme) private var theme
    @State private var markup = EditorGameScreenshotMarkup()
    @State private var currentStroke: [Point] = []
    @State private var text = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var sendTask: Task<Void, Never>?

    let image: Image
    let isAgentRunning: Bool
    let cancel: () -> Void
    let submit: (EditorGameScreenshotMarkup, String) async throws -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                MobileEditorPlayControl(symbol: "\u{E5CD}", identifier: "CancelGameFeedback", action: cancel)
                    .disabled(isSending)
                Text("Mark a change")
                    .font(MobileEditorFont.navigationFont(size: 16))
                    .foregroundColor(theme.editorColors.text)
                Spacer()
                MobileEditorPlayControl(symbol: "\u{E166}", identifier: "UndoGameMarkup") {
                    if !markup.strokes.isEmpty { markup.strokes.removeLast() }
                }
                .disabled(markup.strokes.isEmpty || isSending)
                MobileEditorPlayControl(symbol: "\u{E872}", identifier: "ClearGameMarkup") { markup.strokes = [] }
                    .disabled(markup.strokes.isEmpty || isSending)
            }
            .padding(.horizontal, 12)

            Text("Draw on the screenshot to show Ada what to change.")
                .font(MobileEditorFont.font(size: 11))
                .foregroundColor(theme.editorColors.muted)
                .padding(.horizontal, 16)
            canvas
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .padding(.horizontal, 12)
                .allowsHitTesting(!isSending)

            composer
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .padding(.top, 8)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(theme.editorColors.background)
        .accessibilityIdentifier("AdaEditor.Mobile.GameFeedback")
        .onDisappear {
            sendTask?.cancel()
        }
    }

    private var canvas: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / Float(image.width), geometry.size.height / Float(image.height))
            let size = Size(width: Float(image.width) * scale, height: Float(image.height) * scale)
            ZStack {
                image.resizable()
                MobileEditorMarkupShape(strokes: markup.strokes + (currentStroke.isEmpty ? [] : [currentStroke]))
                    .stroke(Color(red: 1, green: 0.22, blue: 0.25), lineWidth: max(2, size.width * 0.009))
                    .allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if currentStroke.isEmpty {
                        currentStroke.append(canvasPoint(value.startLocation, geometry: geometry, size: size))
                    }
                    currentStroke.append(canvasPoint(value.location, geometry: geometry, size: size))
                }
                .onEnded { value in
                    if currentStroke.isEmpty {
                        currentStroke.append(canvasPoint(value.startLocation, geometry: geometry, size: size))
                    }
                    currentStroke.append(canvasPoint(value.location, geometry: geometry, size: size))
                    markup.strokes.append(currentStroke)
                    currentStroke = []
                })
            .accessibilityIdentifier("AdaEditor.Mobile.GameMarkupCanvas")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func canvasPoint(_ point: Point, geometry: GeometryProxy, size: Size) -> Point {
        // AdaUI drag values use window coordinates; account for the fitted image's margins.
        let frame = geometry.frame(in: .global)
        let inset = Point((geometry.size.width - size.width) / 2, (geometry.size.height - size.height) / 2)
        return EditorGameScreenshotMarkup.normalized(point, in: Rect(origin: frame.origin + inset, size: size))
    }

    private var composer: some View {
        EditorAgentComposerSurface(cornerRadius: 24, horizontalInset: 14, topInset: 12, bottomInset: 10) {
            VStack(alignment: .leading, spacing: 10) {
                MobileEditorGameFeedbackInput(text: $text, textColor: theme.editorColors.text)
                    .nativeRenderingMode(.overlay)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .disabled(isSending)
                    .accessibilityIdentifier("AdaEditor.Mobile.GameFeedbackPrompt")
                if let errorMessage {
                    Text(errorMessage).font(MobileEditorFont.font(size: 11)).foregroundColor(theme.editorColors.muted)
                }
                HStack {
                    Text("Screenshot attached")
                        .font(MobileEditorFont.font(size: 11))
                        .foregroundColor(theme.editorColors.muted)
                    Spacer()
                    Button(action: send) {
                        Text(isSending ? "Sending…" : "Send to Ada")
                            .font(MobileEditorFont.font(size: 13))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .background(CapsuleShape().fill(theme.editorColors.blue))
                    }
                    .buttonStyle(DefaultButtonStyle())
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending || isAgentRunning)
                    .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending || isAgentRunning ? 0.4 : 1)
                    .accessibilityIdentifier("AdaEditor.Mobile.SendGameFeedback")
                }
            }
        }
    }

    private func send() {
        guard !isSending, !isAgentRunning else { return }
        isSending = true
        errorMessage = nil
        sendTask = Task { @MainActor in
            do {
                try await submit(markup, text.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                isSending = false
            }
        }
    }


}

private struct MobileEditorMarkupShape: Shape {
    typealias AnimatableData = EmptyAnimatableData
    let strokes: [[Point]]

    func path(in rect: Rect) -> Path {
        var path = Path()
        for stroke in strokes {
            guard let first = stroke.first else { continue }
            path.move(to: Vector2(first.x * rect.width, first.y * rect.height))
            for point in stroke.dropFirst() {
                path.addLine(to: Vector2(point.x * rect.width, point.y * rect.height))
            }
        }
        return path
    }
}
#endif
