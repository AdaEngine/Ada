import AdaApp
import AdaUI

struct GameDiagnosticsPlugin: Plugin {
    func setup(in app: borrowing AppWorlds) {
        UIPlugin.installWindowOverlayPass(in: app)
    }

    func finish(for app: borrowing AppWorlds) {
        guard let window = app.getResource(PrimaryWindow.self)?.window else { return }
        let session = GameDiagnosticsSession()
        session.attach(to: app)

        let titleBar = window.configuration.titleBar
        let titleInset = titleBar.background == .transparent && !titleBar.reservesSafeArea
            ? titleBar.dragRegionHeight ?? 0 : 0
        let content = UIContainerView(
            rootView: GameDiagnosticsOverlay(session: session)
                .padding(.top, titleInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        )
        let overlay = UIWindowOverlayView(content: content)
        overlay.frame = window.bounds
        window.addSubview(overlay)
        overlay.setNeedsLayout()
        overlay.setNeedsDisplay()
    }
}
