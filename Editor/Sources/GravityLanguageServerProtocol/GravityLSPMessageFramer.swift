import Foundation

public enum GravityLSPFramingError: Error, Equatable, Sendable {
    case contentTooLarge(Int)
    case invalidContentLength
    case invalidHeader
}

public struct GravityLSPMessageFramer: Sendable {
    private static let headerSeparator = Data("\r\n\r\n".utf8)
    private static let maximumHeaderLength = 8 * 1_024
    private static let maximumContentLength = 16 * 1_024 * 1_024
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var messages: [Data] = []
        while let headerRange = buffer.range(of: Self.headerSeparator) {
            let headerData = buffer[..<headerRange.lowerBound]
            guard headerData.count <= Self.maximumHeaderLength else {
                throw GravityLSPFramingError.invalidHeader
            }
            guard let header = String(bytes: headerData, encoding: .utf8) else {
                throw GravityLSPFramingError.invalidHeader
            }
            guard let contentLength = Self.contentLength(from: header), contentLength >= 0 else {
                throw GravityLSPFramingError.invalidContentLength
            }
            guard contentLength <= Self.maximumContentLength else {
                throw GravityLSPFramingError.contentTooLarge(contentLength)
            }
            let contentStart = headerRange.upperBound
            guard buffer.count - contentStart >= contentLength else {
                break
            }
            let contentEnd = contentStart + contentLength
            messages.append(buffer.subdata(in: contentStart..<contentEnd))
            buffer.removeSubrange(buffer.startIndex..<contentEnd)
        }
        if buffer.range(of: Self.headerSeparator) == nil, buffer.count > Self.maximumHeaderLength {
            throw GravityLSPFramingError.invalidHeader
        }
        return messages
    }

    public static func frame(_ message: [String: Any]) throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: message)
        var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        framed.append(body)
        return framed
    }

    private static func contentLength(from header: String) -> Int? {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                continue
            }
            if parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return nil
    }
}
