import AdaInput
import AdaRender
import AdaText
import AdaUtils
import Foundation
import Math

/// A resolution-independent inventory surface. Game code owns items and validates moves;
/// this view only draws the supplied snapshot and publishes completed pointer intents.
struct ItemBoardDocument: Decodable {
    struct Element: Decodable {
        var id: String
        var kind: String
        var rect: [Float]
        var text: String?
        var label: String?
        var image: String?
        var color: String?
        var font: Float?
        var draggable: Bool?
        var enabled: Bool?
        var accepts: [String]?
        var category: String?
        var columns: Int?
        var rows: Int?
        var border: String?
        var bounds: Rect { Rect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]) }
    }
    var width: Float
    var height: Float
    var elements: [Element]

    static func decode(_ text: String) throws -> Self {
        if text.isEmpty { return Self(width: 1280, height: 720, elements: []) }
        guard text.utf8.count <= 2_000_000 else { throw UIDiagnostic("ItemBoard snapshot exceeds 2 MB.") }
        let result = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        guard result.width.isFinite, result.height.isFinite, result.width > 0, result.height > 0,
              result.width <= 16384, result.height <= 16384, result.elements.count <= 4096,
              Set(result.elements.map(\.id)).count == result.elements.count,
              result.elements.allSatisfy({ element in
                  element.rect.count == 4 && element.rect.allSatisfy { $0.isFinite && abs($0) <= 32768 }
                      && element.rect[2] >= 0 && element.rect[3] >= 0
                      && (1...128).contains(element.columns ?? 1) && (1...128).contains(element.rows ?? 1)
                      && (element.font ?? 14).isFinite && (1...256).contains(element.font ?? 14)
              }) else { throw UIDiagnostic("Invalid ItemBoard geometry or duplicate element identity.") }
        return result
    }

    func point(_ point: Point, in size: Size) -> Point? {
        let scale = min(size.width / width, size.height / height)
        guard scale.isFinite, scale > 0 else { return nil }
        return Point((point.x - (size.width - width * scale) / 2) / scale,
                     (point.y - (size.height - height * scale) / 2) / scale)
    }

    func target(at point: Point, category: String) -> (String, Int)? {
        for element in elements.reversed() where element.kind == "zone" && element.enabled != false {
            guard element.bounds.contains(point: point), element.accepts?.contains(category) ?? true else { continue }
            let columns = element.columns ?? 1, rows = element.rows ?? 1
            guard element.bounds.width > 0, element.bounds.height > 0 else { continue }
            let column = min(columns - 1, Int((point.x - element.bounds.minX) / element.bounds.width * Float(columns)))
            let row = min(rows - 1, Int((point.y - element.bounds.minY) / element.bounds.height * Float(rows)))
            return (element.id, row * columns + column)
        }
        return nil
    }
}

struct ItemBoard: UIViewRepresentable {
    let snapshot: Binding<String>
    let resources: UISceneResources
    let sourceURL: URL?
    let command: Binding<String>
    func makeUIView(in _: Context) -> ItemBoardHost {
        let view = ItemBoardHost()
        view.backgroundColor = .clear
        return view
    }
    func updateUIView(_ view: ItemBoardHost, in _: Context) {
        view.snapshot = snapshot
        view.resources = resources
        view.sourceURL = sourceURL
        view.command = command
        view.refreshDocument()
        view.setNeedsDisplay()
    }
}

@MainActor
final class ItemBoardHost: UIView {
    var snapshot: Binding<String>?
    var resources: UISceneResources?
    var sourceURL: URL?
    var document = ItemBoardDocument(width: 1280, height: 720, elements: [])
    var textures: [String: Texture2D] = [:]
    private var lastSnapshot: String?
    var command: Binding<String>?
    private var source: ItemBoardDocument.Element?
    private var start = Point.zero
    private var pointer = Point.zero
    private var dragging = false
    private var pressed = false
    private var contact: RID?
    private var textCache: [String: TextLayoutManager] = [:]

    override func update(_ deltaTime: AdaUtils.TimeInterval) {
        refreshDocument()
    }

    func refreshDocument() {
        guard let value = snapshot?.wrappedValue, value != lastSnapshot, let resources else { return }
        lastSnapshot = value
        do {
            let next = try ItemBoardDocument.decode(value)
            var nextTextures: [String: Texture2D] = [:]
            for path in Set(next.elements.compactMap(\.image)) where !path.isEmpty {
                nextTextures[path] = try textures[path] ?? Texture2D(image: resources.image(path, relativeTo: sourceURL))
            }
            document = next
            textures = nextTextures
            setNeedsDisplay()
        } catch {
            // Keep the last valid board if a partially written snapshot arrives.
        }
    }

