@_spi(AdaEngine) import AdaEngine
import AdaPackageManifestTool
import Foundation
import Observation

struct EditorToolStripItem: Equatable, Sendable {
    var identifier: String
    var title: String
    var icon: String
}

struct EditorCodeColorPalette: Hashable, Sendable {
    var plainText: Color
    var keyword: Color
    var type: Color
    var string: Color
    var number: Color
    var comment: Color
    var punctuation: Color
    var lineNumber: Color
    var currentLineBackground: Color
    var selection: Color
    var annotation: Color?
    var function: Color?
    var member: Color?

    var annotationColor: Color { annotation ?? keyword }
    var functionColor: Color { function ?? type }
    var memberColor: Color { member ?? type }

    static let dark = Self(
        plainText: Color(red: 214 / 255, green: 217 / 255, blue: 224 / 255),
        keyword: Color(red: 197 / 255, green: 134 / 255, blue: 252 / 255),
        type: Color(red: 78 / 255, green: 201 / 255, blue: 176 / 255),
        string: Color(red: 214 / 255, green: 157 / 255, blue: 133 / 255),
        number: Color(red: 181 / 255, green: 206 / 255, blue: 168 / 255),
        comment: Color(red: 106 / 255, green: 153 / 255, blue: 85 / 255),
        punctuation: Color(red: 172 / 255, green: 176 / 255, blue: 190 / 255),
        lineNumber: Color(red: 101 / 255, green: 108 / 255, blue: 122 / 255),
        currentLineBackground: Color(red: 43 / 255, green: 45 / 255, blue: 52 / 255),
        selection: Color(red: 53 / 255, green: 116 / 255, blue: 240 / 255).opacity(0.24)
    )

    static let godot = Self(
        plainText: Color.fromHex(0xB0CCE1),
        keyword: Color.fromHex(0xFF7085),
        type: Color.fromHex(0x42E0BB),
        string: Color.fromHex(0xE1D38C),
        number: Color.fromHex(0x92D8C8),
        comment: Color.fromHex(0x808080),
        punctuation: Color.fromHex(0xABC9FF),
        lineNumber: Color.fromHex(0xAAAAAA),
        currentLineBackground: Color.fromHex(0x292929),
        selection: Color.fromHex(0x405C78).opacity(0.65),
        annotation: Color.fromHex(0xECA05D),
        function: Color.fromHex(0x60C7DF),
        member: Color.fromHex(0xB0CCE1)
    )

    static let monokai = Self(
        plainText: Color(red: 248 / 255, green: 248 / 255, blue: 242 / 255),
        keyword: Color(red: 249 / 255, green: 38 / 255, blue: 114 / 255),
        type: Color(red: 166 / 255, green: 226 / 255, blue: 46 / 255),
        string: Color(red: 230 / 255, green: 219 / 255, blue: 116 / 255),
        number: Color(red: 174 / 255, green: 129 / 255, blue: 255 / 255),
        comment: Color(red: 117 / 255, green: 113 / 255, blue: 94 / 255),
        punctuation: Color(red: 248 / 255, green: 248 / 255, blue: 242 / 255),
        lineNumber: Color(red: 144 / 255, green: 142 / 255, blue: 126 / 255),
        currentLineBackground: Color(red: 62 / 255, green: 61 / 255, blue: 50 / 255),
        selection: Color(red: 73 / 255, green: 72 / 255, blue: 62 / 255)
    )

    static let solarized = Self(
        plainText: Color(red: 131 / 255, green: 148 / 255, blue: 150 / 255),
        keyword: Color(red: 133 / 255, green: 153 / 255, blue: 0 / 255),
        type: Color(red: 38 / 255, green: 139 / 255, blue: 210 / 255),
        string: Color(red: 42 / 255, green: 161 / 255, blue: 152 / 255),
        number: Color(red: 211 / 255, green: 54 / 255, blue: 130 / 255),
        comment: Color(red: 88 / 255, green: 110 / 255, blue: 117 / 255),
        punctuation: Color(red: 147 / 255, green: 161 / 255, blue: 161 / 255),
        lineNumber: Color(red: 88 / 255, green: 110 / 255, blue: 117 / 255),
        currentLineBackground: Color(red: 7 / 255, green: 54 / 255, blue: 66 / 255),
        selection: Color(red: 38 / 255, green: 139 / 255, blue: 210 / 255).opacity(0.25)
    )
}

