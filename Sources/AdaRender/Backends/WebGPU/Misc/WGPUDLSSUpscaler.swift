#if os(Windows) && WEBGPU_ENABLED && canImport(CWebGPUDLSS) && canImport(WebGPU)
    import AdaUtils
    import CWebGPUDLSS
    import Foundation
    import Math
    import Synchronization
    @unsafe @preconcurrency import WebGPU

    /// All native calls are serialized with Dawn queue submission by webGPUDeviceLock.
    // Native pointers never escape the backend; ownership and every native access are synchronized.
    @safe final class WGPUDLSSDevice: @unchecked Sendable {
        let handle: OpaquePointer
        private let available = Mutex(true)
        var isAvailable: Bool { available.withLock { $0 } }

        init?(device: WebGPU.GPUDevice) {
            guard ProcessInfo.processInfo.environment["ADAENGINE_DISABLE_DLSS"] != "1" else { return nil }
            // Swan imports the C opaque handles as pointer-sized foreign references.
            // Keep its API-notes ownership declarations out of the bridge's C module.
            guard let handle = unsafe ada_dlss_device_create(unsafeBitCast(device, to: UnsafeMutableRawPointer.self)) else {
                let reason = unsafe String(cString: ada_dlss_last_error())
                FileHandle.standardError.write(Data("AdaEngine DLSS unavailable: \(reason)\n".utf8))
                return nil
            }
            self.handle = handle
        }

        deinit {
            webGPUDeviceLock.withLock { _ in unsafe ada_dlss_device_destroy(handle) }
        }

        func disableAfterFailure() {
            let first = available.withLock { value in
                let previous = value
                value = false
                return previous
            }
            if first {
                let reason = unsafe String(cString: ada_dlss_last_error())
                FileHandle.standardError.write(Data("AdaEngine DLSS disabled after evaluation failure: \(reason)\n".utf8))
            }
        }
    }

    @safe final class WGPUDLSSUpscaler: TemporalUpscaler, @unchecked Sendable {
        private let device: WGPUDLSSDevice
        private let handle: OpaquePointer

        init?(device: WGPUDLSSDevice, inputSize: SizeInt, outputSize: SizeInt) {
            guard inputSize.width > 0, inputSize.height > 0,
                outputSize.width >= inputSize.width, outputSize.height >= inputSize.height,
                let width = UInt32(exactly: inputSize.width), let height = UInt32(exactly: inputSize.height),
                let outputWidth = UInt32(exactly: outputSize.width), let outputHeight = UInt32(exactly: outputSize.height)
            else { return nil }
            let created = webGPUDeviceLock.withLock { _ in
                unsafe ada_dlss_view_create(device.handle, width, height, outputWidth, outputHeight)
            }
            guard let created else { return nil }
            self.device = device
            self.handle = created
        }

        deinit {
            webGPUDeviceLock.withLock { _ in unsafe ada_dlss_view_destroy(handle) }
        }

        func encode(commandBuffer: CommandBuffer, color: Texture, depth: Texture, motion: Texture,
                    reactive: Texture, output: Texture, jitter: Vector2, reset: Bool) -> Bool {
            guard let command = commandBuffer as? WGPUCommandEncoder,
                let color = color.gpuTexture as? WGPUGPUTexture,
                let depth = depth.gpuTexture as? WGPUGPUTexture,
                let motion = motion.gpuTexture as? WGPUGPUTexture,
                let reactive = reactive.gpuTexture as? WGPUGPUTexture,
                let output = output.gpuTexture as? WGPUGPUTexture
            else { return false }
            let encoded = command.withExternalGPUWork {
                unsafe ada_dlss_evaluate(handle, native(color.texture), native(depth.texture), native(motion.texture),
                    native(reactive.texture), native(output.texture), jitter.x, jitter.y, reset)
            }
            if !encoded { device.disableAfterFailure() }
            return encoded
        }

        private func native(_ texture: WebGPU.GPUTexture) -> UnsafeMutableRawPointer {
            unsafe unsafeBitCast(texture, to: UnsafeMutableRawPointer.self)
        }
    }
#endif
