//
//  AppleEmbeddedAppDelegate.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/24/22.
//

#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    @_spi(Internal) import AdaUI
    import UIKit

    class AppleEmbeddedAppDelegate: NSObject, UIApplicationDelegate {
        var window: UIKit.UIWindow?

        func application(
            _: UIApplication,
            didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
        ) -> Bool {
            return true
        }

        #if os(iOS) || os(tvOS) || os(visionOS)
            func application(
                _: UIApplication,
                configurationForConnecting connectingSceneSession: UIKit.UISceneSession,
                options _: UIScene.ConnectionOptions
            ) -> UISceneConfiguration {
                let configuration = UISceneConfiguration(
                    name: "Default Configuration",
                    sessionRole: connectingSceneSession.role
                )
                configuration.delegateClass = AppleEmbeddedSceneDelegate.self
                return configuration
            }

            func application(
                _: UIApplication,
                didDiscardSceneSessions sceneSessions: Set<UIKit.UISceneSession>
            ) {
                (UIWindowManager.shared as? AppleEmbeddedWindowManager)?
                    .sceneSessionsDidDiscard(sceneSessions)
            }
        #endif
    }

#endif
