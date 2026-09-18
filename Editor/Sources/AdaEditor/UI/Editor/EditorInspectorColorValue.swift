import Foundation

struct EditorInspectorColorValue: Equatable, Sendable {
    var red: Float
    var green: Float
    var blue: Float
    var alpha: Float

    init(red: Float, green: Float, blue: Float, alpha: Float) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    init(_ text: String) {
        self = Self(rgbaText: text) ?? Self(red: 0, green: 0, blue: 0, alpha: 1)
    }

    init?(rgbaText: String) {
        let components =
            rgbaText
            .split { $0 == "," || $0 == " " || $0 == "\t" }
            .compactMap { Float($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard components.count == 4 else {
            return nil
        }
        self.init(red: components[0], green: components[1], blue: components[2], alpha: components[3])
    }

    init?(hexText: String) {
        let trimmed = hexText.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard value.count == 6 || value.count == 8, let number = UInt32(value, radix: 16) else {
            return nil
        }
        let hasAlpha = value.count == 8
        let redShift = hasAlpha ? 24 : 16
        let greenShift = hasAlpha ? 16 : 8
        let blueShift = hasAlpha ? 8 : 0
        self.init(
            red: Float((number >> redShift) & 0xFF) / 255,
            green: Float((number >> greenShift) & 0xFF) / 255,
            blue: Float((number >> blueShift) & 0xFF) / 255,
            alpha: hasAlpha ? Float(number & 0xFF) / 255 : 1
        )
    }

    var rgbaString: String {
        [red, green, blue, alpha].map(Self.format).joined(separator: ", ")
    }

    var hexString: String {
        String(
            format: "#%02X%02X%02X%02X",
            Self.byte(red),
            Self.byte(green),
            Self.byte(blue),
            Self.byte(alpha)
        )
    }

    private static func byte(_ value: Float) -> Int {
        Int((clamp(value) * 255).rounded())
    }

    private static func clamp(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }

    private static func format(_ value: Float) -> String {
        let formatted = String(format: "%.3f", value)
        return
            formatted
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}

enum ColorFieldMode: String, Equatable, Sendable {
    case rgba
    case hex

    var title: String { rawValue.uppercased() }
}
