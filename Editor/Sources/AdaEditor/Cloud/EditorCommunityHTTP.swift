import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One bounded unauthenticated request. Mutable state is serialized by URLSession's delegate queue.
final class EditorCommunityHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var data = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    private let maximumBytes = 16 * 1024 * 1024

    static func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let delegate = EditorCommunityHTTP()
        let task = MutexTask()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.timeoutIntervalForRequest = 30
                let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
                delegate.session = session
                task.install(session.dataTask(with: request))
            }
        } onCancel: { task.cancel() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel); return
        }
        self.response = response
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= maximumBytes - self.data.count else { dataTask.cancel(); return }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Files and manifests must stay at the approved publication origin and release.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer { continuation = nil; self.session = nil; session.finishTasksAndInvalidate() }
        if let error { continuation?.resume(throwing: error) }
        else if let response { continuation?.resume(returning: (data, response)) }
        else { continuation?.resume(throwing: EditorCommunityClient.CommunityError.invalidResponse) }
    }

    private final class MutexTask: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false
        func install(_ task: URLSessionDataTask) {
            lock.withLock { self.task = task; if cancelled { task.cancel() }; task.resume() }
        }
        func cancel() { lock.withLock { cancelled = true; task?.cancel() } }
    }
}
