import Foundation

/// Bounded static HTML extraction. Never evaluates scripts or loads subresources.
enum EditorWebHTML {
    static func text(_ html: String) -> String {
        var value = replace(html, #"(?is)<!--.*?-->|<(script|style|noscript|template)\b[^>]*>.*?</\1\s*>"#, "")
        value = replace(value, #"(?i)<(?:br|/?(?:p|div|h[1-6]|li|tr|section|article|pre))\b[^>]*>"#, "\n")
        value = entities(replace(value, #"<[^>]+>"#, ""))
        value = replace(value, #"[\t\r ]+"#, " ")
        value = replace(value, #"\n\s*\n+"#, "\n\n")
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func title(_ html: String) -> String {
        matches(html, #"(?is)<title\b[^>]*>(.*?)</title>"#).first.map { text($0[1]) } ?? ""
    }

    static func links(_ html: String, base: URL) -> [[String: String]] {
        var seen = Set<String>()
        let values = anchors(html).compactMap { anchor -> [String: String]? in
            guard let url = URL(string: anchor.href, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil, seen.insert(url.absoluteString).inserted else { return nil }
            return ["title": String(text(anchor.body).prefix(300)), "url": url.absoluteString]
        }
        return Array(values.prefix(100))
    }

    static func searchResults(_ html: String, count: Int) -> [[String: String]] {
        // Split on web result containers; ignore navigation, ads, videos and embedded JSON.
        let results = matches(html, #"(?is)<div\b([^>]*\bdata-type\s*=\s*["']web["'][^>]*)>(.*?)(?=<div\b[^>]*\bdata-type\s*=\s*["']web["']|\z)"#)
        var seen = Set<String>()
        let values = results.compactMap { result -> [String: String]? in
            guard attribute("class", in: result[1])?.split(separator: " ").contains("snippet") == true,
                  let anchor = anchors(result[2]).first(where: { $0.body.contains("search-snippet-title") }),
                  let url = URL(string: anchor.href), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil, seen.insert(url.absoluteString).inserted else {
                return nil
            }
            let title = matches(anchor.body, #"(?is)<div\b[^>]*class\s*=\s*["'][^"']*\bsearch-snippet-title\b[^"']*["'][^>]*>(.*?)</div>"#).first
            let snippet = matches(result[2], #"(?is)<div\b[^>]*class\s*=\s*["'](?:[^"']*\s)?content(?:\s[^"']*)?["'][^>]*>(.*?)</div>"#).first
            return ["title": String(text(title?[1] ?? "").prefix(500)), "url": url.absoluteString, "snippet": String(text(snippet?[1] ?? "").prefix(2000))]
        }
        return Array(values.prefix(count))
    }

    private static func anchors(_ html: String) -> [(href: String, body: String)] {
        matches(html, #"(?is)<a\b([^>]*)>(.*?)</a>"#).compactMap { match in
            attribute("href", in: match[1]).map { (entities($0), match[2]) }
        }
    }

    private static func attribute(_ name: String, in html: String) -> String? {
        matches(html, "(?is)\\b" + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#).first.map {
            $0.dropFirst().first(where: { !$0.isEmpty }) ?? ""
        }
    }

    private static func entities(_ source: String) -> String {
        let names: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—", "hellip": "…", "copy": "©"]
        guard let regex = try? NSRegularExpression(pattern: #"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#) else {
            return source
        }
        var result = source
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let range = Range(match.range(at: 1), in: source), let full = Range(match.range, in: result) else { continue }
            let entity = String(source[range])
            let replacement: String?
            if entity.hasPrefix("#") {
                let number = entity.hasPrefix("#x") ? UInt32(entity.dropFirst(2), radix: 16) : UInt32(entity.dropFirst())
                replacement = number.flatMap(UnicodeScalar.init).map(String.init)
            } else {
                replacement = names[entity]
            }
            if let replacement { result.replaceSubrange(full, with: replacement) }
        }
        return result
    }

    private static func replace(_ source: String, _ pattern: String, _ replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return source
        }
        return regex.stringByReplacingMatches(in: source, range: NSRange(source.startIndex..., in: source), withTemplate: replacement)
    }

    private static func matches(_ source: String, _ pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).map { match in
            (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: source).map { String(source[$0]) } ?? "" }
        }
    }
}
