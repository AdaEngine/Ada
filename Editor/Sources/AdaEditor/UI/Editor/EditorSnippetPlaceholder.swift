enum EditorSnippetPlaceholder {
    static func render(_ source: String, at insertion: EditorSourceLocation) -> (text: String, placeholder: EditorSourceRange?) {
        var result = ""
        var placeholder: EditorSourceRange?
        var line = insertion.line
        var column = insertion.character
        var index = source.startIndex

        while index < source.endIndex {
            if source[index] == "$" {
                let nameStart = source.index(after: index)
                if let closing = source[nameStart...].firstIndex(of: "$"), closing > nameStart,
                    !source[nameStart..<closing].contains("\n") {
                    let name = source[nameStart..<closing]
                    if placeholder == nil {
                        let start = EditorSourceLocation(line: line, character: column)
                        placeholder = EditorSourceRange(
                            start: start,
                            end: EditorSourceLocation(line: line, character: column + name.count)
                        )
                    }
                    result.append(contentsOf: name)
                    column += name.count
                    index = source.index(after: closing)
                    continue
                }
            }

            let character = source[index]
            result.append(character)
            if character == "\n" {
                line += 1
                column = 0
            } else {
                column += 1
            }
            index = source.index(after: index)
        }

        return (result, placeholder)
    }
}
