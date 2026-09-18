//
//  EmptyWindow.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 30.05.2025.
//

/// Create a window with empty content.
public struct EmptyWindow: AppScene {
    /// Initialize a new empty window.
    public init() {}

    /// The body of the empty window.
    public var body: some AppScene { fatalError("Unreachable code") }
}
