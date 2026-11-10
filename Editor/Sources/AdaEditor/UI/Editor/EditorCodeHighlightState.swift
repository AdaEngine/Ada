@_spi(AdaEngine) import AdaEngine
import Observation

/// Syntax spans for one code view.
///
/// Small sources are highlighted synchronously, as before. Larger sources are highlighted off the main
/// actor so a keystroke or newly opened tab does not wait for a whole-document tree-sitter pass; the view
/// keeps showing the most recent spans until the current text's spans are ready. Only one pass runs at a
/// time, and a burst of edits coalesces into a pass for the latest text.
@Observable
@MainActor
final class EditorCodeHighlightState {
    struct Request: Equatable, Sendable {
        /// Identifies the document whose earlier spans may stand in while its edits re-highlight.
        var documentID: String
        var source: String
        var language: EditorSourceLanguage
        var palette: EditorCodeColorPalette
        var keywordFont: Font?

        /// Spans for `other` only approximate this request when they describe an earlier version of the
        /// same document with the same styling; another document's colors must never be painted here.
        func canReuseSpans(of other: Request) -> Bool {
            documentID == other.documentID && language == other.language
                && palette == other.palette && keywordFont == other.keywordFont
        }
    }

    /// Sources up to this size stay synchronous: highlighting them costs less than a frame.
    static let synchronousUTF8Limit = 24 * 1_024

    /// Bumped when background spans arrive so observing views redraw with them.
    private(set) var revision = 0
    @ObservationIgnored private var displayed: (request: Request, spans: [TextEditorTokenSpan])?
    @ObservationIgnored private var latest: Request?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private(set) var backgroundPasses = 0

    var isHighlighting: Bool {
        worker != nil
    }

    func spans(for request: Request) -> [TextEditorTokenSpan] {
        _ = revision
        if let displayed, displayed.request == request {
            return displayed.spans
        }
        if request.source.utf8.count <= Self.synchronousUTF8Limit {
            let spans = Self.highlight(request)
            displayed = (request, spans)
            latest = nil
            return spans
        }
        schedule(request)
        guard let displayed, request.canReuseSpans(of: displayed.request) else {
            // A different document or style starts as plain text until its own pass is ready.
            return []
        }
        return displayed.spans
    }

    /// Waits for scheduled background work; used by tests and callers that need settled spans.
    func waitUntilIdle() async {
        while let worker {
            await worker.value
        }
    }

    private func schedule(_ request: Request) {
        latest = request
        guard worker == nil else {
            return
        }
        worker = Task { [weak self] in
            while let next = self?.pendingRequest() {
                let spans = await Self.backgroundHighlight(next)
                guard let self else {
                    return
                }
                // Publish even if newer text is pending: these spans are closer to it than the old ones.
                self.displayed = (next, spans)
                self.backgroundPasses += 1
                self.revision &+= 1
            }
            self?.worker = nil
        }
    }

    private func pendingRequest() -> Request? {
        guard let latest, displayed?.request != latest else {
            self.latest = nil
            return nil
        }
        return latest
    }

    nonisolated private static func highlight(_ request: Request) -> [TextEditorTokenSpan] {
        EditorSyntaxHighlighter.spans(
            for: request.source,
            language: request.language,
            palette: request.palette,
            keywordFont: request.keywordFont
        )
    }

    @concurrent
    nonisolated private static func backgroundHighlight(_ request: Request) async -> [TextEditorTokenSpan] {
        let stall = PerformanceStallProbe.begin()
        let spans = highlight(request)
        PerformanceStallProbe.end("Studio.Highlight", since: stall, bytes: request.source.utf8.count, count: spans.count)
        return spans
    }
}
