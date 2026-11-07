import Foundation

/// Per-model import limits for resource pipelines that must bound work before CPU/GPU allocation.
/// General model imports retain their existing behavior when no limits are installed.
public struct ModelImportLimits: Sendable {
    public let maximumEncodedBytes: Int
    public let maximumDecodedBytes: Int

    public init(maximumEncodedBytes: Int = 64 * 1_024 * 1_024, maximumDecodedBytes: Int = 128 * 1_024 * 1_024) {
        self.maximumEncodedBytes = maximumEncodedBytes
        self.maximumDecodedBytes = maximumDecodedBytes
    }
}

/// Limits follow the structured asynchronous resource request without modifying process-wide loader configuration.
public enum ModelImportContext {
    @TaskLocal public static var limits: ModelImportLimits?
}

public enum ModelImportLimitError: LocalizedError, Equatable {
    case invalidLimits
    case encodedBudgetExceeded
    case decodedBudgetExceeded

    public var errorDescription: String? {
        switch self {
        case .invalidLimits: "Model import limits must be positive"
        case .encodedBudgetExceeded: "Model root and dependencies exceed the encoded import budget"
        case .decodedBudgetExceeded: "Model data exceed the decoded import budget"
        }
    }
}

/// Conservative accounting carried between importer and resource preparation stages.
@_spi(Internal) public struct ModelImportFootprint: Sendable {
    public let encodedBytes: Int
    public let decodedBytes: Int

    public init(encodedBytes: Int, decodedBytes: Int) {
        self.encodedBytes = encodedBytes
        self.decodedBytes = decodedBytes
    }
}
