import Foundation

/// A tolerant lexer for incomplete shader source. Columns use Character offsets, as AdaUI's text editor does.
enum EditorShaderSyntaxHighlighter {
    enum Language: Sendable {
        case glsl
        case wgsl
    }

    enum Kind: Sendable {
        case keyword, type, string, number, comment, punctuation
    }

    struct Token: Equatable, Sendable {
        let line: Int
        let column: Int
        let length: Int
        let kind: Kind
    }

    static func tokens(for source: String, language: Language) -> [Token] {
        var scanner = Scanner(language: language)
        // Match the line splitting used by EditorSyntaxHighlighter and its token extraction helper.
        for (lineIndex, line) in source.components(separatedBy: .newlines).enumerated() {
            scanner.scan(Array(line), line: lineIndex)
        }
        return scanner.tokens
    }

    private struct Scanner {
        let language: Language
        var tokens: [Token] = []
        var commentDepth = 0

        mutating func scan(_ chars: [Character], line: Int) {
            var index = 0
            while index < chars.count {
                let start = index
                let kind: Kind?
                if commentDepth > 0 || matches("/*", chars, at: index) {
                    index = blockCommentEnd(chars, from: index)
                    kind = .comment
                } else if matches("//", chars, at: index) {
                    index = chars.count
                    kind = .comment
                } else if language == .glsl && chars[index] == "\"" {
                    index = stringEnd(chars, from: index)
                    kind = .string
                } else if language == .glsl && matches("[[", chars, at: index) {
                    index += 2
                    while index < chars.count && !matches("]]", chars, at: index) { index += 1 }
                    index = min(chars.count, index + 2)
                    kind = .keyword
                } else if (language == .glsl && chars[index] == "#") || (language == .wgsl && chars[index] == "@") {
                    index += 1
                    while index < chars.count && chars[index].isWhitespace { index += 1 }
                    index = identifierEnd(chars, from: index)
                    kind = .keyword
                } else if chars[index].isASCII && chars[index].isNumber
                    || (chars[index] == "." && index + 1 < chars.count && chars[index + 1].isNumber) {
                    index = numberEnd(chars, from: index)
                    kind = .number
                } else if isIdentifierStart(chars[index]) {
                    index = identifierEnd(chars, from: index)
                    let word = String(chars[start..<index])
                    kind = identifierKind(word, chars: chars, end: index)
                } else {
                    index += 1
                    kind = Self.punctuation.contains(chars[start]) ? .punctuation : nil
                }
                if let kind {
                    tokens.append(Token(line: line, column: start, length: index - start, kind: kind))
                }
            }
        }

        private func identifierKind(_ word: String, chars: [Character], end: Int) -> Kind? {
            if word == "true" || word == "false" {
                return .number
            }
            let keywords = language == .glsl ? glslKeywords : wgslKeywords
            if keywords.contains(word) {
                return .keyword
            }
            let types = language == .glsl ? glslTypes : wgslTypes
            if types.contains(word) || (language == .glsl && word.hasPrefix("gl_")) || word.first?.isUppercase == true {
                return .type
            }
            var next = end
            while next < chars.count && chars[next].isWhitespace { next += 1 }
            return next < chars.count && chars[next] == "(" ? .type : nil
        }

        private mutating func blockCommentEnd(_ chars: [Character], from start: Int) -> Int {
            var index = start
            if commentDepth == 0 {
                commentDepth = 1
                index += 2
            }
            while index < chars.count {
                if matches("*/", chars, at: index) {
                    commentDepth -= 1
                    index += 2
                    if commentDepth == 0 {
                        return index
                    }
                } else if language == .wgsl && matches("/*", chars, at: index) {
                    commentDepth += 1
                    index += 2
                } else {
                    index += 1
                }
            }
            return index
        }

        private static let punctuation = Set("{}[]();:,.=+-*/%<>!&|^~?")
    }

    private static func matches(_ text: String, _ chars: [Character], at index: Int) -> Bool {
        let end = index + text.count
        return end <= chars.count && chars[index..<end].elementsEqual(text)
    }

    private static func isIdentifierStart(_ char: Character) -> Bool {
        char == "_" || char.isLetter
    }

