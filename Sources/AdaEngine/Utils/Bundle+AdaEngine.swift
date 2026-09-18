//
//  Bundle+AdaEngine.swift
//  AdaEngine
//
//  Created by vladislav.prusakov on 13.03.2025.
//

import Foundation

extension Bundle {
    public static var engineBundle: Bundle {
        #if SWIFT_PACKAGE
            return Self.module
        #else
            return Bundle(for: BundleToken.self)
        #endif
    }
}

#if !SWIFT_PACKAGE
    class BundleToken {}
#endif
