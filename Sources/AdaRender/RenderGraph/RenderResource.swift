//
//  RenderResource.swift
//  AdaEngine
//
//  Created by v.prusakov on 2/18/23.
//

import AdaECS

public enum RenderResource: Sendable {
    case texture(Texture)
    case buffer(Buffer)
    case sampler(Sampler)
    case entity(Entity)
}

public enum RenderResourceKind: String, Sendable {
    case texture
    case buffer
    case sampler
    case entity
}

extension RenderResource {
    public var resourceKind: RenderResourceKind {
        switch self {
        case .texture:
            return .texture
        case .buffer:
            return .buffer
        case .sampler:
            return .sampler
        case .entity:
            return .entity
        }
    }

    public var texture: Texture? {
        guard case let .texture(texture) = self else {
            return nil
        }

        return texture
    }

    public var buffer: Buffer? {
        guard case let .buffer(buffer) = self else {
            return nil
        }

        return buffer
    }

    public var sampler: Sampler? {
        guard case let .sampler(sampler) = self else {
            return nil
        }

        return sampler
    }

    public var entity: Entity? {
        guard case let .entity(entity) = self else {
            return nil
        }

        return entity
    }
}
