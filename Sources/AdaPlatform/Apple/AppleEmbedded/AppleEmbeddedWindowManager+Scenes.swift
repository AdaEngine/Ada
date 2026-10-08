//
//  AppleEmbeddedWindowManager+Scenes.swift
//  AdaEngine
//

#if IOS || TVOS || VISIONOS
    @_spi(Internal) import AdaUI
    import AdaUtils
    import Foundation
    import UIKit

    extension AppleEmbeddedWindowManager {
        func destroySceneIfRequestWasCancelled(
            _ requestToken: String?,
            windowScene: UIWindowScene
        ) -> Bool {
            guard
                let requestToken,
                cancelledSceneRequestTokens.remove(requestToken) != nil
            else {
                return false
            }
            UIApplication.shared.requestSceneSessionDestruction(windowScene.session, options: nil)
            return true
        }

        func cancelPendingSceneRequests(for window: AdaUI.UIWindow) {
            let requestTokens = pendingSceneWindows.compactMap { requestToken, pendingWindow in
                pendingWindow.window === window ? requestToken : nil
            }
            for requestToken in requestTokens {
                pendingSceneWindows[requestToken] = nil
                cancelledSceneRequestTokens.insert(requestToken)
            }
        }

        func sceneSessionsDidDiscard(_ sceneSessions: Set<UIKit.UISceneSession>) {
            for sceneSession in sceneSessions {
                dedicatedSceneSessionIDs.remove(sceneSession.persistentIdentifier)
                guard
                    let windowID = windowIDsBySceneSession.removeValue(forKey: sceneSession.persistentIdentifier),
                    let window = windows[windowID],
                    let uiWindow = window.systemWindow as? UIKit.UIWindow
                else {
                    continue
                }

                uiWindow.isHidden = true
                uiWindow.windowScene = nil
                removeWindow(window, setActiveAnotherIfNeeded: true)
            }
        }

        func sceneDidBecomeActive(_ windowScene: UIWindowScene) {
            guard
                let uiWindow = (windowScene.delegate as? AppleEmbeddedSceneDelegate)?.window,
                let window = findWindow(for: uiWindow)
            else {
                return
            }
            setActiveWindow(window)
        }

        func sceneWillResignActive(_ windowScene: UIWindowScene) {
            guard
                let uiWindow = (windowScene.delegate as? AppleEmbeddedSceneDelegate)?.window,
                let window = findWindow(for: uiWindow)
            else {
                return
            }
            resignActiveWindow(window)
        }

        func requestNewScene(for window: AdaUI.UIWindow, isFocused: Bool) {
            guard UIApplication.shared.supportsMultipleScenes else {
                presentWindow(window, isFocused: isFocused, scene: nil)
                return
            }

            guard !pendingSceneWindows.values.contains(where: { $0.window === window }) else {
                return
            }

            let requestToken = UUID().uuidString
            pendingSceneWindows[requestToken] = (window, isFocused)

            let activity = NSUserActivity(activityType: AppleEmbeddedSceneRequest.activityType)
            activity.targetContentIdentifier = requestToken
            activity.addUserInfoEntries(from: [AppleEmbeddedSceneRequest.tokenKey: requestToken])

            let options = UIWindowScene.ActivationRequestOptions()
            options.requestingScene = activeWindowScene()
            let request = UISceneSessionActivationRequest(
                role: .windowApplication,
                userActivity: activity,
                options: options
            )
            UIApplication.shared.activateSceneSession(for: request) { [weak self] error in
                guard let self else {
                    return
                }
                if self.cancelledSceneRequestTokens.remove(requestToken) != nil {
                    return
                }
                guard let pendingWindow = self.pendingSceneWindows.removeValue(forKey: requestToken) else {
                    return
                }
                self.presentWindow(
                    pendingWindow.window,
                    isFocused: pendingWindow.isFocused,
                    scene: nil
                )
                print("AdaEngine could not create a new window scene: \(error.localizedDescription)")
            }
        }

        func activeWindowScene() -> UIWindowScene? {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first {
                    $0.activationState == .foregroundActive
                        || $0.activationState == .foregroundInactive
                }
                ?? UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
        }
    }

    enum AppleEmbeddedSceneRequest {
        static let activityType = "org.adaengine.window.open"
        static let tokenKey = "AdaEngineWindowRequestToken"
    }
#endif
