import Foundation

#if WASM && canImport(JavaScriptFoundationCompat) && canImport(JavaScriptKit)
    import JavaScriptEventLoop
    import JavaScriptFoundationCompat
    import JavaScriptKit
#endif

extension AssetsManager {
    #if WASM && canImport(JavaScriptFoundationCompat) && canImport(JavaScriptKit)
        /// JavaScript objects remain on the browser executor across promise suspensions.
        @MainActor
        static func readBoundedResponse(url: String, maximumBytes: Int) async throws -> Data {
            guard let constructor = JSObject.global.AbortController.function else {
                throw AssetError.message("Browser AbortController is unavailable")
            }
            let controller = constructor.new()
            let abort: @MainActor @Sendable () -> Void = { _ = controller.abort?() }
            return try await withTaskCancellationHandler {
                defer { abort() }
                try Task.checkCancellation()
                let options = JSObject.global.Object.function?.new()
                guard let options else { throw AssetError.message("Browser fetch options are unavailable") }
                options.signal = controller.signal
                guard let request = try JSObject.global.throwing.fetch?(url, options),
                    let promise = JSPromise.construct(from: request),
                    let response = try await promise.value(isolation: MainActor.shared).object
                else {
                    throw AssetError.message("Browser fetch returned an invalid response for \(url)")
                }
                try Task.checkCancellation()
                guard response.ok.boolean == true else { throw AssetError.notExistAtPath(url) }
                if response.body.isNull {
                    return Data()
                }
                guard let body = response.body.object,
                    let reader = try body.throwing.getReader?().object
                else {
                    throw AssetError.message("Browser response streaming is unavailable for \(url)")
                }
                defer {
                    // The outer abort closes the request on errors/cancellation, without an unobserved cancel promise.
                    _ = try? reader.throwing.releaseLock?()
                }
                var data = Data()
                while true {
                    try Task.checkCancellation()
                    guard let next = try reader.throwing.read?(),
                        let pending = JSPromise.construct(from: next),
                        let result = try await pending.value(isolation: MainActor.shared).object
                    else {
                        throw AssetError.message("Browser response stream returned an invalid chunk for \(url)")
                    }
                    try Task.checkCancellation()
                    if result.done.boolean == true {
                        return data
                    }
                    guard let chunk = result.value.object, let length = chunk.byteLength.number,
                        length.isFinite, length >= 0, length.rounded(.down) == length
                    else {
                        throw AssetError.message("Browser response stream returned invalid bytes for \(url)")
                    }
                    guard length <= Double(maximumBytes - data.count) else {
                        throw AssetError.encodedSizeLimitExceeded(path: url, limit: maximumBytes)
                    }
                    guard let bytes = Data.construct(from: .object(chunk)), Double(bytes.count) == length else {
                        throw AssetError.message("Browser response bytes could not be read for \(url)")
                    }
                    data.append(bytes)
                }
            } onCancel: {
                // Cancellation handlers are synchronous; the abort must run on the JavaScript executor.
                Task { @MainActor in abort() }
            }
        }
    #else
        @concurrent
        static func readBoundedFile(url: URL, maximumBytes: Int) async throws -> Data {
            try Task.checkCancellation()
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw AssetError.notExistAtPath(url.path)
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard try handle.seekToEnd() <= UInt64(maximumBytes) else {
                throw AssetError.encodedSizeLimitExceeded(path: url.path, limit: maximumBytes)
            }
            try handle.seek(toOffset: 0)
            var data = Data()
            // The file can grow after the size check. Read at most one byte beyond the remaining budget.
            while true {
                try Task.checkCancellation()
                let remaining = maximumBytes - data.count
                let count = remaining >= 65_536 ? 65_536 : remaining + 1
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
                    return data
                }
                guard chunk.count <= remaining else {
                    throw AssetError.encodedSizeLimitExceeded(path: url.path, limit: maximumBytes)
                }
                data.append(chunk)
            }
        }
    #endif
}
