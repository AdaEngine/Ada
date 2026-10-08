//
//  AppleEmbeddedSceneDelegate.swift
//  AdaEngine
//
//  Created by Codex on 29.03.2026.
//

#if os(iOS) || os(tvOS) || os(visionOS)
    @_spi(Internal) import AdaUI
    import UIKit

    final class AppleEmbeddedSceneDelegate: NSObject, UIWindowSceneDelegate {
        var window: UIKit.UIWindow?

        func scene(
            _ scene: UIScene,
            willConnectTo _: UIKit.UISceneSession,
            options connectionOptions: UIScene.ConnectionOptions
        ) {
            guard
                let windowScene = scene as? UIWindowScene,
                let windowManager = UIWindowManager.shared as? AppleEmbeddedWindowManager
            else {
                return
            }
            let requestToken =
                connectionOptions.userActivities
                .first { $0.activityType == AppleEmbeddedSceneRequest.activityType }?
                .userInfo?[AppleEmbeddedSceneRequest.tokenKey] as? String
            windowManager.sceneDidConnect(windowScene, requestToken: requestToken)

            if let url = connectionOptions.urlContexts.first?.url {
                NotificationCenter.default.post(name: .adaEngineOpenURL, object: url)
            }
        }

        func scene(_: UIScene, openURLContexts urlContexts: Set<UIOpenURLContext>) {
            guard let url = urlContexts.first?.url else {
                return
            }
            NotificationCenter.default.post(name: .adaEngineOpenURL, object: url)
        }

        func sceneDidBecomeActive(_ scene: UIScene) {
            guard
                let windowScene = scene as? UIWindowScene,
                let windowManager = UIWindowManager.shared as? AppleEmbeddedWindowManager
            else {
                return
            }
            windowManager.sceneDidBecomeActive(windowScene)
        }

        func sceneWillResignActive(_ scene: UIScene) {
            guard
                let windowScene = scene as? UIWindowScene,
                let windowManager = UIWindowManager.shared as? AppleEmbeddedWindowManager
            else {
                return
            }
            windowManager.sceneWillResignActive(windowScene)
        }
    }
#endif
