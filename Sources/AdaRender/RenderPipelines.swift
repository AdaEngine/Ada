//
//  RenderPipelines.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 05.12.2025.
//

import AdaECS

public protocol RenderPipelineConfigurator: Resource {
    associatedtype Configuration: Hashable, Sendable

    func configurate(with configuration: Configuration) -> RenderPipelineDescriptor
}

public struct RenderPipelineEmptyConfiguration: Hashable, Sendable {
    @usableFromInline
    init() {}
}

public struct RenderPipelines<T: RenderPipelineConfigurator>: Resource {
    @usableFromInline
    var caches: [T.Configuration: RenderPipeline] = [:]

    @usableFromInline
    let configurator: T

    public init(configurator: T) {
        self.configurator = configurator
    }

    public mutating func pipeline(
        for configuration: T.Configuration,
        device: RenderDevice
    ) -> any RenderPipeline {
        if let pipeline = self.caches[configuration] {
            return pipeline
        }

        let pipelineDesc = configurator.configurate(with: configuration)
        let pipeline = device.createRenderPipeline(from: pipelineDesc)
        caches[configuration] = pipeline
        return pipeline
    }

    @inlinable
    public mutating func dropCache() {
        self.caches.removeAll(keepingCapacity: true)
    }
}

extension RenderPipelines where T.Configuration == RenderPipelineEmptyConfiguration {
    @inlinable
    public mutating func pipeline(
        device: RenderDevice
    ) -> any RenderPipeline {
        self.pipeline(for: RenderPipelineEmptyConfiguration(), device: device)
    }
}

extension RenderPipelines: WorldInitable where T: WorldInitable {
    @inlinable
    public init(from world: World) {
        self.configurator = T(from: world)
    }
}
