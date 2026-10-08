/// The base writing direction used to resolve bidirectional text.
public enum TextWritingDirection: Hashable, Sendable {
    /// Infer the base direction from the first strongly directional character.
    case natural

    /// Resolve the paragraph from left to right.
    case leftToRight

    /// Resolve the paragraph from right to left.
    case rightToLeft
}

extension TextWritingDirection {
    func resolved(for text: String) -> TextWritingDirection {
        guard self == .natural else {
            return self
        }

        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (0x0590...0x08FF).contains(value)
                || (0xFB1D...0xFDFF).contains(value)
                || (0xFE70...0xFEFF).contains(value)
                || (0x10800...0x10FFF).contains(value)
                || (0x1E800...0x1EEFF).contains(value) {
                return .rightToLeft
            }

            switch scalar.properties.generalCategory {
            case .uppercaseLetter,
                .lowercaseLetter,
                .titlecaseLetter,
                .modifierLetter,
                .otherLetter,
                .decimalNumber,
                .letterNumber,
                .otherNumber:
                return .leftToRight
            default:
                continue
            }
        }

        return .leftToRight
    }
}
