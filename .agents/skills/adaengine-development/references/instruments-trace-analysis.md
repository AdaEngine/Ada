# Instruments Trace Analysis

Use this workflow for an existing Apple Instruments `.trace` package. It is designed for Time Profiler recordings that may also contain Hangs, Core Animation presents, and Metal Application data.

## Export

Always analyze a working copy. Instruments Analysis Core may update derived data inside a trace package, and exporting several schemas concurrently can fail or produce empty files.

```bash
TRACE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/adaengine-trace-export.XXXXXX")"
.agents/skills/adaengine-development/scripts/export_instruments_trace.sh \
  --trace /absolute/path/Capture.trace \
  --output "$TRACE_DIR"
```

The exporter preserves the original trace and writes:

- `toc.xml`
- `time-profile.xml` (required)
- `potential-hangs.xml`
- `ca-present.xml`
- `metal-application.xml`
- `run-issues.tsv`, when the trace contains an Instruments issue store

`xctrace` may need access to `~/Library/Caches/com.apple.dt.InstrumentsCLI`. If a sandboxed run fails there, request the normal command escalation instead of changing cache ownership or permissions.

## Analyze

```bash
.agents/skills/adaengine-development/scripts/analyze_instruments_trace.py \
  --input "$TRACE_DIR" \
  --process AdaEditor
```

The report includes active CPU sample weight, main-thread share, exclusive AdaEngine subsystem categories, inclusive first-party stacks, hangs, present cadence, Metal CPU encoding intervals, and recording issues.

## Interpretation Rules

- Time Profiler sample weight is active CPU time, not elapsed wall time. Multiple threads can contribute more than one CPU-second per wall-clock second.
- Inclusive stack percentages overlap. Do not add them together. Use exclusive categories for a partition of sampled CPU.
- Core Animation surfaces commonly rotate through a swapchain. Calculate frame cadence from all presents in timestamp order; per-surface deltas are not frame times.
- Metal `Encoding` intervals measure CPU-side command encoding. They do not prove GPU execution time. Require supported GPU counters or driver/GPU intervals before declaring a workload GPU-bound.
- `Wait for Next Drawable` commonly includes display pacing. Treat it as a bottleneck only when it correlates with long frame gaps and the CPU is not already blocked elsewhere.
- Read `run-issues.tsv`. Dropped events or an unsupported GPU counter profile make exact percentages incomplete even when the hotspot ordering remains useful.
- Before/after claims require the same user-visible flow, build configuration, device/display, recording duration, and Instruments settings. Prefer Deferred recording when Immediate mode reports dropped events.
- Verify that first-party symbols and source paths are present. Unsymbolicated addresses are a coverage gap, not evidence that application code is cheap.

## AdaEngine Triage Order

Start with the highest exclusive category, then inspect representative first-party stacks and the corresponding source:

1. view invalidation/reconciliation
2. text shaping/layout or editor syntax highlighting
3. UI tessellation/clipping
4. render/Metal CPU submission
5. shader compilation/cache, separating startup from steady state

Do not optimize a generic runtime leaf such as `swift_release`, `memmove`, or allocator code until its first-party parent stack identifies the owning subsystem.
