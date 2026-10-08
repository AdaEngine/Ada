import AdaAssets
import AdaECS
@testable import AdaScripting
import Foundation

@Component
struct AsyncPosition {
    var value: Double
}

// The delayed decoder proves that ECS frames advance while native asset work waits.
final class AsyncTextAsset: Asset, @unchecked Sendable {
    var assetMetaInfo: AssetMetaInfo?
    let value: String

    init(value: String) { self.value = value }
    init(from decoder: any AssetDecoder) async throws {
        let decoded = try decoder.decode(String.self)
        try await Task.sleep(for: .milliseconds(80))
        value = decoded
    }
    func encodeContents(with encoder: any AssetEncoder) throws { try encoder.encode(value) }
    static func extensions() -> [String] { ["asynctext"] }
}

func waitForOperation(_ operation: AdaScriptAsyncOperation) async throws -> AdaScriptAsyncResult {
    for _ in 0..<100 where !operation.isDone() {
        try await Task.sleep(for: .milliseconds(10))
    }
    return operation.result()
}
