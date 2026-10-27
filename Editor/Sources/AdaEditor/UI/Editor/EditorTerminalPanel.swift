@_spi(AdaEngine) import AdaEngine
import Foundation
import SwiftTerm

extension EditorTerminalSession {
    func pasteClipboard() {
        guard let text = UIClipboard.getString() else { return }
        send((terminal.bracketedPasteMode ? "\u{1b}[200~" : "") + text + (terminal.bracketedPasteMode ? "\u{1b}[201~" : ""))
    }
}

struct EditorTerminalPanel: View {
    let viewModel: EditorViewModel
    @Environment(\.theme) private var theme
    @State private var hoveredAction: String?

    private var workspace: EditorTerminalWorkspace { viewModel.terminals }
    private var session: EditorTerminalSession { workspace.activeSession }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                toolbar.frame(height: 34)
                if let error = session.error {
                    Text(L10n.text("Could not start terminal: \(error)"))
                        .font(.system(size: 12))
                        .foregroundColor(theme.editorColors.text)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                }
                EditorTerminalSurface(session: session)
                    .frame(width: geometry.size.width, height: max(0, geometry.size.height - 34 - (session.error == nil ? 0 : 24)))
                    .accessibilityIdentifier("AdaEditor.Terminal.Surface")
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .overlay(anchor: .topTrailing) {
            if let hoveredAction {
                Text(L10n.tr(hoveredAction))
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.text)
                    .padding(7)
                    .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surface))
                    .offset(x: -6, y: 36)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            if let projectURL = viewModel.projectURL { workspace.start(in: projectURL) }
        }
        .onDisappear { hoveredAction = nil }
        .accessibilityIdentifier("AdaEditor.Terminal.Panel")
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(workspace.sessions) { item in
                        terminalTab(item)
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            iconButton("\u{E145}", title: "New Terminal", identifier: "New") { workspace.add() }
            iconButton("\u{E5D5}", title: "Restart Terminal", identifier: "Restart") { session.restart() }
            iconButton("\u{E14D}", title: "Copy", identifier: "Copy") {
                UIClipboard.setString(session.terminal.selectionText(session.selection))
            }
            iconButton("\u{E14F}", title: "Paste", identifier: "Paste") { session.pasteClipboard() }
        }
        .padding(.horizontal, 6)
        .background(theme.editorColors.surface)
    }

    private func terminalTab(_ item: EditorTerminalSession) -> some View {
        let active = item === session
        return HStack(spacing: 0) {
            Button { workspace.select(item) } label: {
                HStack(spacing: 6) {
                    symbol("\u{EB8E}")
                    Text(item.title == "Terminal" ? L10n.text("Terminal") : item.title.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? item.title)
                        .environment(\.font, .system(size: 12))
                        .lineLimit(1)
                        .frame(maxWidth: 160, alignment: .leading)
                    if !item.isRunning { symbol("\u{E047}") }
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
            }
            .buttonStyle(DefaultButtonStyle())
            .accessibilityIdentifier("AdaEditor.Terminal.Tab.\(item.id)")
            iconButton("\u{E5CD}", title: "Close Terminal", identifier: "Close.\(item.id)") { workspace.close(item) }
        }
        .foregroundColor(active ? theme.editorColors.text : theme.editorColors.muted)
        .background(RoundedRectangleShape(cornerRadius: 5).fill(active ? theme.editorColors.surfaceElevated : .clear))
        .overlay {
            RoundedRectangleShape(cornerRadius: 5).stroke(active ? theme.editorColors.blue.opacity(0.65) : .clear, lineWidth: 1)
        }
    }

    private func iconButton(_ glyph: String, title: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { symbol(glyph).frame(width: 28, height: 28) }
            .buttonStyle(DefaultButtonStyle())
            .foregroundColor(theme.editorColors.muted)
            .onHover { hoveredAction = $0 ? title : nil }
            .accessibilityIdentifier("AdaEditor.Terminal.\(identifier)")
    }

    private func symbol(_ glyph: String) -> some View {
        Text(glyph).environment(\.font, AdaEditorMaterialSymbolFont.font(size: 16))
    }
}

