//
//  PreviewProvider.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 20.02.2025.
//

#if false && canImport(SwiftUI) && swift(>=5.9)

    import AdaEngine
    import SwiftUI

    // @available(iOS 16.0, macOS 14.0, *)
    // public struct ScenePreviewProvider {
    //    public let scene: AdaEngine.Scene
    //
    //    public init(scene: AdaEngine.Scene) {
    //        self.scene = scene
    //    }
    // }

    #if canImport(UIKit)

        extension ScenePreviewProvider: UIViewRepresentable {
            public func makeUIView(in _: Context) -> AEView {
                do {
                    return try AEView(scene: scene, frame: .zero)
                } catch {
                    preconditionFailure("Unable to create scene preview: \(error)")
                }
            }

            public func updateUIView(_: AEView, in _: Context) {}
        }

    #endif

    #if canImport(AppKit)

        // extension ScenePreviewProvider: NSViewRepresentable {
        //    public func makeNSView(context: Context) -> AEView {
        //        try! AEView(scene: scene, frame: .zero)
        //    }
        //
        //    public func updateNSView(_ nsView: AEView, context: Context) { }
        // }

    #endif

#endif
