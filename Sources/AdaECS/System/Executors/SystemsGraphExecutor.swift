//
//  SystemsGraphExecutor.swift
//  AdaEngine
//

import AdaUtils
import Collections

/// Protocol that responsible to execute graph of systems.
public protocol SystemsGraphExecutor: Sendable {
    mutating func initialize(_ graph: borrowing SystemsGraph)

    mutating func execute(
        _ graph: borrowing SystemsGraph,
        world: World,
        scheduler: SchedulerName
    ) async
}
