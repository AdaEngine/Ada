//
//  RuntimePlatform.swift
//  AdaEngine
//
//  Created by v.prusakov on 10/9/21.
//

/// The collection of available runtime platfoms.
public enum RuntimePlatform: String, Codable {
    case macOS
    case tvOS
    case iOS
    case watchOS
    case visionOS

    case windows

    case linux
    case android
    case web
}
