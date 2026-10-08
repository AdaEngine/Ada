import Foundation

/// Authenticated public AI API. The transport uses the existing Cloud session and token refresh.
@MainActor
struct EditorCloudAIClient {
    typealias Transport = @MainActor (String, String, EditorCloudValue?) async throws -> EditorCloudValue
    let owner: String
    let transport: Transport

    func catalog() async throws -> EditorAICatalog {
        let catalog: EditorAICatalog = try await get("/ai/catalog")
        guard catalog.microcreditsPerCredit == EditorAICreditAmount.scale,
              catalog.plans.allSatisfy({ $0.monthlyMicrocredits >= 0 }) else { throw EditorAIError.invalidResponse }
        return catalog
    }

    func balance() async throws -> EditorAIBalance {
        let balance: EditorAIBalance = try await get("/ai/balance")
        try balance.validate(owner: owner)
        return balance
    }

    func usage(after cursor: Int64 = 0) async throws -> EditorAIUsagePage {
        guard cursor >= 0 else { throw EditorAIError.invalidResponse }
        let page: EditorAIUsagePage = try await get("/ai/usage?after=\(cursor)")
        guard page.scale == EditorAICreditAmount.scale, page.items.count <= 50,
              page.nextCursor >= cursor else { throw EditorAIError.invalidResponse }
        var previous = cursor
        for item in page.items {
            guard item.cursor > previous, item.cursor <= page.nextCursor else { throw EditorAIError.invalidResponse }
            previous = item.cursor
        }
        guard page.nextCursor == (page.items.last?.cursor ?? cursor) else { throw EditorAIError.invalidResponse }
        return page
    }

    // Preserve operationID and digest on retries: the server owns tariff selection and deduplication.
    func quote(_ input: EditorAIQuoteRequest) async throws -> EditorAIQuote {
        try input.validate()
        let quote: EditorAIQuote = try await send("/ai/quotes", body: value(input))
        try validate(quote)
        guard quote.request == input else { throw EditorAIError.invalidResponse }
        return quote
    }

    func reserve(quoteID: String) async throws -> EditorAIReservation {
        try validateID(quoteID)
        let reservation: EditorAIReservation = try await send("/ai/reservations", body: ["quoteID": .string(quoteID)])
        try validate(reservation)
        guard UUID(uuidString: reservation.quote.id) == UUID(uuidString: quoteID) else { throw EditorAIError.invalidResponse }
        return reservation
    }

    func reservation(id: String) async throws -> EditorAIReservation {
        try validateID(id)
        let reservation: EditorAIReservation = try await get("/ai/reservations/\(id)")
        try validate(reservation)
        guard UUID(uuidString: reservation.id) == UUID(uuidString: id) else { throw EditorAIError.invalidResponse }
        return reservation
    }

    func cancel(id: String) async throws -> EditorAIReservation {
        try validateID(id)
        let reservation: EditorAIReservation = try await send("/ai/reservations/\(id)/cancel", body: nil)
        try validate(reservation)
        guard UUID(uuidString: reservation.id) == UUID(uuidString: id) else { throw EditorAIError.invalidResponse }
        return reservation
    }

    private func validateID(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw EditorAIError.invalidResponse }
    }

    private func validate(_ quote: EditorAIQuote) throws {
        try validateID(quote.id)
        guard let expected = UUID(uuidString: owner), UUID(uuidString: quote.accountID) == expected,
              quote.maximumMicrocredits >= 0, quote.expiresAt > 0 else { throw EditorAIError.invalidResponse }
        try quote.request.validate()
    }

    private func validate(_ reservation: EditorAIReservation) throws {
        try validateID(reservation.id)
        try validate(reservation.quote)
        guard UUID(uuidString: reservation.accountID) == UUID(uuidString: owner), reservation.chargedMicrocredits >= 0 else {
            throw EditorAIError.invalidResponse
        }
        try reservation.usage?.validate()
    }

    private func value<T: Encodable>(_ body: T) throws -> EditorCloudValue {
        try JSONDecoder().decode(EditorCloudValue.self, from: JSONEncoder().encode(body))
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try await response(path, method: "GET", body: nil)
    }

    private func send<T: Decodable>(_ path: String, body: EditorCloudValue?) async throws -> T {
        try await response(path, method: "POST", body: body)
    }

    private func response<T: Decodable>(_ path: String, method: String, body: EditorCloudValue?) async throws -> T {
        let result = try await transport(path, method, body)
        do {
            return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(result))
        } catch {
            throw EditorAIError.invalidResponse
        }
    }
}
