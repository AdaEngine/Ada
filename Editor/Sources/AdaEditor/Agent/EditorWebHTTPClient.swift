import Foundation

struct EditorWebHTTPResponse: Sendable {
    let data: Data
    let url: URL
    let mimeType: String
    let textEncodingName: String?
}

protocol EditorWebHTTPClient: Sendable {
    func get(_ url: URL, maxBytes: Int) async throws -> EditorWebHTTPResponse
}

struct EditorWebToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Redirects are followed explicitly, so every target passes the same URL validation.
private final class EditorWebRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct EditorWebURLSessionClient: EditorWebHTTPClient {
    func get(_ url: URL, maxBytes: Int) async throws -> EditorWebHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: EditorWebRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var current = url
        for redirect in 0...5 {
            try Self.validate(current)
            try Task.checkCancellation()
            var request = URLRequest(url: current)
            request.setValue("AdaEditor/1.0", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw EditorWebToolError("Expected an HTTP response.") }
            if [301, 302, 303, 307, 308].contains(http.statusCode) {
                guard redirect < 5, let location = http.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: current)?.absoluteURL else {
                    throw EditorWebToolError("Invalid redirect or more than five redirects.")
                }
                current = next
                continue
            }
            guard (200..<300).contains(http.statusCode) else { throw EditorWebToolError("HTTP \(http.statusCode) from \(current.host ?? "server").") }
            guard response.expectedContentLength <= Int64(maxBytes) else { throw EditorWebToolError("Response exceeds the \(maxBytes)-byte limit.") }
            var data = Data()
            data.reserveCapacity(min(maxBytes, 64 * 1024))
            for try await byte in bytes {
                guard data.count < maxBytes else { throw EditorWebToolError("Response exceeds the \(maxBytes)-byte limit.") }
                data.append(byte)
                if data.count % (64 * 1024) == 0 { try Task.checkCancellation() }
            }
            return EditorWebHTTPResponse(data: data, url: current, mimeType: response.mimeType ?? "application/octet-stream", textEncodingName: response.textEncodingName)
        }
        throw EditorWebToolError("Too many redirects.")
    }

    static func validate(_ url: URL) throws {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else {
            throw EditorWebToolError("Use an HTTP(S) URL without embedded credentials.")
        }
        guard host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"),
              host != "[::1]", host != "::1", host != "0.0.0.0" else {
            throw EditorWebToolError("Local network URLs are unavailable to web tools.")
        }
        let address = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let octets = address.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
            guard ![0, 10, 127].contains(octets[0]),
                  !(octets[0] == 169 && octets[1] == 254),
                  !(octets[0] == 172 && (16...31).contains(octets[1])),
                  !(octets[0] == 192 && octets[1] == 168), octets[0] < 224 else {
                throw EditorWebToolError("Local network addresses are unavailable to web tools.")
            }
        }
        if address.contains(":") {
            guard address != "::", !address.hasPrefix("fc"), !address.hasPrefix("fd"),
                  !address.hasPrefix("fe8"), !address.hasPrefix("fe9"), !address.hasPrefix("fea"),
                  !address.hasPrefix("feb"), !address.hasPrefix("ff"), !address.hasPrefix("::ffff:") else {
                throw EditorWebToolError("Local network addresses are unavailable to web tools.")
            }
        }
    }
}