struct EditorTerminalSurface: UIViewRepresentable {
    let session: EditorTerminalSession
    func makeUIView(in context: Context) -> EditorTerminalView { EditorTerminalView(frame: .zero) }
    func sizeThatFits(_ proposal: ProposedViewSize, view: EditorTerminalView, context: Context) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }
    func updateUIView(_ view: EditorTerminalView, in context: Context) {
        if view.session !== session { view.session?.onChange = nil }
        view.session = session
        session.onChange = { [weak view] in view?.setNeedsDisplay() }
        view.setNeedsLayout()
        view.setNeedsDisplay()
    }
}

final class EditorTerminalView: UIView {
    var session: EditorTerminalSession?
    private let cellWidth: Float = 8.4
    private let cellHeight: Float = 19
    private var isSelecting = false
    private struct GlyphKey: Hashable {
        let text: String
        let foreground: AdaEngine.Color
        let bold: Bool
        let width: Int8
    }
    private var glyphs: [GlyphKey: TextLayoutManager] = [:]
    override var acceptsKeyboardFocus: Bool { true }

    override func layoutSubviews() {
        super.layoutSubviews()
        session?.resize(columns: Int(max(0, bounds.width - 12) / cellWidth), rows: Int(max(0, bounds.height - 8) / cellHeight))
    }

    override func onFocusChanged(isFocused: Bool) {
        session?.terminal.setTerminalFocus(isFocused)
        setNeedsDisplay()
    }

    override func onTextInputEvent(_ event: TextInputEvent) {
        if event.action == .insert || event.action == .commitText {
            // Enter, Tab, Escape and control chords are delivered by onKeyEvent.
            let text = event.text.filter { $0 == " " || !$0.unicodeScalars.allSatisfy { $0.value < 32 || $0.value == 127 } }
            session?.send(text)
        }
        if event.action == .deleteBackward { session?.send("\u{7f}") }
    }

    override func onKeyEvent(_ event: KeyEvent) {
        guard event.status == .down, let session else { return }
        if EditorTerminalKeyboard.isClipboardChord(event.modifiers), event.keyCode == .v {
            session.pasteClipboard()
            return
        }
        if EditorTerminalKeyboard.isClipboardChord(event.modifiers), event.keyCode == .c {
            UIClipboard.setString(session.terminal.selectionText(session.selection))
            return
        }
        if let text = EditorTerminalKeyboard.sequence(event, applicationCursor: session.terminal.applicationCursor) { session.send(text) }
    }

    override func onMouseEvent(_ event: MouseEvent) {
        guard let session else { return }
        let column = max(0, min(session.terminal.cols - 1, Int((event.mousePosition.x - 6) / cellWidth)))
        let row = max(0, min(session.terminal.rows - 1, Int((event.mousePosition.y - 4) / cellHeight)))
        if event.button == .scrollWheel {
            if !session.terminal.sendHostMouse(action: .wheel, button: event.scrollDelta.y > 0 ? .wheelUp : .wheelDown,
                                                modifiers: 0, col: column, row: row, pixelX: max(0, Int(event.mousePosition.x)),
                                                pixelY: max(0, Int(event.mousePosition.y))) {
                session.terminal.scrollViewport(event.scrollDelta.y > 0 ? -3 : 3)
            }
            setNeedsDisplay()
            return
        }
        guard event.button == .left || event.button == .none else { return }
        let action: TerminalMouseAction = event.phase == .began ? .press : event.phase == .ended ? .release : .move
        if session.terminal.sendHostMouse(action: action, button: event.button == .none ? .none : .left,
                                          modifiers: 0, col: column, row: row, pixelX: max(0, Int(event.mousePosition.x)),
                                          pixelY: max(0, Int(event.mousePosition.y))) { return }
        if event.phase == .began {
            isSelecting = true
            session.terminal.updateSelection(session.selection, action: 0, column: column, row: row)
        } else if isSelecting {
            session.terminal.updateSelection(session.selection, action: 1, column: column, row: row)
        }
        if event.phase == .ended || event.phase == .cancelled { isSelecting = false }
        setNeedsDisplay()
    }

