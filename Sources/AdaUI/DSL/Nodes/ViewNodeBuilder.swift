//
//  ViewNodeBuilder.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 08.06.2024.
//

protocol ViewNodeBuilder {
    typealias BuildContext = _ViewInputs

    @MainActor @preconcurrency
    func buildViewNode(in context: BuildContext) -> ViewNode
}
