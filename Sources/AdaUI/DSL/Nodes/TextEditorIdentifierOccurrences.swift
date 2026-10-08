//
//  TextEditorIdentifierOccurrences.swift
//  AdaEngine
//

import Foundation

enum TextEditorIdentifierOccurrences {
    static let maximumIdentifierLength = 128

    static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.first, let firstScalar = first.unicodeScalars.first,
            first == "_" || CharacterSet.letters.contains(firstScalar)
        else {
            return false
        }
        return text.count <= maximumIdentifierLength && text.allSatisfy(isIdentifierCharacter)
    }

    static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { $0 == "_" || CharacterSet.alphanumerics.contains($0) }
    }

    static func ranges(of identifier: String, in line: String) -> [Range<Int>] {
        guard isIdentifier(identifier) else { return [] }
        let characters = Array(line)
        let word = Array(identifier)
        guard characters.count >= word.count else { return [] }

        var result: [Range<Int>] = []
        for start in 0...(characters.count - word.count) {
            let end = start + word.count
            guard (start == 0 || !isIdentifierCharacter(characters[start - 1])),
                (end == characters.count || !isIdentifierCharacter(characters[end])),
                characters[start..<end].elementsEqual(word)
            else {
                continue
            }
            result.append(start..<end)
        }
        return result
    }
}