enum EditorCodePalettePreset: String, CaseIterable, Hashable, Sendable {
    case adaDark
    case godot
    case monokai
    case solarized

    var title: String {
        switch self {
        case .godot:
            "Godot"
        case .adaDark:
            "Ada Dark"
        case .monokai:
            "Monokai"
        case .solarized:
            "Solarized Dark"
        }
    }

    var palette: EditorCodeColorPalette {
        switch self {
        case .godot:
            .godot
        case .adaDark:
            .dark
        case .monokai:
            .monokai
        case .solarized:
            .solarized
        }
    }

    static func matching(_ palette: EditorCodeColorPalette) -> Self {
        allCases.first { $0.palette == palette } ?? .adaDark
    }
}

enum EditorCodeFontFamily: String, CaseIterable, Hashable, Sendable {
    case firaCode
    case system

    var title: String {
        switch self {
        case .firaCode:
            "Fira Code"
        case .system:
            "System"
        }
    }
}

enum EditorCodeFontWeight: String, CaseIterable, Hashable, Sendable {
    case light
    case regular
    case medium
    case semibold
    case bold

    var title: String {
        rawValue.capitalized
    }
}

enum EditorSourceLanguage: String, Sendable {
    case ada
    case c
    case cpp
    case glsl
    case wgsl
    case json
    case markdown
    case metal
    case packageManifest
    case plainText
    case swift
    case yaml

    static func detect(fileName: String) -> Self {
        let lowercasedName = fileName.lowercased()
        let fileExtension = URL(fileURLWithPath: lowercasedName).pathExtension

        if lowercasedName == "package.swift" {
            return .packageManifest
        }

        switch fileExtension {
        case "ada",
            "gravity":
            return .ada
        case "c",
            "h":
            return .c
        case "cc",
            "cpp",
            "cxx",
            "hpp",
            "hxx":
            return .cpp
        case "comp",
            "frag",
            "geom",
            "glsl",
            "shader",
            "tesc",
            "tese",
            "vert":
            return .glsl
        case "wgsl":
            return .wgsl
        case "json":
            return .json
        case "md",
            "markdown":
            return .markdown
        case "metal":
            return .metal
        case "swift":
            return .swift
        case "yaml",
            "yml",
            "tileset":
            return .yaml
        default:
            return .plainText
        }
    }

    var supportsLanguageTooling: Bool {
        self == .ada || self == .swift || self == .packageManifest
    }
}

enum EditorProjectFileKind: Equatable, Sendable {
    case folder
    case scene
    case text(EditorSourceLanguage)
    case image
    case audio
    case genericAsset
    case unsupported
}

enum EditorAssetPreviewKind: String, Equatable, Sendable {
    case tileSource
    case atlas
    case image
    case audio
    case generic
}

struct EditorTextDocument: Equatable, Sendable {
    var id: String
    var title: String
    var relativePath: String
    var absolutePath: String?
    var language: EditorSourceLanguage
    var content: String
    var lastSavedContent: String?
    var isReadOnly: Bool = false
    var errorMessage: String?
    var isDirty: Bool = false
    var statusMessage: String?
    var diagnostics: [EditorDiagnostic] = []
    var semanticTokens: [EditorSemanticToken] = []
    var completionItems: [EditorCompletionItem] = []
    var completionPosition: EditorSourceLocation?
    var selectedCompletionIndex = 0
    var symbolHighlights: [EditorSourceRange] = []
    var sourceHoverRange: EditorSourceRange?
    var sourceHoverDescription: String?
    var focusedRange: EditorSourceRange?
    var selectionRange: EditorSourceRange?
    var selectedText: String?
}

struct EditorSceneDocument: Equatable, Sendable {
    var id: String
    var title: String
    var relativePath: String
    var absolutePath: String?
    var content: String
    var lastSavedContent: String?
    var isReadOnly: Bool = false
    var sceneModel: EditorSceneModel?
    var errorMessage: String?
    var isDirty: Bool
    var statusMessage: String?
    var loadSummary: EditorSceneLoadSummary
}

