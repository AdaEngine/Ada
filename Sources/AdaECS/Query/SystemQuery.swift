//
//  SystemQuery.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/21/25.
//

/// A protocol that describe a query for world from a system.
public protocol SystemParameter: Sendable {
    /// The world access required by this parameter.
    static var access: SystemAccessSet { get }

    /// The world access required by this parameter instance.
    var access: SystemAccessSet { get }

    /// Initialize a new system query.
    /// - Parameter world: The world that will be used to initialize the query.
    init(from world: World)

    /// Updates the query state with the given world.
    /// - Parameter world: The world that will be used to update the query.
    /// Updates the query state with the given world.
    func update(from world: World)

    /// Notify query that world finish execution
    func finish(_ world: World)
}

extension SystemParameter {
    public static var access: SystemAccessSet {
        SystemAccessSet()
    }

    public var access: SystemAccessSet {
        Self.access
    }

    // Protocol witness must remain callable; concrete query implementations override it.
    // swiftlint:disable:next unavailable_function
    public func update(from _: World) {
        preconditionFailure("SystemQuery.update(from:) must be implemented by a concrete query.")
    }

    public func finish(_: World) {}
}
