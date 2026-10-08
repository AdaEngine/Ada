//
//  AppleApplication.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/9/23.
//

#if canImport(MetalKit)
    @_spi(Internal) import AdaEngine
    @_spi(Internal) import AdaPlatform
    import MetalKit

    /// Application for apple platfroms.
    /// This application class using for storing game loop and window manager.
    final class AppleApplication: Application {
        override init(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws {
            try super.init(argc: argc, argv: argv)
            let screenManager = AppleEmbeddableScreenManager()
            Screen.screenManager = screenManager
            self.windowManager = AppleWindowManager(screenManager: screenManager)
        }
    }

#endif