    private static func identifierEnd(_ chars: [Character], from start: Int) -> Int {
        var index = start
        while index < chars.count && (isIdentifierStart(chars[index]) || chars[index].isNumber) { index += 1 }
        return index
    }

    private static func stringEnd(_ chars: [Character], from start: Int) -> Int {
        var index = start + 1
        while index < chars.count {
            if chars[index] == "\\" {
                index = min(chars.count, index + 2)
            } else if chars[index] == "\"" {
                return index + 1
            } else {
                index += 1
            }
        }
        return index
    }

    private static func numberEnd(_ chars: [Character], from start: Int) -> Int {
        let hexadecimal = matches("0x", chars, at: start) || matches("0X", chars, at: start)
        var index = start + (hexadecimal ? 2 : 0)
        let digits = hexadecimal ? Set("0123456789abcdefABCDEF") : Set("0123456789")
        while index < chars.count && digits.contains(chars[index]) { index += 1 }
        if index < chars.count && chars[index] == "." {
            index += 1
            while index < chars.count && digits.contains(chars[index]) { index += 1 }
        }
        let exponent = hexadecimal ? Set("pP") : Set("eE")
        if index < chars.count && exponent.contains(chars[index]) {
            index += 1
            if index < chars.count && (chars[index] == "+" || chars[index] == "-") {
                index += 1
            }
            while index < chars.count && chars[index].isASCII && chars[index].isNumber { index += 1 }
        }
        while index < chars.count && "uUiIfFhHlL".contains(chars[index]) { index += 1 }
        return max(start + 1, index)
    }

    private static let glslKeywords = Set(
        """
        attribute const uniform varying buffer shared coherent volatile restrict readonly writeonly atomic_uint
        layout centroid flat smooth noperspective patch sample invariant precise precision highp mediump lowp
        break continue do for while switch case default if else subroutine in out inout discard return struct
        """
        .split(whereSeparator: \.isWhitespace).map(String.init)
    )

    private static let wgslKeywords = Set(
        """
        alias break case const const_assert continue continuing default diagnostic discard else enable fn for if
        let loop override requires return struct switch var while function private workgroup uniform storage
        read write read_write handle push_constant
        """
        .split(whereSeparator: \.isWhitespace).map(String.init)
    )

    private static let glslTypes: Set<String> = {
        var types = Set(["void", "bool", "int", "uint", "float", "double", "atomic_uint"])
        for width in 2...4 {
            for prefix in ["vec", "bvec", "ivec", "uvec", "dvec"] { types.insert("\(prefix)\(width)") }
            for prefix in ["mat", "dmat"] {
                types.insert("\(prefix)\(width)")
                for height in 2...4 { types.insert("\(prefix)\(width)x\(height)") }
            }
        }
        for prefix in ["sampler", "isampler", "usampler", "image", "iimage", "uimage"] {
            for shape in ["1D", "2D", "3D", "Cube", "2DRect", "1DArray", "2DArray", "CubeArray", "Buffer", "2DMS", "2DMSArray"] {
                types.insert(prefix + shape)
                if prefix == "sampler" {
                    types.insert(prefix + shape + "Shadow")
                }
            }
        }
        return types
    }()

    private static let wgslTypes: Set<String> = {
        var types = Set(
            """
            bool i32 u32 f32 f16 array atomic ptr sampler sampler_comparison texture_1d texture_2d texture_2d_array
            texture_3d texture_cube texture_cube_array texture_multisampled_2d texture_storage_1d texture_storage_2d
            texture_storage_2d_array texture_storage_3d texture_depth_2d texture_depth_2d_array texture_depth_cube
            texture_depth_cube_array texture_depth_multisampled_2d texture_external binding_array
            """
            .split(whereSeparator: \.isWhitespace).map(String.init)
        )
        for width in 2...4 {
            for suffix in ["", "f", "h", "i", "u"] { types.insert("vec\(width)\(suffix)") }
            for height in 2...4 {
                for suffix in ["", "f", "h"] { types.insert("mat\(width)x\(height)\(suffix)") }
            }
        }
        return types
    }()
}
