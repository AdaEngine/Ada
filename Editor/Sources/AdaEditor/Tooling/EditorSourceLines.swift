enum EditorSourceLines {
    /// Swift treats CRLF as one newline character, matching TextEditor's normalized lines.
    static func split(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
    }
}