    override func draw(in rect: Rect, with graphics: UIGraphicsContext) {
        let scale = min(rect.width / document.width, rect.height / document.height)
        guard scale.isFinite, scale > 0 else { return }
        var graphics = graphics
        graphics.translateBy(x: (rect.width - document.width * scale) / 2, y: -(rect.height - document.height * scale) / 2)
        graphics.scaleBy(x: scale, y: scale)
        for element in document.elements {
            if element.kind == "zone" { continue }
            if dragging && element.id == source?.id {
                var faded = graphics
                faded.opacity = 0.22
                draw(element, in: faded)
            } else { draw(element, in: graphics) }
        }
        if let source, dragging {
            if let (id, cell) = document.target(at: pointer, category: source.category ?? "") ,
               let target = document.elements.first(where: { $0.id == id }) {
                let columns = target.columns ?? 1, rows = target.rows ?? 1
                let width = target.bounds.width / Float(columns), height = target.bounds.height / Float(rows)
                let highlight = Rect(x: target.bounds.minX + Float(cell % columns) * width,
                                     y: target.bounds.minY + Float(cell / columns) * height, width: width, height: height)
                graphics.drawRect(highlight, color: Color.fromHex(0xC15B20).opacity(0.3))
                outline(highlight, color: Color.fromHex(0xEF8C47), in: graphics)
            }
            var ghost = source
            ghost.rect = [pointer.x - source.bounds.width / 2, pointer.y - source.bounds.height / 2, source.bounds.width, source.bounds.height]
            ghost.color = "#292a24f5"
            ghost.border = "#ef8c47ff"
            draw(ghost, in: graphics)
        } else if !pressed, let hovered = document.elements.reversed().first(where: { $0.kind == "item" && $0.bounds.contains(point: pointer) }),
                  let label = hovered.label {
            let tooltip = Rect(x: min(pointer.x + 14, document.width - 278), y: max(6, min(pointer.y + 18, document.height - 44)), width: 266, height: 34)
            graphics.drawRect(tooltip, color: Color.fromHex(0x131B1B).opacity(0.98))
            outline(tooltip, color: Color.fromHex(0xA4AB91).opacity(0.6), in: graphics)
            text(label, in: Rect(x: tooltip.minX + 10, y: tooltip.minY + 8, width: 247, height: 22), font: 13,
                 color: Color.fromHex(0xE8E0CF), context: graphics)
        }
    }

