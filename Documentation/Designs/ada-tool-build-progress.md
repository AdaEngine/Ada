# Ada Tool Build Progress

`ada_tool.py` sends compiler output to a file and forwards selected lines to
the terminal. During quiet parts of an Xcode build, `install studio` may sit
at the compiler log path with no indication of elapsed time.

## Terminal behavior

While the compiler runs, show one updating status line on interactive stderr.
Use an ASCII spinner and elapsed time measured from compiler launch with a
monotonic clock. For example:

```text
Compiler log: .build-tools/ada-tool/macos-arm64/studio-release-build.log
| Building... 00:47 elapsed
```

The indicator updates even when the compiler is silent. Build duration is
unknown, so use the spinner for activity and continue forwarding any progress
lines emitted by SwiftPM. Temporarily clear the status line when forwarding
output. Stop the indicator before printing the log tail, reporting a failure,
or returning control to the terminal after Ctrl-C. Print a final elapsed time
on a separate line when compilation exits normally, including nonzero exits.
Redirected stderr keeps its existing line-oriented output. Dry runs emit only
their existing command previews.

## Scope and ownership

The logged compiler subprocess in `script/ada_tools/context.py` owns the
indicator. This covers `build studio`, `build engine`, and `install studio`
when it compiles from source, across macOS, Linux, and Windows. The timer
measures compilation. Project generation, signing, packaging, and copying
an existing distribution are outside that interval. Use Python's standard
library and preserve the existing compiler log, error reporting, and
subprocess cancellation behavior.

## Verification and documentation

Extend `script/test_ada_tool.py` using a short-lived child process to verify
timer updates during silence, complete log capture, and ordinary output on
redirected stderr. Check failure and Ctrl-C cleanup in an interactive
terminal and run the existing CLI suite and contributor checks. Record which
hosts were exercised.

Update the existing **Build without installing** section in
[`Documentation/Tooling.md`](../Tooling.md), including the behavior of
`python ada_tool.py install studio`. Keep the guide's existing navigation.