    override func draw(in rect: Rect, with context: UIGraphicsContext) {
        guard let session else { return }
        let snapshot = session.terminal.makeRenderSnapshot(scope: .full)
        let selection = session.terminal.selectionState(session.selection)
        context.drawRect(bounds, color: color(snapshot.backgroundColor))
        for row in snapshot.lines {
            for (column, cell) in row.cells.enumerated() where cell.width > 0 {
                let rect = Rect(x: 6 + Float(column) * cellWidth, y: 4 + Float(row.y) * cellHeight,
                                width: cellWidth * Float(cell.width), height: cellHeight)
                var foreground = resolve(cell.attribute.fg, snapshot: snapshot, foreground: true)
                var background = resolve(cell.attribute.bg, snapshot: snapshot, foreground: false)
                if cell.attribute.style.contains(.inverse) != snapshot.reverseVideo { swap(&foreground, &background) }
                context.drawRect(rect, color: background)
                if selection.spans.contains(where: { $0.row == row.y && column >= $0.startColumn && column < $0.endColumn }) {
                    context.drawRect(rect, color: AdaEngine.Color(red: 0.25, green: 0.45, blue: 0.8).opacity(0.5))
                }
                guard !cell.text.isEmpty, cell.text != " ", !cell.attribute.style.contains(.invisible) else { continue }
                let key = GlyphKey(text: cell.text, foreground: foreground, bold: cell.attribute.style.contains(.bold), width: cell.width)
                let layout: TextLayoutManager
                if let cached = glyphs[key] {
                    layout = cached
                } else {
                    if glyphs.count > 4096 { glyphs.removeAll(keepingCapacity: true) }
                    layout = TextLayoutManager()
                    var attributes = TextAttributeContainer()
                    attributes.font = AdaEditorCodeFont.font(family: .firaCode, weight: key.bold ? .bold : .regular, size: 14)
                    attributes.foregroundColor = foreground
                    layout.setTextContainer(TextContainer(text: AttributedText(cell.text, attributes: attributes)))
                    layout.fitToSize(rect.size)
                    glyphs[key] = layout
                }
                // Layout glyphs already use points. A rectangle transform would scale them by the cell size.
                if let line = layout.textLines.first {
                    let ascent = Float(line.typographicBounds.ascent)
                    let descent = Float(line.typographicBounds.descent)
                    var textContext = context
                    textContext.translateBy(x: rect.minX, y: -rect.minY - (cellHeight - ascent - descent) / 2 - ascent)
                    textContext.draw(line)
                }
            }
        }
        if !snapshot.cursor.hidden {
            context.drawRect(Rect(x: 6 + Float(snapshot.cursor.x) * cellWidth, y: 4 + Float(snapshot.cursor.y) * cellHeight + cellHeight - 2,
                                  width: cellWidth, height: 2), color: color(snapshot.cursorColor ?? snapshot.foregroundColor))
        }
        session.terminal.clearUpdateRange()
    }

    private func resolve(_ value: SwiftTerm.Attribute.Color, snapshot: TerminalRenderSnapshot, foreground: Bool) -> AdaEngine.Color {
        switch value {
        case .defaultColor: color(foreground ? snapshot.foregroundColor : snapshot.backgroundColor)
        case .defaultInvertedColor: color(foreground ? snapshot.backgroundColor : snapshot.foregroundColor)
        case let .ansi256(code): color(snapshot.palette[Int(code)])
        case let .trueColor(red, green, blue): AdaEngine.Color(red: Float(red) / 255, green: Float(green) / 255, blue: Float(blue) / 255)
        }
    }

    private func color(_ value: SwiftTerm.Color) -> AdaEngine.Color {
        AdaEngine.Color(red: Float(value.red) / 65535, green: Float(value.green) / 65535, blue: Float(value.blue) / 65535)
    }
}
