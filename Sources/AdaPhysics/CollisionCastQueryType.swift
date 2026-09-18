//
//  CollisionCastQueryType.swift
//  AdaEngine
//
//  Created by v.prusakov on 4/5/23.
//

/// The kinds of ray and convex shape cast queries that you can make.
public enum CollisionCastQueryType: Hashable, Sendable {
    /// Report one hit
    case first

    /// Report all hits sorted in ascending order by distance from the cast origin.
    case all
}
