//
//  MetalRenderBackend.swift
//  AdaEngine
//
//  Created by v.prusakov on 10/20/21.
//

// TODO: (Vlad) We should support bgra8Unorm_srgb (Should we?)

#if METAL
    import AdaUtils
    import Math
    @unsafe @preconcurrency import Metal
    import MetalKit
    import ModelIO
    import OrderedCollections

    final class MetalRenderBackend: RenderBackend, @unchecked Sendable {
        private let context: Context
        let type: RenderBackendType = .metal

        private var commandQueue: MTLCommandQueue

        private(set) var renderDevice: RenderDevice

        init() {
            self.context = Context()
            guard let commandQueue = self.context.physicalDevice.makeCommandQueue() else {
                preconditionFailure("Metal failed to create a command queue.")
            }
            self.commandQueue = commandQueue

            self.renderDevice = MetalRenderDevice(
                device: self.context.physicalDevice,
                commandQueue: self.commandQueue,
                context: self.context
            )
        }

        func createLocalRenderDevice() -> RenderDevice {
            guard let commandQueue = self.context.physicalDevice.makeCommandQueue() else {
                preconditionFailure("Metal failed to create a local command queue.")
            }
            return MetalRenderDevice(
                device: self.context.physicalDevice,
                commandQueue: commandQueue
            )
        }

        func createWindow(_ windowId: WindowID, for surface: RenderSurface, size: SizeInt) throws {
            let mtlView = (surface as! MTKView)
            try self.context.createRenderWindow(with: windowId, view: mtlView, size: size)
        }

        func resizeWindow(_ windowId: WindowID, newSize: SizeInt) throws {
            guard newSize.width > 0 && newSize.height > 0 else {
                return
            }

            self.context.updateSizeForRenderWindow(windowId, size: newSize)
        }

        func destroyWindow(_ window: WindowID) throws {
            self.context.destroyWindow(by: window)
        }

        func getRenderWindow(for windowId: WindowID) -> RenderWindow? {
            guard let window = self.context.windows[windowId] else {
                return nil
            }

            return RenderWindow(
                windowId: windowId,
                height: window.size.height,
                width: window.size.width,
                scaleFactor: window.scaleFactor
            )
        }

        func getRenderWindows() throws -> RenderWindows {
            var windows = SparseSet<WindowID, RenderWindow>()
            for (id, window) in self.context.windows {
                windows[id] = RenderWindow(
                    windowId: id,
                    height: window.size.height,
                    width: window.size.width,
                    scaleFactor: window.scaleFactor
                )
            }

            return RenderWindows(windows: windows)
        }
    }

    // MARK: - Data

    extension IndexPrimitive {
        @inlinable
        @inline(__always)
        var toMetal: MTLPrimitiveType {
            switch self {
            case .line:
                return MTLPrimitiveType.line
            case .lineStrip:
                return MTLPrimitiveType.lineStrip
            case .points:
                return MTLPrimitiveType.point
            case .triangle:
                return MTLPrimitiveType.triangle
            case .triangleStrip:
                return MTLPrimitiveType.triangleStrip
            }
        }
    }

    extension MetalRenderBackend {
        struct InternalBuffer {
            var buffer: MTLBuffer
            var offset: Int
            var index: Int

            /// Only for index buffer
            var indexFormat: IndexBufferFormat?
        }

        struct PipelineState {
            var state: MTLRenderPipelineState?
        }
    }

    extension PixelFormat {
        var toMetal: MTLPixelFormat {
            #if MACOS
                if case .depth24_stencil8 = self {
                    return .depth24Unorm_stencil8
                }
            #endif

            switch self {
            case .depth_32f_stencil8:
                return .depth32Float_stencil8
            case .depth_32f:
                return .depth32Float
            case .bgra8:
                return .bgra8Unorm
            case .bgra8_srgb:
                return .bgra8Unorm_srgb
            case .rgba8:
                return .rgba8Unorm
            case .rgba_16f:
                return .rgba16Float
            case .rgba_32f:
                return .rgba32Float
            case .none:
                return .invalid
            default:
                return .invalid
            }
        }
    }

    extension BlendOperation {
        var toMetal: MTLBlendOperation {
            switch self {
            case .add:
                return .add
            case .subtract:
                return .subtract
            case .reverseSubtract:
                return .reverseSubtract
            case .min:
                return .min
            case .max:
                return .max
            }
        }
    }

    extension BlendFactor {
        var toMetal: MTLBlendFactor {
            switch self {
            case .zero:
                return .zero
            case .one:
                return .one
            case .sourceColor:
                return .sourceColor
            case .oneMinusSourceColor:
                return .oneMinusSourceColor
            case .destinationColor:
                return .destinationColor
            case .oneMinusDestinationColor:
                return .oneMinusDestinationColor
            case .sourceAlpha:
                return .sourceAlpha
            case .oneMinusSourceAlpha:
                return .oneMinusSourceAlpha
            case .destinationAlpha:
                return .destinationAlpha
            case .oneMinusDestinationAlpha:
                return .oneMinusDestinationAlpha
            case .sourceAlphaSaturated:
                return .sourceAlphaSaturated
            case .blendColor:
                return .blendColor
            case .oneMinusBlendColor:
                return .oneMinusBlendColor
            case .blendAlpha:
                return .blendAlpha
            case .oneMinusBlendAlpha:
                return .oneMinusBlendAlpha
            }
        }
    }

    extension Texture.TextureType {
        var toMetal: MTLTextureType {
            switch self {
            case .texture1D:
                return .type1D
            case .texture1DArray:
                return .type1DArray
            case .texture2D:
                return .type2D
            case .texture2DArray:
                return .type2DArray
            case .texture2DMultisample:
                return .type2DMultisample
            case .texture2DMultisampleArray:
                return .type2DMultisampleArray
            case .textureCube:
                return .typeCube
            case .texture3D:
                return .type3D
            case .textureBuffer:
                fatalError("Unsupported texture buffer type for Metal")
            }
        }
    }

    extension CompareOperation {
        var toMetal: MTLCompareFunction {
            switch self {
            case .never:
                return .never
            case .less:
                return .less
            case .equal:
                return .equal
            case .lessOrEqual:
                return .lessEqual
            case .greater:
                return .greater
            case .notEqual:
                return .notEqual
            case .greaterOrEqual:
                return .greaterEqual
            case .always:
                return .always
            }
        }
    }

    extension AttachmentLoadAction {
        var toMetal: MTLLoadAction {
            switch self {
            case .clear:
                return .clear
            case .dontCare:
                return .dontCare
            case .load:
                return .load
            }
        }
    }

    extension AttachmentStoreAction {
        var toMetal: MTLStoreAction {
            switch self {
            case .dontCare:
                return .dontCare
            case .store:
                return .store
            }
        }
    }

    extension Color {
        var toMetalClearColor: MTLClearColor {
            MTLClearColor(red: Double(self.red), green: Double(self.green), blue: Double(self.blue), alpha: Double(self.alpha))
        }
    }

    extension StencilOperation {
        var toMetal: MTLStencilOperation {
            switch self {
            case .zero:
                return .zero
            case .keep:
                return .keep
            case .replace:
                return .replace
            case .incrementAndClamp:
                return .incrementClamp
            case .decrementAndClamp:
                return .decrementClamp
            case .invert:
                return .invert
            case .incrementAndWrap:
                return .incrementWrap
            case .decrementAndWrap:
                return .decrementWrap
            }
        }
    }

    extension SamplerMinMagFilter {
        var toMetal: MTLSamplerMinMagFilter {
            switch self {
            case .nearest:
                return .nearest
            case .linear:
                return .linear
            }
        }
    }

    final class MetalRenderCommandBuffer: DrawCommandBuffer {
        let encoder: MTLRenderCommandEncoder
        let commandBuffer: MTLCommandBuffer

        init(encoder: MTLRenderCommandEncoder, commandBuffer: MTLCommandBuffer) {
            self.encoder = encoder
            self.commandBuffer = commandBuffer
        }
    }

#endif

/// A protocol that defines a draw command buffer.
public protocol DrawCommandBuffer: Sendable {
}
