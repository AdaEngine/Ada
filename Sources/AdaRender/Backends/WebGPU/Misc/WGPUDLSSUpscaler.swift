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
        /// NGX reports DLSS Ray Reconstruction on this adapter and driver.
        var supportsRayReconstruction: Bool { unsafe ada_dlss_device_supports_ray_reconstruction(handle) }

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
        private let inputSize: SizeInt
        private let outputSize: SizeInt
        /// Ray Reconstruction view, created on first use; its NGX feature is separate from Super Resolution's.
        private let rayReconstruction = Mutex<OpaquePointer?>(nil)
        private let rayReconstructionFailed = Mutex(false)

        var supportsDenoising: Bool { device.supportsRayReconstruction && !rayReconstructionFailed.withLock { $0 } }

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
            self.inputSize = inputSize
            self.outputSize = outputSize
        }

        deinit {
            let denoiser = rayReconstruction.withLock { $0 }
            webGPUDeviceLock.withLock { _ in
                unsafe ada_dlss_view_destroy(handle)
                if let denoiser { unsafe ada_dlss_view_destroy(denoiser) }
            }
        }

        func encodeDenoised(commandBuffer: CommandBuffer, color: Texture, depth: Texture, motion: Texture, reactive: Texture,
                            guides: RayReconstructionGuides, output: Texture, jitter: Vector2, reset: Bool) -> Bool {
            guard supportsDenoising,
                let command = commandBuffer as? WGPUCommandEncoder,
                let color = color.gpuTexture as? WGPUGPUTexture,
                let depth = depth.gpuTexture as? WGPUGPUTexture,
                let motion = motion.gpuTexture as? WGPUGPUTexture,
                let reactive = reactive.gpuTexture as? WGPUGPUTexture,
                let diffuse = guides.diffuseAlbedo.gpuTexture as? WGPUGPUTexture,
                let specular = guides.specularAlbedo.gpuTexture as? WGPUGPUTexture,
                let normals = guides.normalRoughness.gpuTexture as? WGPUGPUTexture,
                let output = output.gpuTexture as? WGPUGPUTexture,
                let width = UInt32(exactly: inputSize.width), let height = UInt32(exactly: inputSize.height),
                let outputWidth = UInt32(exactly: outputSize.width), let outputHeight = UInt32(exactly: outputSize.height)
            else { return false }
            let view: OpaquePointer? = rayReconstruction.withLock { view in
                if view == nil {
                    view = webGPUDeviceLock.withLock { _ in
                        unsafe ada_dlss_rr_view_create(device.handle, width, height, outputWidth, outputHeight)
                    }
                }
                return view
            }
            guard let view else {
                rayReconstructionFailed.withLock { $0 = true }
                return false
            }
            // NGX takes row-major matrices for row vectors, which is the column-major layout of these transforms.
            let worldToView = Self.floats(guides.worldToView)
            let viewToClip = Self.floats(guides.viewToClip)
            let encoded = command.withExternalGPUWork {
                unsafe worldToView.withUnsafeBufferPointer { worldToView in
                    unsafe viewToClip.withUnsafeBufferPointer { viewToClip in
                        unsafe ada_dlss_rr_evaluate(view, native(color.texture), native(depth.texture), native(motion.texture),
                            native(reactive.texture), native(diffuse.texture), native(specular.texture), native(normals.texture),
                            native(output.texture), jitter.x, jitter.y, worldToView.baseAddress, viewToClip.baseAddress, reset)
                    }
                }
            }
            if !encoded {
                rayReconstructionFailed.withLock { $0 = true }
                let reason = unsafe String(cString: ada_dlss_last_error())
                FileHandle.standardError.write(Data("AdaEngine DLSS Ray Reconstruction disabled: \(reason)\n".utf8))
            }
            return encoded
        }

        private static func floats(_ matrix: Transform3D) -> [Float] {
            [matrix.x.x, matrix.x.y, matrix.x.z, matrix.x.w, matrix.y.x, matrix.y.y, matrix.y.z, matrix.y.w,
             matrix.z.x, matrix.z.y, matrix.z.z, matrix.z.w, matrix.w.x, matrix.w.y, matrix.w.z, matrix.w.w]
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
