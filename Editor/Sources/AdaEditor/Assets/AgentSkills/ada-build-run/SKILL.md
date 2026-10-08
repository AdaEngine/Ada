---
name: ada-build-run
description: Build, test, run, stop, and diagnose Ada projects on their supported destination.
allowed-tools: terminal, editor.project.context, editor.build.start, editor.test.start, editor.play.start, editor.task.status, editor.task.stop, editor.output.read, runtime.pause, runtime.resume, runtime.step_frame, trace.status, profiler.live_snapshot
---

# Ada Build and Run

- Use `editor.project.context` to check which project and document are open before choosing a build or run command. The editor MCP exposes project context and scene authoring; use the existing build/run workflow for compilation and tests.
- Prefer `editor.build.start`, `editor.test.start`, and `editor.play.start` to use the editor's selected destination and native AdaScript/SwiftPM flow. Poll `editor.task.status`, then read the `editor` or `game` output stream with `editor.output.read`.
- Use `editor.task.stop` for a running build, test, run, debugger, player, or Play Mode session.
- Save dirty documents before starting a build or run.
- AdaScript-only projects build in process and may run on macOS or iPadOS. SwiftPM build, test, and run is a macOS workflow in AdaEditor.
- Prefer the narrowest build or test that exercises the changed path, then broaden when the change crosses modules.
- Read structured diagnostics and complete output before editing again. Separate code failures from toolchain, network, storage, or platform failures.
- Stop an existing run before replacing its runtime state. Report the exit or stop reason.
