# Debugging in AdaEditor

## Implemented: Swift on macOS

Select an executable product and the macOS destination, add a breakpoint in the
source gutter, then press the Debug toolbar button. Debug saves open documents,
builds the product with SwiftPM's debug configuration in `.build/adaeditor-debug`,
and launches the executable through the selected Xcode's `lldb-dap`.

The Debug panel provides pause/continue, step into/over/out, thread and frame
selection, expandable variables, watches, and an LLDB command console. Return
submits a command or adds a watch; the Send/Add buttons also work.

Example LLDB commands:

```text
frame variable
bt
expression -- player.position
memory read --format x --size 1 --count 64 0xADDRESS
```

Replace `0xADDRESS` with a valid address in the debuggee. LLDB reports unreadable
memory as a command error. Debugger references belong to the current stop;
continuing, changing frames, or restarting discards previously expanded values.

Breakpoints and watches are saved per project under
`Application Support/AdaEditor/Debugging`. Source locations inside the project are
stored as relative paths. Editing moves breakpoint anchors, while the current
debuggee continues using its launch snapshot. Modified sources show a restart
notice and do not display a misleading execution-line marker.

The LLDB launch includes a source map between the physical compiler directory and
the editor's project URL. This matters for macOS aliases such as `/var` versus
`/private/var`, as well as projects opened through symbolic links.

## Not yet implemented: AdaScript execution debugging

The shared UI can retain AdaScript breakpoint locations, and the session model
defines a transport boundary for another adapter. **The AdaScript transport and
VM pause/resume are not implemented.** Debug on an AdaScript project reports this
explicitly. There is no mixed Swift/AdaScript session or autonomous iPad debugger
yet. Play and Preview continue to use their existing execution and logging paths.

Completing AdaScript requires changes below the editor UI:

- Compiler debug information for original source locations, lexical locals and
  captures, including a map through view-builder lowering.
- Resumable VM execution that preserves nested native-to-script callbacks without
  replaying side effects or keeping the main thread blocked.
- Lifetime management for borrowed ECS data while a callback is suspended.
- Scheduling a paused runtime separately from the editor: hosted SceneViews are
  currently awaited by the editor's frame loop.
- macOS runtime hosting, local iPad transport, validated VM object references,
  read-only expression evaluation and mixed-session coordination.

Do not implement an iPad breakpoint by waiting inside the current synchronous VM
call. That also stalls the editor's frame loop and can retain the global runtime
lock while the UI needs it.

## Validation

Run the independent debugger package tests:

```sh
swift test --package-path Editor/Debugging --scratch-path /tmp/ada-debugging-tests
```

They compile and debug real Swift programs, exercise memory reads, stepping,
pause/stop/restart, protocol framing and breakpoint relocation. macOS integration
tests require Xcode with `lldb-dap` and permission to debug a child process.

The editor's `EditorDebuggerTests` and `EditorDebuggerLaunchTests` verify state
persistence and the full selected-SwiftPM-product launch path. The engine's
`EditorDebuggerGutterTests` exercise real AdaUI mouse/touch routing and Return
submission, using the normal `AdaUITests` harness.

For a worktree without an adjacent AdaMCP checkout, set `ADA_MCP_LOCAL_PATH` to
the existing checkout when building or testing the editor. This does not change
the default package location.
