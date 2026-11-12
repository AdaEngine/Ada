//
//  JSBrowserTransport.swift
//  AdaEngine
//

#if SAGA_WEBGPU && canImport(SAGAWebHost) && canImport(JavaScriptKit)
    import JavaScriptKit
    import SAGATypes
    import SAGAWebHost

    /// Sends SAGA opcode packets to the page's JavaScript WebGPU host (`host.handle(Uint8Array)`).
    struct JSBrowserTransport: BrowserTransport, @unchecked Sendable {
        let host: JSObject

        func send(_ bytes: [UInt8]) async throws -> [UInt8] {
            let request = JSTypedArray<UInt8>(bytes)
            guard let pending = host.handle?(request).object, let promise = JSPromise(pending) else {
                throw GPUError.backendFailure("SAGA browser host returned no promise")
            }
            let reply: JSValue = try await withCheckedThrowingContinuation { continuation in
                _ = promise.then(
                    success: { value in
                        continuation.resume(returning: value)
                        return JSValue.undefined
                    },
                    failure: { error in
                        continuation.resume(throwing: GPUError.backendFailure(error.description))
                        return JSValue.undefined
                    }
                )
            }
            guard let array = JSTypedArray<UInt8>(from: reply) else {
                throw GPUError.backendFailure("SAGA browser host returned a non-byte reply")
            }
            return array.withUnsafeBytes { unsafe Array($0) }
        }
    }
#endif