    private func draw(_ element: ItemBoardDocument.Element, in context: UIGraphicsContext) {
        let bounds = element.bounds
        let color = resolved(element.color, fallback: .clear)
        if element.kind == "text" {
            text(element.text ?? "", in: bounds, font: element.font ?? 14, color: color, context: context)
            return
        }
        if color.alpha > 0 { context.drawRect(bounds, color: color) }
        if let border = element.border { outline(bounds, color: resolved(border, fallback: .clear), in: context) }
        if let key = element.image, let texture = textures[key] {
            let padding: Float = element.kind == "item" ? 5 : 0
            let fit = min(max(0, bounds.width - padding * 2) / Float(texture.width), max(0, bounds.height - padding * 2) / Float(texture.height))
            let width = Float(texture.width) * fit, height = Float(texture.height) * fit
            context.drawRect(Rect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height), texture: texture, color: .white)
        }
        if element.kind == "button" {
            if bounds.contains(point: pointer) && element.enabled != false { context.drawRect(bounds, color: .white.opacity(0.07)) }
            text(element.text ?? "", in: Rect(x: bounds.minX + 18, y: bounds.midY - (element.font ?? 18) * 0.7,
                                              width: bounds.width - 28, height: bounds.height),
                 font: element.font ?? 18, color: element.enabled == false ? .white.opacity(0.3) : Color.fromHex(0xF0E9DC), context: context)
        } else if let label = element.text, !label.isEmpty {
            text(label, in: Rect(x: bounds.minX + 7, y: bounds.maxY - 17, width: bounds.width - 10, height: 16),
                 font: 10, color: Color.fromHex(0xE8E0CF), context: context)
        }
    }

    private func resolved(_ string: String?, fallback: Color) -> Color {
        guard let string else { return fallback }
        let hex = string.hasPrefix("#") ? String(string.dropFirst()) : string
        guard let value = UInt32(hex, radix: 16), hex.count == 8 else { return fallback }
        return Color(red: Float((value >> 24) & 255) / 255, green: Float((value >> 16) & 255) / 255,
                     blue: Float((value >> 8) & 255) / 255, alpha: Float(value & 255) / 255)
    }
    private func outline(_ rect: Rect, color: Color, in context: UIGraphicsContext) {
        let thickness: Float = 1
        for line in [Rect(x: rect.minX, y: rect.minY, width: rect.width, height: thickness),
                     Rect(x: rect.minX, y: rect.maxY - thickness, width: rect.width, height: thickness),
                     Rect(x: rect.minX, y: rect.minY, width: thickness, height: rect.height),
                     Rect(x: rect.maxX - thickness, y: rect.minY, width: thickness, height: rect.height)] {
            context.drawRect(line, color: color)
        }
    }
    private func text(_ value: String, in rect: Rect, font: Float, color: Color, context: UIGraphicsContext) {
        let key = "\(value)|\(font)|\(rect.width)|\(color)"
        let layout: TextLayoutManager
        if let cached = textCache[key] { layout = cached } else {
            var attributes = TextAttributeContainer()
            attributes.font = .system(size: Double(font))
            attributes.foregroundColor = color
            layout = TextLayoutManager()
            layout.setTextContainer(TextContainer(text: AttributedText(value, attributes: attributes)))
            layout.fitToSize(rect.size)
            if textCache.count > 512 { textCache.removeAll(keepingCapacity: true) }
            textCache[key] = layout
        }
        // Glyph positions are already in logical pixels. The legacy drawText
        // rectangle API also scales by the rectangle dimensions, so use the
        // same glyph renderer as the declarative Text node instead.
        var graphics = context
        var top: Float = -.infinity
        var left: Float = .infinity
        for line in layout.textLines {
            for run in line {
                for glyph in run {
                    top = max(top, glyph.position.w)
                    left = min(left, glyph.position.x)
                }
            }
        }
        guard top.isFinite, left.isFinite else { return }
        graphics.translateBy(x: rect.minX - left, y: -rect.minY - top)
        DefaultRichTextRenderer().draw(layout: Text.Layout(lines: layout.textLines), in: &graphics)
    }

    override func onMouseEvent(_ event: MouseEvent) {
        guard contact == nil, event.button == .left || event.phase == .changed else { return }
        process(event.mousePosition, began: event.phase == .began, ended: event.phase == .ended, cancelled: event.phase == .cancelled)
    }
    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        for touch in touches {
            if touch.phase == .began && contact == nil && !pressed { contact = touch.contactID }
            guard touch.contactID == contact else { continue }
            process(touch.location, began: touch.phase == .began, ended: touch.phase == .ended, cancelled: touch.phase == .cancelled)
        }
    }
    private func process(_ location: Point, began: Bool, ended: Bool, cancelled: Bool) {
        guard let point = document.point(location, in: bounds.size) else { reset(); return }
        pointer = point
        if cancelled { reset(); return }
        if began {
            pressed = true
            start = point
            source = document.elements.reversed().first { element in
                let interactive = element.draggable == true || element.kind == "button"
                return interactive && element.enabled != false && element.bounds.contains(point: point)
            }
        }
        if pressed, source?.draggable == true {
            let dx = point.x - start.x, dy = point.y - start.y
            if dx * dx + dy * dy > 25 { dragging = true }
        }
        if ended, pressed, let source {
            if dragging, let target = document.target(at: point, category: source.category ?? "") {
                publish(["move", source.id, target.0, target.1])
            } else if !dragging, source.kind == "button", source.bounds.contains(point: point) { publish(["action", source.id]) }
            reset()
        } else if ended { reset() }
        setNeedsDisplay()
    }
    private func publish(_ intent: [Any]) {
        let previous = command?.wrappedValue.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [Any]
        let serial = ((previous?.first as? Int) ?? 0) + 1
        guard let data = try? JSONSerialization.data(withJSONObject: [serial] + intent), let text = String(data: data, encoding: .utf8) else { return }
        command?.wrappedValue = text
    }
    private func reset() { source = nil; dragging = false; pressed = false; contact = nil; setNeedsDisplay() }
    override func onFocusChanged(isFocused: Bool) { if !isFocused { reset() } }
    override func viewWillMove(to window: UIWindow?) { if window == nil { reset() } }
    override func viewWillMove(to parentView: UIView?) { if parentView == nil { reset() } }
}
