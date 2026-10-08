//
//  UserInterfaceIdiomModifier.swift
//  AdaEngine
//

import AdaUtils

/// Constants that indicate the interface type for the device.
public enum UserInterfaceIdiom: Hashable, Sendable, CaseIterable {
    case phone
    case pad
    case xr
    case desktop
    case tv
}

extension EnvironmentValues {
    @Entry public var userInterfaceIdiom: UserInterfaceIdiom = {
        #if os(macOS) || os(Windows) || os(Linux) || os(wasi)
            .desktop
        #else
            .phone
        #endif
    }()
}
