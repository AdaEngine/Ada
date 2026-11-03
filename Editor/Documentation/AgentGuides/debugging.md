# Debugging and Performance

Read this reference only when the task touches this area. Return to [the editor guide](../../AGENTS.md) for routing and shared rules.

Paths in code spans and commands retain their original `Editor/` working-directory context unless explicitly repository-relative; Markdown links resolve from this file.

This inventory was originally recorded on **2026-10-04** and subsequently maintained. Implementation and test links identify existing coverage, not a validation run or platform acceptance.

### Debugging and performance

Standalone desktop has a workspace-owned SwiftTerm/AdaUI terminal backed by
Unix PTY or Windows ConPTY. Terminal mode shows only shell tabs and icon actions;
each tab retains an independent shell and the grid follows window/panel resizing.
The left console tool opens Terminal; Output keeps
the Game/Editor logs. Windows launchers prepare LF SwiftTerm sources through
`ensure_windows_swiftterm.py` and `ADAEDITOR_SWIFTTERM_PACKAGE_PATH`; manual builds
need that override too. Tests lists discovered AdaScript/Swift tests with statuses
and exact single-function runs. See [WorkbenchPanels.md](../../Documentation/WorkbenchPanels.md)
and `EditorTestExplorerTests`, `EditorTerminalTests`, `EditorWorkbenchPanelTests`.
These source paths do not establish macOS/Linux UI validation.

Swift/macOS debugging through `lldb-dap`: breakpoints, pause/continue/step,
threads/frames, variables, watches and LLDB commands, with project persistence.
Game Performance panel: update rate, CPU update/p95, process memory, entity count,
ECS-system/render-node CPU durations, bounded history and Chrome Trace export.
Overview/Timeline views share the panel, with an expanded central-workspace mode.
Delayed, duration-limited CPU captures expose selectable event lanes, graph/node
details, filters, zoom and time navigation; overlapping calls use separate rows.
Profiler MCP tools address individual embedded game sessions and captures.

Guides: [Debugging.md](../../Documentation/Debugging.md),
[PerformancePanel.md](../../Documentation/PerformancePanel.md).
Coverage: [EditorDebuggerLaunchTests.swift](../../Tests/AdaEditorTests/EditorDebuggerLaunchTests.swift),
[EditorPerformanceTests.swift](../../Tests/AdaEditorTests/EditorPerformanceTests.swift).

## Boundaries and incomplete paths

- AdaScript execution debugging / VM pause-resume, mixed Swift/AdaScript debugging
  and an autonomous iPad debugger are not implemented. Saved breakpoint markers
  alone are not execution debugging.
- Performance measurements cover CPU/update cadence, not GPU time or display
  FPS. AdaPlayer/external Swift profiling is outside the current panel.
