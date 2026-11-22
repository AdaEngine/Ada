import AdaEngine
import Foundation

@MainActor
private enum Palette {
    static let paper = Color.fromHex(0x171E28)
    static let panel = Color.fromHex(0x212B39)
    static let header = Color.fromHex(0x283446)
    static let rule = Color.fromHex(0x3B4B60)
    static let ink = Color.fromHex(0xE6EDF6)
    static let muted = Color.fromHex(0xA4B4C9)
    static let accent = Color.fromHex(0x6CE2CE)
    static let selected = Color.fromHex(0x304756)
}

private struct SourceFile: Identifiable {
    let folder: String
    let name: String
    let source: String
    var id: String { folder + "/" + name }

    static let fixture: [SourceFile] = [
        SourceFile(folder: "Sources", name: "OrbitalPath.swift", source:
            """
            import Foundation

            struct Vec2 {
                let x: Double
                let y: Double
            }

            struct Orbit {
                let radius: Double
                let eccentricity: Double
                let orientation: Double

                func position(at phase: Double) -> Vec2 {
                    let angle = phase * 2 * Double.pi
                    let distance = radius * (1 - eccentricity * eccentricity) / (1 + eccentricity * cos(angle))
                    // Rotate the ellipse so each orbit has an independent orientation within the system.
                    let heading = angle + orientation
                    return Vec2(x: distance * cos(heading), y: distance * sin(heading))
                }
            }

            """),
        SourceFile(folder: "Sources", name: "Preview.swift", source:
            """
            struct Preview {
                let duration: Double
                let sampleCount: Int

                func phases() -> [Double] {
                    return (0..<sampleCount).map { Double($0) / Double(sampleCount) }
                }
            }

            """),
        SourceFile(folder: "Sources", name: "Timeline.swift", source:
            """
            struct Timeline {
                var elapsed = 0.0

                mutating func advance(by seconds: Double) {
                    elapsed += seconds
                }
            }

            """),
        SourceFile(folder: "Tests", name: "OrbitalPathTests.swift", source:
            """
            import Testing

            @Test func circularOrbitStartsOnXAxis() {
                let orbit = Orbit(radius: 2, eccentricity: 0, orientation: 0)
                let point = orbit.position(at: 0)
                #expect(point.x == 2)
                #expect(point.y == 0)
            }

            """)
    ]

    static var sampleOrbitSource: String {
        fixture[0].source + (1...36).map { index in
            """

            // Preset \(index). These parameters can be edited while inspecting the preview.
            let orbit\(index) = Orbit(radius: \(index * 2), eccentricity: 0.2, orientation: .pi / 3)
            """
        }.joined(separator: "\n")
    }

    @MainActor static func tokens(in source: String) -> [TextEditorTokenSpan] {
        let keywords: Set<String> = ["import", "struct", "let", "var", "func", "return", "mutating"]
        return source.split(separator: "\n", omittingEmptySubsequences: false).enumerated().flatMap { line, text in
            if text.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                return [TextEditorTokenSpan(line: line, startColumn: 0, length: text.count, color: Palette.muted)]
            }
            return text.split(separator: " ").compactMap { word in
                guard keywords.contains(String(word)) else { return nil }
                return TextEditorTokenSpan(
                    line: line,
                    startColumn: text.distance(from: text.startIndex, to: word.startIndex),
                    length: word.count,
                    color: Palette.accent
                )
            }
        }
    }
}

@MainActor
private struct Workbench: View {
    private let wrapsLines = ProcessInfo.processInfo.environment["ORBIT_SOFT_WRAP"] != "0"

    @State private var selection: String = SourceFile.fixture[0].id
    @State private var documents: [String: String] = Dictionary(uniqueKeysWithValues: SourceFile.fixture.map {
        ($0.id, $0.id == SourceFile.fixture[0].id ? SourceFile.sampleOrbitSource : $0.source)
    })

    @State private var editorWidth: Float = 680
    @State private var dragStartWidth: Float? = nil

    var body: some View {
        GeometryReader { geometry in
            let dividerWidth: Float = 8
            let totalWidth = geometry.size.width
            let width = min(editorWidth, max(360, totalWidth - dividerWidth - 220))
            HStack(spacing: 0) {
                editor.frame(width: width, height: geometry.size.height)
                Palette.rule
                    .overlay { Palette.accent.frame(width: 2).allowsHitTesting(false) }
                    .frame(width: dividerWidth, height: geometry.size.height)
                    .cursorShape(.resizeLeftRight)
                    .gesture(DragGesture(minimumDistance: 1)
                        .onChanged { drag in
                            let start = dragStartWidth ?? width
                            if dragStartWidth == nil { dragStartWidth = start }
                            editorWidth = max(360, min(totalWidth - dividerWidth - 220, start + drag.translation.width))
                        }
                        .onEnded { _ in dragStartWidth = nil }
                        .onCancelled { dragStartWidth = nil })
                files.frame(width: max(0, totalWidth - width - dividerWidth), height: geometry.size.height)
            }
        }
        .background(Palette.paper)
    }

    private var editor: some View {
        VStack(spacing: 0) {
            bar(selection, color: Palette.ink)
            let id = selection
            TextEditor(
                text: Binding(
                    get: { documents[id, default: ""] },
                    set: { documents[id] = $0 }
                ),
                tokenSpans: SourceFile.tokens(in: documents[id, default: ""]),
                showsIndentationGuides: true,
                wrapsLines: wrapsLines
            )
            .font(.monospaced(size: 14))
            .foregroundColor(Palette.ink)
            .environment(\.textEditorColors, TextEditorColors(
                background: Palette.paper,
                border: Palette.paper,
                focusedBorder: Palette.rule,
                gutter: Palette.muted,
                gutterRule: Palette.rule,
                currentLineBackground: Palette.header,
                selection: Palette.selected
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.paper)
    }

    private var files: some View {
        VStack(spacing: 0) {
            bar("Project files", color: Palette.ink)
            ScrollView(.vertical, respectsSafeArea: false) {
                VStack(alignment: .leading, spacing: 3) {
                    folder("Sources")
                    folder("Tests")
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Palette.panel)
    }

    private func folder(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Palette.muted)
                .frame(height: 28)
            ForEach(SourceFile.fixture.filter { $0.folder == name }) { file in
                Button {
                    selection = file.id
                } label: {
                    Text(file.name)
                        .font(.system(size: 13))
                        .foregroundColor(selection == file.id ? Palette.accent : Palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .frame(height: 29)
                        .background(selection == file.id ? Palette.selected : Palette.panel)
                }
            }
        }
    }

    private func bar(_ title: String, color: Color) -> some View {
        Text(verbatim: title)
            .font(.system(size: 13, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 37)
            .background(Palette.header)
    }
}

@main
@MainActor
struct SplitEditorApp: App {
    var body: some AppScene {
        WindowGroup {
            Workbench()
        }
        .minimumSize(width: 1040, height: 640)
        .windowMode(.windowed)
        .windowTitle("Orbit Workspace")
        .transformAppWorlds { worlds in
            worlds.insertResource(ApplicationFramePacing(
                maximumFramesPerSecond: 120,
                minimumFramesPerSecond: 120
            ))
        }
    }
}
