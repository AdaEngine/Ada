//
//  MacAppDelegate.swift
//  AdaEngine
//
//  Created by v.prusakov on 10/9/21.
//

#if MACOS
    import AppKit
    import MetalKit

    final class MacAppDelegate: NSObject, NSApplicationDelegate {
        func application(_: NSApplication, open urls: [URL]) {
            for url in urls {
                NotificationCenter.default.post(name: .adaEngineOpenURL, object: url)
            }
        }
    }

#endif
