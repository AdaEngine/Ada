# Tests and terminal

The Tests panel discovers AdaScript `@test` declarations in the same source roots
and libraries used by the test runner. Discovery parses source without executing
project code. Swift projects use `swift test list`, which may build the tests.
Refresh Tests rescans after adding or removing declarations. Each row shows its
source/specifier, latest status and failure details; Run Test selects exactly one
function, and Run All Tests ignores the toolbar's saved test filter. Existing
results remain visible when another test is run. A build error or cancellation
leaves tests that did not finish as Not run. Swift Testing's version 0 JSON event
stream disambiguates equal function names in different suites.

Standalone macOS, Windows and Linux builds expose Terminal in the bottom panel.
The console button on the left opens it. Terminal mode shows only shell tabs and
icon actions (new, restart, copy, paste and close), with localized hover labels.
Output remains the Game/Editor log view in the Build tool's panel tabs. App Store/mobile builds
keep the log console and do not start local shells.

Each terminal tab owns a shell, starting in its project directory: `$SHELL` (or
`/bin/sh`) on macOS/Linux, `%ComSpec%` (normally `cmd.exe`) on Windows. Switching
panels or tabs keeps every session and buffer. Restart Terminal restarts the active
shell; closing a tab stops its process. Closing the final tab creates a fresh one.
Workspace destruction closes all PTYs and shells. The surface fills the bottom
panel and resizes its cell grid and PTY when the window or panel divider moves.

SwiftTerm's pinned, UI-independent engine handles ANSI colors, UTF-8, cursor
movement and alternate screens. The AdaUI surface renders the cell grid and
routes text, control keys, navigation/function keys, selection, clipboard paste,
scrollback and terminal mouse reporting. Cmd+C/V on macOS or Ctrl+Shift+C/V on
Windows/Linux copy and paste; Ctrl+C continues to reach the shell. The toolbar
provides Copy and Paste too. Graphical terminal image protocols, hyperlink
activation and IME composition previews are outside the current surface.

The native transport is `CEditorTerminal`: `forkpty`/`TIOCSWINSZ` on Unix and
ConPTY/job objects on Windows. Reads and writes are nonblocking; the main actor
feeds raw bytes to SwiftTerm, including split UTF-8 sequences, and sends its
terminal replies back to the shell. Shell input is never interpolated into a
process-launch command.

Windows builds use `script/ensure_windows_swiftterm.py` through the normal Studio
launcher. It checks out the pinned revision with LF line endings in `.build-tools`
and supplies `ADAEDITOR_SWIFTTERM_PACKAGE_PATH`. This avoids the upstream terminfo
generator's CRLF parsing issue without changing global Git settings or SwiftPM
checkouts. Manual Windows builds need this override as well as the existing
Gravity override. The shipped Assets include SwiftTerm's license.

Validation suites: `EditorTestExplorerTests`, `EditorTerminalTests`,
`EditorWorkbenchPanelTests`, `EditorWorkspaceResizeTests`, `EditorLocalizationTests`
and `EditorAdaScriptTestRunnerTests`. Native macOS
interaction still requires a macOS host; Linux PTY checks alone do not validate
the Linux editor surface.

Windows validation uses Swift 6.3.1. Tests exercise real SwiftPM discovery/filtering,
ConPTY shells and tab teardown, Unicode glyph geometry, selection, icon fonts,
default/inverse cell contrast, retained tab buffers and the mounted workspace's
window/divider resize path. Resolve SwiftTerm's default colors separately for
foreground and background; treating both as foreground hides ordinary shell text.
The latest terminal, workbench, workspace resizing and localization run passed
19 tests in four suites.

The complete standalone package was staged with its SDK. Native checks through
the editor's MCP API on a dedicated port verified creating/selecting/closing tabs,
Build → Terminal navigation and divider resizing from 146 to 266 points and back.
An editor-node screenshot confirmed the visible shell prompt, dark background and
icon toolbar. Linux PTY transport was also compiled and exercised in WSL. macOS
and Linux GUI interaction remain unverified.

The clean validation scratch build needed a temporary workaround for the existing
JavaScriptKit 0.59.0 `PackageToJS` Windows plugin error (`stderr` is unavailable):
the scratch checkout used `Foundation.FileHandle.standardError` instead. This is
an environment/dependency workaround, not a change to shipped engine sources.
