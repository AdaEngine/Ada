# Projects, Files and Workbench

Read this reference only when the task touches this area. Return to [the editor guide](../../AGENTS.md) for routing and shared rules.

Paths in code spans and commands retain their original `Editor/` working-directory context unless explicitly repository-relative; Markdown links resolve from this file.

This inventory was originally recorded on **2026-10-04** and subsequently maintained. Implementation and test links identify existing coverage, not a validation run or platform acceptance.

- The project file tree starts collapsed and persists expanded relative folder
  paths per project. Its header has icon buttons for New File and recursive
  expand/collapse, plus a crosshair to reveal the active tab, open its ancestors
  and scroll to its selected row. Disclosure animates row height/opacity and the
  chevron; interrupted transitions retain their current presentation. Targets
  must not list descendants of an existing root as additional roots with duplicate IDs.
  Refreshes preserve existing expansion and close new folders.
  Visibility filtering indexes collapsed relative paths once and checks each
  item's ancestors. Do not search the entire item array for every collapsed
  folder per file: that stalls unrelated tab changes in large asset trees.
  Selection updates per-row observable handles; tree topology has its own
  revision. Keep `selectedItem` and `items` snapshots accurate without notifying
  the whole tree for a tab selection. Let the scroll view constrain row width;
  a surrounding GeometryReader rebuilt the row menus during unrelated layout.
  Imports expand the destination's ancestors so the copied files are visible.
  Coverage: `EditorProjectTreeStateTests` and `EditorFileDropTests`.
- Source highlighting and semantic position conversion use `EditorSourceLines`
  so Windows CRLF counts as one newline, matching TextEditor's normalized text.
  Live text selections are kept outside the observed document array; command
  snapshots merge them through `textDocument(id:)` and pane/active accessors.
  Caret geometry is observed by the completion overlay, not the whole code view.
  Consecutive captured text-selection moves coalesce within a UI input batch;
  other drags and the raw scene input stream retain every event. Coverage:
  `EditorTextInteractionPerformanceTests` and `EditorWindowHoverInputTests`.
- Double Shift focuses project file search. Windows observes parsed AdaInput
  before focused UI controls; macOS uses its local event monitor. Keep repeats,
  modifier chords, intervening clicks/keys and window changes out of the gesture.
  Install its system through `EditorSearchShortcutPlugin`: scheduler creation
  during app startup replaces systems registered early in `transformAppWorlds`.

### Projects and files

Desktop project windows display staged loading while metadata, the complete file
index, script catalogs and the restored document are prepared off the UI actor.
The workspace reuses that snapshot; file sorting snapshots directory/link metadata
once per entry. Scene loading reports decoding, resource discovery, completed/total
distinct model/skeleton imports and object creation. Closing a load discards its
result. Coverage: `EditorProjectLoadingTests`, `EditorProjectStartupTests` and
`EditorSceneAssetCacheTests`; see [SceneLoading.md](../../Documentation/SceneLoading.md).

Project creation/opening, recent projects, project persistence and recovery;
AdaScript and standalone SwiftPM project paths. Project navigator, new-file
templates, asset import/file drop, deletion, file search, Save and Save All.
Project settings cover runtime entry, plugins, input actions and resource roots;
standalone SwiftPM tooling includes dependencies, products, targets and tasks.
The project navigator lists all project entries without a count cap. `.builds/`
is reserved for local build products and excluded from the navigator, project
text search and filesystem-triggered refreshes.

Entry points: [ProjectSystem.swift](../../Sources/AdaEditor/ProjectSystem.swift),
[EditorProjectStore.swift](../../Sources/AdaEditor/EditorProjectStore.swift),
[EditorViewModel+ProjectConfiguration.swift](../../Sources/AdaEditor/UI/Editor/EditorViewModel+ProjectConfiguration.swift).
Coverage: [ProjectSystemTests.swift](../../Tests/AdaEditorTests/ProjectSystemTests.swift),
[EditorFileDropTests.swift](../../Tests/AdaEditorTests/EditorFileDropTests.swift).

The HUB Samples section loads the official AdaExamples catalog, supports search
by name/tags, downloads a separate editable project into a selected folder, and
opens it through the ordinary project loader. Swift projects require standalone.
`ADAEXAMPLES_PATH` selects a local catalog for development; otherwise catalog and
files use one pinned GitHub commit. Games live in AdaExamples, with independent
engine regression fixtures. Guide: [Examples.md](../../Documentation/Examples.md).
Coverage: [EditorExampleCatalogTests.swift](../../Tests/AdaEditorTests/EditorExampleCatalogTests.swift).

### Workbench and code

Document tabs, tab reordering, Back/Forward navigation, restoration, resizable
panels, and two independently selected document panes with Split/Merge/move
actions. Code and scene documents can remain visible together.
Opening a file that already has an ordinary tab selects its existing document;
it preserves unsaved edits, prepared scene data and external-write conflict checks.
Raw and source-control review tabs remain distinct. Hierarchy panels request
label-only rows: do not scan numeric mesh/collider payloads for unused resource links
while mounting, searching or updating the scene hierarchy.
Text editing, syntax highlighting for Swift/AdaScript/YAML/GLSL, completion,
snippet placeholders, hover, definition navigation and diagnostics. Swift uses
SourceKit-LSP; AdaScript uses the embedded language core / language server.
AdaScript workspace diagnostics also run the shared `AdaScriptLinter`: operator,
comma/colon and control-keyword spacing, separate statement lines, and blank
lines between type/function declarations. They publish warning diagnostics with
source `adascript-lint` and stable rule codes. Desktop `adastudio validate --lint strict`
checks saved authored sources and tests and returns exit code 3 for style
violations; the default `warning` mode preserves successful validation. See
[AdaScriptLint.md](../../Documentation/AdaScriptLint.md). Coverage: `AdaScriptLintTests`,
`GravityLintTests` and `EditorAdaScriptLintTests`.
Find in File and Find in Project include case and whole-word controls.
Indentation guides, tab markers and space dots default to off. Explicit saved
display preferences, including the legacy combined toggle, are preserved.

Entry points: [EditorCenterWorkbench.swift](../../Sources/AdaEditor/UI/Editor/EditorCenterWorkbench.swift),
[EditorWorkbenchViewModel+Split.swift](../../Sources/AdaEditor/UI/Editor/EditorWorkbenchViewModel+Split.swift),
[EditorViewModel+SourceTooling.swift](../../Sources/AdaEditor/UI/Editor/EditorViewModel+SourceTooling.swift).
Coverage: [EditorWorkbenchSplitTests.swift](../../Tests/AdaEditorTests/EditorWorkbenchSplitTests.swift),
[GravityLiveEditorTests.swift](../../Tests/AdaEditorTests/GravityLiveEditorTests.swift),
[EditorTextSearchTests.swift](../../Tests/AdaEditorTests/EditorTextSearchTests.swift).
