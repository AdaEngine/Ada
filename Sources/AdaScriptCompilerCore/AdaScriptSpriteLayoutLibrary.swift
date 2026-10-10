/// Portable layout factories shared by the VM and native AdaScript compiler.
public enum AdaScriptSpriteLayoutLibrary {
    /// Native AOT does not support the VM's dynamic factory classes.
    public static let nativeSource = """
    func SpriteAnchor(x, y) { return [x, y]; }
    func SpriteSliceBorder(top, left, bottom, right) { return [top, left, bottom, right]; }
    func AdaSpriteImageModeSliced(border) { return ["sliced", border[0], border[1], border[2], border[3]]; }
    func AdaSpriteImageModeTiled(tileX, tileY, scale) { return ["tiled", tileX, tileY, scale]; }
    """

    /// Rewrites only factory member tokens, leaving comments and quoted text intact.
    public static func lowerForNative(_ source: String) -> String {
        let anchors = [
            "center": "[0.0, 0.0]", "bottomLeft": "[-0.5, -0.5]", "bottomCenter": "[0.0, -0.5]", "bottomRight": "[0.5, -0.5]",
            "centerLeft": "[-0.5, 0.0]", "centerRight": "[0.5, 0.0]", "topLeft": "[-0.5, 0.5]", "topCenter": "[0.0, 0.5]", "topRight": "[0.5, 0.5]",
        ]
        let orientations = ["identity", "rotate90", "rotate180", "rotate270", "mirrorX", "mirrorXRotate90", "mirrorXRotate180", "mirrorXRotate270"]
        var lexer = Lexer(source: source)
        let tokens = lexer.lex()
        var changes: [(Range<Int>, String)] = []
        for index in tokens.indices where index + 2 < tokens.count {
            guard tokens[index].kind == .identifier, tokens[index + 1].text == ".",
                index == 0 || tokens[index - 1].text != "." else { continue }
            let member = tokens[index + 2].text
            let replacement: String?
            switch tokens[index].text {
            case "SpriteAnchor": replacement = anchors[member]
            case "TileOrientation": replacement = orientations.firstIndex(of: member).map(String.init)
            case "SpriteImageMode":
                replacement = switch member {
                case "stretch", "fit", "fill": "\"\(member)\""
                case "sliced": "AdaSpriteImageModeSliced"
                case "tiled": "AdaSpriteImageModeTiled"
                default: nil
                }
            default: replacement = nil
            }
            if let replacement { changes.append((tokens[index].startOffset..<tokens[index + 2].endOffset, replacement)) }
        }
        var characters = Array(source)
        for (range, replacement) in changes.reversed() { characters.replaceSubrange(range, with: Array(replacement)) }
        return completingNativeArguments(String(characters))
    }

    private static func completingNativeArguments(_ source: String) -> String {
        let defaults = ["SpriteAnchor": ["0", "0"], "SpriteSliceBorder": ["0", "0", "0", "0"], "AdaSpriteImageModeTiled": ["true", "true", "1"]]
        var lexer = Lexer(source: source)
        let tokens = lexer.lex()
        var insertions: [(Int, String)] = []
        for index in tokens.indices where index + 1 < tokens.count {
            guard let values = defaults[tokens[index].text], tokens[index + 1].text == "(",
                index == 0 || !["func", "."].contains(tokens[index - 1].text) else { continue }
            var depth = 1
            var end = index + 2
            var count = 0
            while end < tokens.count {
                let text = tokens[end].text
                if ["(", "[", "{"].contains(text) { depth += 1 }
                if [")", "]", "}"].contains(text) { depth -= 1 }
                if depth == 0 { break }
                if depth == 1 && text == "," { count += 1 }
                end += 1
            }
            guard depth == 0, tokens.indices.contains(end) else { continue }
            if end > index + 2 { count += 1 }
            guard count < values.count else { continue }
            let missing = values.dropFirst(count).joined(separator: ", ")
            insertions.append((tokens[end].startOffset, (count == 0 ? "" : ", ") + missing))
        }
        var characters = Array(source)
        for (offset, text) in insertions.sorted(by: { $0.0 > $1.0 }) { characters.insert(contentsOf: text, at: offset) }
        return String(characters)
    }

    public static let source = """
        class __AdaSpriteAnchorFactory {
            var center { get { return [0.0, 0.0]; } };
            var bottomLeft { get { return [-0.5, -0.5]; } };
            var bottomCenter { get { return [0.0, -0.5]; } };
            var bottomRight { get { return [0.5, -0.5]; } };
            var centerLeft { get { return [-0.5, 0.0]; } };
            var centerRight { get { return [0.5, 0.0]; } };
            var topLeft { get { return [-0.5, 0.5]; } };
            var topCenter { get { return [0.0, 0.5]; } };
            var topRight { get { return [0.5, 0.5]; } };
            func exec(x = 0, y = 0) { return [x, y]; }
        }
        var SpriteAnchor = __AdaSpriteAnchorFactory();
        func SpriteSliceBorder(top = 0, left = 0, bottom = 0, right = 0) { return [top, left, bottom, right]; }
        class __AdaSpriteImageModeFactory {
            var stretch { get { return "stretch"; } };
            var fit { get { return "fit"; } };
            var fill { get { return "fill"; } };
            func sliced(border) { return ["sliced", border[0], border[1], border[2], border[3]]; }
            func tiled(tileX = true, tileY = true, scale = 1) { return ["tiled", tileX, tileY, scale]; }
        }
        var SpriteImageMode = __AdaSpriteImageModeFactory();
        class __AdaTileOrientationFactory {
            var identity { get { return 0; } };
            var rotate90 { get { return 1; } };
            var rotate180 { get { return 2; } };
            var rotate270 { get { return 3; } };
            var mirrorX { get { return 4; } };
            var mirrorXRotate90 { get { return 5; } };
            var mirrorXRotate180 { get { return 6; } };
            var mirrorXRotate270 { get { return 7; } };
        }
        var TileOrientation = __AdaTileOrientationFactory();
        """
}
