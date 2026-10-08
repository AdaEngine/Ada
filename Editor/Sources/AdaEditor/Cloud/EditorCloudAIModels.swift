import Foundation

// Public wallet contracts only. Provider credentials and settlement belong to Ada Cloud.
enum EditorAICapability: String, Codable, Sendable, CaseIterable {
    case llm, image, mesh, rigging, animation, voice
}

struct EditorAIUsage: Codable, Sendable, Equatable {
    var inputTokens: Int64 = 0
    var outputTokens: Int64 = 0
    var units: Int64 = 0
    var audioSeconds: Int64 = 0
    var replyCharacters: Int64 = 0

    func validate() throws {
        guard (0...200_000).contains(inputTokens), (0...16_000).contains(outputTokens),
              (0...16).contains(units), (0...600).contains(audioSeconds), (0...10_000).contains(replyCharacters) else {
            throw EditorAIError.invalidResponse
        }
    }

    enum CodingKeys: String, CodingKey { case inputTokens, outputTokens, units, audioSeconds, replyCharacters }

    init(inputTokens: Int64 = 0, outputTokens: Int64 = 0, units: Int64 = 0, audioSeconds: Int64 = 0, replyCharacters: Int64 = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.units = units
        self.audioSeconds = audioSeconds
        self.replyCharacters = replyCharacters
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try values.decodeIfPresent(Int64.self, forKey: .inputTokens) ?? 0
        outputTokens = try values.decodeIfPresent(Int64.self, forKey: .outputTokens) ?? 0
        units = try values.decodeIfPresent(Int64.self, forKey: .units) ?? 0
        audioSeconds = try values.decodeIfPresent(Int64.self, forKey: .audioSeconds) ?? 0
        replyCharacters = try values.decodeIfPresent(Int64.self, forKey: .replyCharacters) ?? 0
    }
}

struct EditorAIQuoteRequest: Codable, Sendable, Equatable {
    var operationID: String
    var requestDigest: String
    var capability: EditorAICapability
    var maximum: EditorAIUsage

    func validate() throws {
        guard !operationID.isEmpty, operationID.utf8.count <= 100, requestDigest.utf8.count == 64,
              requestDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw EditorAIError.invalidResponse
        }
        try maximum.validate()
    }
}

struct EditorAICatalog: Decodable, Sendable {
    struct Plan: Decodable, Sendable {
        var id: String
        var monthlyMicrocredits: Int64
    }
    var enabled: Bool
    var availability: EditorCloudValue
    var tariffVersion: String
    var microcreditsPerCredit: Int64
    var plans: [Plan]
    // Unknown future capabilities need not break balance display in an older Studio.
    var capabilities: [String]
}

struct EditorAIBalance: Decodable, Sendable, Equatable {
    var accountID: String
    var cycleStart: Int64
    var cycleEnd: Int64
    var allowance: Int64
    var spent: Int64
    var reserved: Int64
    var available: Int64
    var suspended: Bool
    var closed: Bool
    var scale: Int64

    func validate(owner: String) throws {
        guard let expected = UUID(uuidString: owner), UUID(uuidString: accountID) == expected,
              scale == EditorAICreditAmount.scale, allowance >= 0, spent >= 0, reserved >= 0, available >= 0,
              cycleStart >= 0, cycleEnd >= cycleStart, cycleEnd <= 32_503_680_000 else { throw EditorAIError.invalidResponse }
        // Successive subtraction avoids overflow for malformed responses, including spent > allowance after a refund.
        let remainder = max(0, allowance - spent)
        guard available == max(0, remainder - reserved) else { throw EditorAIError.invalidResponse }
    }
}

struct EditorAIQuote: Decodable, Sendable, Equatable {
    var id: String
    var accountID: String
    var request: EditorAIQuoteRequest
    var region: String
    var country: String?
    var tariffVersion: String
    var maximumMicrocredits: Int64
    var expiresAt: Int64
}

struct EditorAIReservation: Decodable, Sendable, Equatable {
    enum State: String, Decodable, Sendable { case reserved, started, reconciliationRequired, settled, released }
    var id: String
    var accountID: String
    var quote: EditorAIQuote
    var cycleStart: Int64
    var state: State
    var expiresAt: Int64
    var executionID: String?
    var settlementID: String?
    var chargedMicrocredits: Int64
    var usage: EditorAIUsage?
}

struct EditorAIUsagePage: Decodable, Sendable {
    struct Entry: Decodable, Sendable, Identifiable {
        var cursor: Int64
        var cycleStart: Int64
        var operationID: String
        var kind: String
        var microcredits: Int64
        var createdAt: Int64
        var id: Int64 { cursor }
    }
    var items: [Entry]
    var nextCursor: Int64
    var scale: Int64
}

enum EditorAICreditAmount {
    static let scale: Int64 = 1_000_000

    /// Exact microcredit formatting, including a single microcredit and Int64.min ledger adjustments.
    static func text(_ microcredits: Int64) -> String {
        let magnitude = microcredits.magnitude
        let whole = magnitude / UInt64(scale)
        let remainder = magnitude % UInt64(scale)
        let sign = microcredits < 0 ? "−" : ""
        guard remainder != 0 else {
            return "\(sign)\(whole)"
        }
        var fraction = String(remainder + UInt64(scale)).dropFirst().description
        while fraction.last == "0" { fraction.removeLast() }
        return "\(sign)\(whole).\(fraction)"
    }
}

enum EditorAIError: LocalizedError {
    case invalidResponse
    case sessionChanged
    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid AI credits response."
        case .sessionChanged: "The Cloud account changed. Please retry."
        }
    }
}
