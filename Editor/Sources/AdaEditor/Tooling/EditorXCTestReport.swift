import Foundation
import FoundationXML

/// SwiftPM's parallel XCTest runner records per-test results in its xUnit report.
final class EditorXCTestReport: NSObject, XMLParserDelegate {
    struct Result {
        var id: String
        var failed = false
        var skipped = false
        var detail = ""
    }
    private(set) var results: [Result] = []
    private var current: Result?
    private var isDiagnostic = false

    static func read(_ data: Data) -> [Result] {
        let delegate = EditorXCTestReport()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else { return [] }
        return delegate.results
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if elementName == "testcase", let name = attributes["name"], let suite = attributes["classname"] {
            current = Result(id: suite + "/" + name)
        } else if elementName == "failure" || elementName == "error" {
            current?.failed = true
            current?.detail += attributes["message"] ?? ""
            isDiagnostic = true
        } else if elementName == "skipped" {
            current?.skipped = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isDiagnostic { current?.detail += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        if elementName == "testcase", let current {
            results.append(current)
            self.current = nil
        }
        if elementName == "failure" || elementName == "error" { isDiagnostic = false }
    }
}
