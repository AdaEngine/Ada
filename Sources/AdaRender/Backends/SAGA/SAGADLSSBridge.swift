//
//  SAGADLSSBridge.swift
//  AdaEngine
//
//  Loads the optional NGX bridge (`Tools/NGXBridge`) at run time. The NVIDIA SDK is never linked into AdaEngine.
//

#if SAGA_RENDER && SAGA_NATIVE && os(Windows) && canImport(SAGAVulkan) && canImport(SAGACompiler)
    import Foundation
    import WinSDK

    /// The C ABI structures of `Tools/NGXBridge/ada_ngx.h`. Field order and types mirror the header.
    struct DLSSBridgeImage {
        var image: UInt64
        var view: UInt64
        var format: UInt32
        var width: UInt32
        var height: UInt32
        var aspect: UInt32
    }

    struct DLSSBridgeDescription {
        var inputWidth: UInt32
        var inputHeight: UInt32
        var outputWidth: UInt32
        var outputHeight: UInt32
        var quality: Int32
        var flags: UInt32
    }

    struct DLSSBridgeFrame {
        var color: DLSSBridgeImage
        var depth: DLSSBridgeImage
        var motion: DLSSBridgeImage
        var output: DLSSBridgeImage
        var jitterX: Float
        var jitterY: Float
        var motionScaleX: Float
        var motionScaleY: Float
        var inputWidth: UInt32
        var inputHeight: UInt32
        var reset: Int32
    }

    /// Ray Reconstruction frame; the matrices are in the memory order of `Transform3D`.
    struct DLSSDBridgeFrame {
        var color: DLSSBridgeImage
        var depth: DLSSBridgeImage
        var motion: DLSSBridgeImage
        var output: DLSSBridgeImage
        var diffuseAlbedo: DLSSBridgeImage
        var specularAlbedo: DLSSBridgeImage
        var normalRoughness: DLSSBridgeImage
        var worldToView: InlineArray<16, Float>
        var viewToClip: InlineArray<16, Float>
        var jitterX: Float
        var jitterY: Float
        var motionScaleX: Float
        var motionScaleY: Float
        var inputWidth: UInt32
        var inputHeight: UInt32
        var reset: Int32
    }

    /// A loaded `adaengine_ngx` library. NGX results are `NVSDK_NGX_Result`; 1 is success.
    final class DLSSBridge: @unchecked Sendable {
        static let abiVersion: UInt32 = 3
        static let success: Int32 = 1

        private typealias RequiredExtensions = @convention(c) (
            UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UnsafePointer<UnsafePointer<CChar>?>?>,
            UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UnsafePointer<UnsafePointer<CChar>?>?>
        ) -> Int32
        private typealias Initialize = @convention(c) (
            UInt64, UInt64, UInt64, UnsafeRawPointer?, UnsafeRawPointer?, UnsafePointer<UInt16>?, UnsafePointer<UInt16>?
        ) -> Int32
        private typealias Supported = @convention(c) () -> Int32
        private typealias Shutdown = @convention(c) (UInt64) -> Void
        private typealias Create = @convention(c) (
            UInt64, UInt64, UnsafeRawPointer, UnsafeMutablePointer<UnsafeMutableRawPointer?>
        ) -> Int32
        private typealias Evaluate = @convention(c) (UInt64, UnsafeMutableRawPointer, UnsafeRawPointer) -> Int32
        private typealias Release = @convention(c) (UnsafeMutableRawPointer?) -> Void

        let directory: String
        private let requiredExtensionsFunction: RequiredExtensions
        private let initializeFunction: Initialize
        private let supportedFunction: Supported
        private let shutdownFunction: Shutdown
        private let createFunction: Create
        private let evaluateFunction: Evaluate
        private let releaseFunction: Release
        private let denoiserSupportedFunction: Supported
        private let createDenoiserFunction: Create
        private let evaluateDenoiserFunction: Evaluate

        /// Loads the bridge from `directory`; nil when it is missing, has another ABI version or lacks a function.
        init?(directory: String) {
            self.directory = directory
            let path = directory + "/" + DLSSRuntime.bridgeName
            guard let library = Self.open(path) else { return nil }
            func symbol<T>(_ name: String, as _: T.Type) -> T? {
                Self.symbol(library, name).map { unsafeBitCast($0, to: T.self) }
            }
            guard let version = symbol("ada_ngx_abi_version", as: (@convention(c) () -> UInt32).self), version() == Self.abiVersion,
                let required = symbol("ada_ngx_required_extensions", as: RequiredExtensions.self),
                let initialize = symbol("ada_ngx_init", as: Initialize.self),
                let supported = symbol("ada_ngx_dlss_supported", as: Supported.self),
                let shutdown = symbol("ada_ngx_shutdown", as: Shutdown.self),
                let create = symbol("ada_ngx_dlss_create", as: Create.self),
                let evaluate = symbol("ada_ngx_dlss_evaluate", as: Evaluate.self),
                let release = symbol("ada_ngx_dlss_release", as: Release.self),
                let denoiserSupported = symbol("ada_ngx_dlssd_supported", as: Supported.self),
                let createDenoiser = symbol("ada_ngx_dlssd_create", as: Create.self),
                let evaluateDenoiser = symbol("ada_ngx_dlssd_evaluate", as: Evaluate.self)
            else { return nil }
            requiredExtensionsFunction = required
            initializeFunction = initialize
            supportedFunction = supported
            shutdownFunction = shutdown
            createFunction = create
            evaluateFunction = evaluate
            releaseFunction = release
            denoiserSupportedFunction = denoiserSupported
            createDenoiserFunction = createDenoiser
            evaluateDenoiserFunction = evaluateDenoiser
        }

        /// Whether DLSS Ray Reconstruction is usable; valid after initialize(instance:physicalDevice:device:instanceProcedure:deviceProcedure:dataDirectory:).
        var supportsDenoising: Bool { denoiserSupportedFunction() == 1 }

        func createDenoiser(device: UInt, commandBuffer: UInt, description: DLSSBridgeDescription) -> (result: Int32, handle: UnsafeMutableRawPointer?) {
            var handle: UnsafeMutableRawPointer?
            let result = withUnsafePointer(to: description) { createDenoiserFunction(UInt64(device), UInt64(commandBuffer), $0, &handle) }
            return (result, handle)
        }

        func evaluateDenoiser(commandBuffer: UInt, handle: UnsafeMutableRawPointer, frame: DLSSDBridgeFrame) -> Int32 {
            withUnsafePointer(to: frame) { evaluateDenoiserFunction(UInt64(commandBuffer), handle, $0) }
        }

        /// The Vulkan extensions NGX needs enabled when the instance and device are created.
        func requiredExtensions() -> (instance: [String], device: [String])? {
            var instanceCount: UInt32 = 0
            var deviceCount: UInt32 = 0
            var instanceNames: UnsafePointer<UnsafePointer<CChar>?>?
            var deviceNames: UnsafePointer<UnsafePointer<CChar>?>?
            guard requiredExtensionsFunction(&instanceCount, &instanceNames, &deviceCount, &deviceNames) == Self.success else { return nil }
            func strings(_ names: UnsafePointer<UnsafePointer<CChar>?>?, _ count: UInt32) -> [String] {
                guard let names else { return [] }
                return (0..<Int(count)).compactMap { names[$0].map { String(cString: $0) } }
            }
            return (strings(instanceNames, instanceCount), strings(deviceNames, deviceCount))
        }

        /// Initializes NGX on the device and reports whether DLSS Super Resolution is usable on it.
        func initialize(
            instance: UInt, physicalDevice: UInt, device: UInt, instanceProcedure: UnsafeRawPointer?, deviceProcedure: UnsafeRawPointer?,
            dataDirectory: String
        ) -> (result: Int32, supported: Bool) {
            let result = dataDirectory.withCString(encodedAs: UTF16.self) { data in
                directory.withCString(encodedAs: UTF16.self) { feature in
                    initializeFunction(UInt64(instance), UInt64(physicalDevice), UInt64(device), instanceProcedure, deviceProcedure, data, feature)
                }
            }
            return (result, result == Self.success && supportedFunction() == 1)
        }

        func shutdown(device: UInt) { shutdownFunction(UInt64(device)) }

        func createFeature(device: UInt, commandBuffer: UInt, description: DLSSBridgeDescription) -> (result: Int32, handle: UnsafeMutableRawPointer?) {
            var handle: UnsafeMutableRawPointer?
            let result = withUnsafePointer(to: description) { createFunction(UInt64(device), UInt64(commandBuffer), $0, &handle) }
            return (result, handle)
        }

        func evaluate(commandBuffer: UInt, handle: UnsafeMutableRawPointer, frame: DLSSBridgeFrame) -> Int32 {
            withUnsafePointer(to: frame) { evaluateFunction(UInt64(commandBuffer), handle, $0) }
        }

        func release(_ handle: UnsafeMutableRawPointer?) { releaseFunction(handle) }

        private static func open(_ path: String) -> UnsafeMutableRawPointer? {
            path.withCString(encodedAs: UTF16.self) { LoadLibraryW($0) }.map { UnsafeMutableRawPointer($0) }
        }

        private static func symbol(_ library: UnsafeMutableRawPointer, _ name: String) -> UnsafeMutableRawPointer? {
            GetProcAddress(HMODULE(OpaquePointer(library)), name).map { unsafeBitCast($0, to: UnsafeMutableRawPointer.self) }
        }
    }
#endif