struct EditorAssetDocument: Equatable, Sendable {
    var id: String
    var title: String
    var relativePath: String
    var absolutePath: String?
    var assetReference: String?
    var kind: EditorAssetPreviewKind
    var fileExtension: String
    var byteCount: Int64?
    var modifiedAt: Date?
    var errorMessage: String?
}

enum EditorWorkbenchDocument: Equatable, Sendable {
    case scene(EditorSceneDocument)
    case ui(EditorTextDocument)
    case text(EditorTextDocument)
    case asset(EditorAssetDocument)
    case git(EditorGitDocument)

    var id: String {
        switch self {
        case let .scene(document):
            document.id
        case let .text(document),
            let .ui(document):
            document.id
        case let .git(document):
            document.id
        case let .asset(document):
            document.id
        }
    }

    var title: String {
        switch self {
        case let .scene(document):
            document.title
        case let .text(document),
            let .ui(document):
            document.title
        case let .git(document):
            document.title
        case let .asset(document):
            document.title
        }
    }

    var relativePath: String {
        switch self {
        case let .scene(document):
            document.relativePath
        case let .text(document),
            let .ui(document):
            document.relativePath
        case .git:
            ""
        case let .asset(document):
            document.relativePath
        }
    }

    var absolutePath: String? {
        switch self {
        case let .scene(document):
            document.absolutePath
        case let .text(document),
            let .ui(document):
            document.absolutePath
        case .git:
            nil
        case let .asset(document):
            document.absolutePath
        }
    }

    var isDirty: Bool {
        switch self {
        case let .scene(document):
            document.isDirty
        case let .text(document),
            let .ui(document):
            document.isDirty
        case .asset,
            .git:
            false
        }
    }
}

enum EditorWorkspaceStatus: Equatable, Sendable {
    case idle
    case resolving
    case indexing
    case preparing(SwiftPMWorkspaceProgress)
    case ready
    case running(String)
    case failed(String)
    case cancelled

    var title: String {
        switch self {
        case .idle:
            "Idle"
        case .resolving:
            "Resolving"
        case .indexing:
            "Indexing"
        case let .preparing(progress):
            progress.progressText
        case .ready:
            "Ready"
        case let .running(command):
            "Running \(command)"
        case .failed:
            "Failed"
        case .cancelled:
            "Cancelled"
        }
    }
}

enum EditorPlayModeState: Equatable, Sendable {
    case editing
    case playing(sceneDocumentID: String, title: String)
    case failed(String)

    var isPlaying: Bool {
        if case .playing = self {
            return true
        }

        return false
    }
}

struct EditorWorkspaceLogLine: Equatable, Sendable, Identifiable {
    static let maximumTextLength = 2_048

    let id: String
    let text: String

    init(id: String = UUID().uuidString, text: String) {
        self.id = id

        let truncationIndex = text.index(
            text.startIndex,
            offsetBy: Self.maximumTextLength,
            limitedBy: text.endIndex
        )
        if let truncationIndex, truncationIndex != text.endIndex {
            self.text = "\(text[..<truncationIndex])… [truncated]"
        } else {
            self.text = text
        }
    }
}

enum EditorWorkspaceLogBuffer {
    static let maximumLineCount = 400

    static func appending(
        _ textLines: [String],
        to existingLines: [EditorWorkspaceLogLine]
    ) -> [EditorWorkspaceLogLine] {
        guard !textLines.isEmpty else {
            return existingLines
        }

        let retainedExistingCount = max(0, maximumLineCount - textLines.count)
        var result = Array(existingLines.suffix(retainedExistingCount))
        result.append(contentsOf: textLines.suffix(maximumLineCount).map { EditorWorkspaceLogLine(text: $0) })
        return result
    }
}

@MainActor
enum EditorPreviewStatus {
    case hidden
    case unavailable(String)
    case available([EditorPreviewDeclaration])
    case building(EditorPreviewDeclaration, String)
    case loaded(EditorPreviewDeclaration, UIView)
    case failed(EditorPreviewDeclaration?, String, Bool)
}

@MainActor
struct EditorLoadedPreview {
    var documentID: String
    var declaration: EditorPreviewDeclaration
    var view: UIView

    func matches(documentID: String, previewID: String) -> Bool {
        self.documentID == documentID && declaration.id == previewID
    }
}
