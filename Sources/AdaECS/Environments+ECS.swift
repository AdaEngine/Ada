//
//  Environments+ECS.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 13.12.2025.
//

import AdaUtils

@_spi(Internal)
extension EnvironmentValues {
    /// Configuration for AdaECS used for tests.
    @Entry package var ecs: ECSConfig = ECSConfig()
}

/// Contains flags for AdaECS framework. Used for tests.
package struct ECSConfig: Sendable {
    /// The ``SystemsGraph`` will ignore ``System/dependencies-1g89l`` flag on linkage stage.
    package var useSystemDependencies = true
}
