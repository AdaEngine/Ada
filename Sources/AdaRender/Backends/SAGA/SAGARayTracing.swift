//
//  SAGARayTracing.swift
//  AdaEngine
//
//  Maps AdaRender's acceleration-structure API onto SAGA's acceleration-structure resources and build commands.
//

#if SAGA_RENDER && canImport(SAGACompiler)
    import Foundation
    import SAGA
    import SAGACore
    import SAGATypes

    /// A SAGA acceleration structure. SAGA retires the resource after the submissions that used it.
    final class SAGAAccelerationStructure: AccelerationStructure, @unchecked Sendable {
        let kind: AccelerationStructureKind
        let context: SAGAContext
        let slot: ResourceSlot<ResourceID>

        init?(context: SAGAContext, kind: AccelerationStructureKind) {
            let descriptor: SAGATypes.AccelerationStructureDescriptor
            switch kind {
            case let .bottomLevel(capacity):
                guard capacity > 0, capacity <= Int(UInt32.max) else { return nil }
                descriptor = .init(maxTriangleCount: UInt32(capacity))
            case let .topLevel(capacity):
                guard capacity > 0, capacity <= Int(UInt32.max) else { return nil }
                descriptor = .init(maxInstanceCount: UInt32(capacity))
            }
            self.kind = kind
            self.context = context
            let slot = ResourceSlot<ResourceID>()
            self.slot = slot
            context.queue.enqueue { device in
                slot.fulfill(try await device.createAccelerationStructure(descriptor))
            }
        }

        deinit {
            let slot = self.slot
            context.queue.enqueue { device in
                if let id = try? slot.get() {
                    try await device.destroyAccelerationStructure(id)
                }
            }
        }
    }

    extension SAGACommandBuffer {
        func encodeBuild(of structure: any AccelerationStructure, geometry: AccelerationStructureGeometry) -> Bool {
            guard let destination = structure as? SAGAAccelerationStructure, destination.context === context,
                case let .bottomLevel(capacity) = destination.kind, geometry.triangleCount <= capacity,
                (try? geometry.validate()) != nil,
                let vertices = geometry.vertexBuffer as? SAGABuffer, vertices.context === context
            else { return false }
            let indices: SAGAIndexBuffer?
            if let indexBuffer = geometry.indexBuffer {
                guard let bound = indexBuffer as? SAGAIndexBuffer, bound.context === context else { return false }
                indices = bound
            } else {
                indices = nil
            }
            append {
                let indexBinding = try indices.map {
                    IndexBufferBinding(buffer: try $0.slot.get(), format: $0.indexFormat == .uInt16 ? .uint16 : .uint32)
                }
                return .buildAccelerationStructure(
                    destination: try destination.slot.get(),
                    geometry: SAGATypes.AccelerationStructureTriangleGeometry(
                        vertexBuffer: try vertices.slot.get(), vertexOffset: UInt64(geometry.vertexOffset),
                        vertexStride: UInt64(geometry.vertexStride), vertexCount: UInt32(geometry.vertexCount),
                        indexBuffer: indexBinding, indexCount: UInt32(geometry.indexCount)
                    )
                )
            }
            return true
        }

        func encodeBuild(of structure: any AccelerationStructure, instances: [AccelerationStructureInstance]) -> Bool {
            guard let destination = structure as? SAGAAccelerationStructure, destination.context === context,
                case let .topLevel(capacity) = destination.kind, !instances.isEmpty, instances.count <= capacity
            else { return false }
            var collected: [SAGAAccelerationStructure] = []
            for instance in instances {
                guard let bottom = instance.structure as? SAGAAccelerationStructure, bottom.context === context,
                    case .bottomLevel = bottom.kind
                else { return false }
                collected.append(bottom)
            }
            let bottoms = collected
            append {
                .buildTopLevelAccelerationStructure(
                    destination: try destination.slot.get(),
                    instances: try zip(instances, bottoms).map { instance, bottom in
                        SAGATypes.AccelerationStructureInstance(
                            accelerationStructure: try bottom.slot.get(), transform: instance.rowMajor3x4,
                            mask: instance.mask, instanceID: instance.instanceID
                        )
                    }
                )
            }
            return true
        }
    }
#endif
