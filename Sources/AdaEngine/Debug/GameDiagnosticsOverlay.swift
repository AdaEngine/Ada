import AdaText
import AdaUI
import AdaUtils
import Foundation

/// Read-only game update statistics for a diagnostics session.
@_spi(AdaEngine)
public struct GameDiagnosticsOverlay: View {
    private let session: GameDiagnosticsSession
    private let frameTimeLabel: String
    private let millisecondsUnit: String

    public init(
        session: GameDiagnosticsSession,
        frameTimeLabel: String = "Frame time",
        millisecondsUnit: String = "ms"
    ) {
        self.session = session
        self.frameTimeLabel = frameTimeLabel
        self.millisecondsUnit = millisecondsUnit
    }

    public var body: some View {
        let fps = session.sample.map { String(format: "%.1f", $0.framesPerSecond) } ?? "—"
        let frameTime = session.sample.map { String(format: "%.1f %@", $0.millisecondsPerFrame, millisecondsUnit) } ?? "—"
        VStack(spacing: 3) {
            row("FPS", value: fps)
            row(frameTimeLabel, value: frameTime)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 164)
        .foregroundColor(.white)
        .background(RoundedRectangleShape(cornerRadius: 6).fill(Color.black.opacity(0.86)))
        .padding(12)
        .allowsHitTesting(false)
    }

    private func row(_ title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12))
            Spacer(minLength: 0)
            Text(value).font(.system(size: 12, weight: .semibold))
        }
    }
}
