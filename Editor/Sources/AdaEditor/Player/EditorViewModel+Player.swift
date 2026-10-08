@_spi(AdaEngine) import AdaEngine
import Foundation

extension EditorViewModel {
    func runOnAdaPlayer() {
        guard let projectURL else {
            return
        }
        playerSession.onOutput = { [weak self] message in self?.appendOutput("[AdaPlayer] \(message)") }
        playerSession.onState = { [weak self] running in
            guard let self else {
                return
            }
            self.workspaceStatus = running ? .running("AdaPlayer") : .ready
            self.footer.setWorkspaceFooterTitle(self.workspaceStatus.title)
        }
        if playerSession.connected {
            playerSession.deploy(projectURL)
            return
        }
        do {
            let manager = try requireWindowManager()
            playerPairingWindow?.close()
            let window = manager.spawnWindow(
                configuration: .init(
                    title: "Connect AdaPlayer",
                    frame: Rect(x: 0, y: 0, width: 520, height: 480),
                    minimumSize: Size(width: 360, height: 400),
                    mode: .windowed,
                    showsImmediately: false,
                    makeKey: true,
                    isResizable: true,
                    scenePresentation: .new
                )
            ) {
                EditorPlayerPairingView(session: self.playerSession, project: projectURL)
            }
            playerSession.onConnected = { [weak self] in
                self?.playerPairingWindow?.close()
                self?.playerPairingWindow = nil
            }
            window.onDidDisappear = { [weak self] in
                guard let self else {
                    return
                }
                if !self.playerSession.connected {
                    self.playerSession.disconnect()
                }
                self.playerPairingWindow = nil
            }
            playerPairingWindow = window
            window.showWindow(makeFocused: true)
        } catch { appendOutput("AdaPlayer: \(error.localizedDescription)") }
    }
}
