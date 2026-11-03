# Swift Engineering

Read the root and nearest `AGENTS.md`, actual manifests, and `.swiftlint.yml`. The package language
mode and installed compiler version are separate concerns. Resolve toolchain versions from
`Tools/ada-toolchain.json` where present; do not introduce another independent version list.

## Isolation and Ownership

- UI, app lifecycle, and platform glue generally belong on `@MainActor`; preserve `WorldActor` boundaries.
- Pass Sendable values across isolation boundaries and prefer structured concurrency and explicit await.
- Avoid detached tasks, `nonisolated(unsafe)`, and `@unchecked Sendable` without a specific lifetime or
  synchronization argument. A C handle is not Sendable merely because it has a Swift wrapper.
- Propagate typed failures where practical. Validate C error codes and cleanup on every error/cancellation path.
- Prefer value data and explicit ownership in ECS paths. Do not retain unsafe storage pointers across
  structural changes. Inspect copy-on-write, temporary collections, locks, and reflection in frame loops.

## API and Style

Implement behavior in the narrow owning module. Keep imports minimal and sorted; use platform
conditionals for platform APIs. Avoid force unwraps and unnecessarily public declarations.
Document non-obvious public behavior, preserve source compatibility unless redesign was agreed,
and follow neighboring use of borrowing/consuming and fluent return values.

SwiftLint configuration defines automated rule enforcement. Stricter written project requirements
still apply during review; configuration/prose discrepancies must be resolved explicitly rather than
used as permission to weaken style. Lint and analyzer execution are distinct checks.

## Verification

New package tests use `import Testing`, suites/tests, and expect/require assertions. Exercise the
production path and failure behavior, not merely implementation structure. Concurrency changes need
access, cancellation, and lifetime cases where material. Macro/public API changes need downstream
compile validation. Measure performance using the repository benchmarks on a quiet machine.
