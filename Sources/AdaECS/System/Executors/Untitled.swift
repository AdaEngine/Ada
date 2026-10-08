//
//  Untitled.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 29.11.2025.
//

import Collections

struct MultithreadedGraphExecutor: SystemsGraphExecutor {
    func initialize(
        _: borrowing SystemsGraph
    ) {
    }

    func execute(
        _: borrowing SystemsGraph,
        world _: World,
        scheduler _: SchedulerName
    ) async {
    }
}

public struct SystemFilterAccess: Sendable {
    public var access: BitSet
    public var denied: BitSet
}
