# SLOPPY — AdaEditor ProjectSystem implementation notes

This file records the implementation details for the Sloppy task that moved the Ada project metadata logic into `Sources/AdaEditor`.

## Scope

The project metadata system belongs to the editor product layer, not to the shared utilities package. The current implementation keeps Ada project discovery, loading, validation, migration hooks, and default metadata generation inside the `AdaEditor` module.

## Source layout

- `Sources/AdaEditor/ProjectSystem.swift`
  - Defines `ProjectSystem`.
  - Defines `ProjectSystemPath`.
  - Defines the `AdaProject` metadata model and nested sections.
  - Defines `ProjectSystemError` structured errors.
- `Tests/AdaEditorTests/ProjectSystemTests.swift`
  - Contains the unit and negative tests for `ProjectSystem`.
- `Tests/AdaEditorTests/Fixtures/ProjectSystem/`
  - Contains valid and invalid committed `project.json` fixtures.
- `Package.swift`
  - Registers `AdaEditorTests` as the test target for the `AdaEditor` module.

## Project metadata contract

Ada projects use a portable metadata file at:

```text
.ada/project.json
```

The editor treats this file as committed project configuration. Local editor state and generated data should stay out of source control:

```text
.ada/workspace.json
.ada/cache/
.ada/logs/
.ada/indexes/
.ada/ai/cache/
```

## Schema version 1

`schemaVersion` is required. Version `1` is currently supported.

Optional top-level sections are:

- `project`
- `engine`
- `paths`
- `build`
- `run`
- `editor`
- `ai.mcp`

`ProjectSystem` supplies stable defaults for omitted optional sections.

## Path validation rules

All path-like values in `.ada/project.json` are portable project-relative paths.

Rejected values include:

- POSIX absolute paths, for example `/tmp/Game`.
- Windows absolute paths, for example `C:\\Game`.
- Home-relative paths, for example `~/Game`.
- URLs.
- Backslash path syntax.
- Empty path segments, for example `Assets//Sprites`.
- Parent traversal segments, for example `../Secrets`.

## Build system support

The supported build system is Swift Package Manager:

```json
{
  "build": {
    "system": "swiftpm"
  }
}
```

The legacy draft field `buildSystem` is still decoded for compatibility and maps to the same `swiftpm` enum value.

## Default project generation

`ProjectSystem.createDefaultProject(at:)` creates `.ada/project.json` for an existing SwiftPM project. It requires `Package.swift` to exist at the project root.

The generated metadata defaults to:

- `schemaVersion: 1`
- `build.system: swiftpm`
- `paths.sources: Sources`
- `paths.assets: Assets`
- `paths.build: .build`
- `paths.run.workingDirectory: .`
- `run.workingDirectory: .`
- `ai.mcp.enabled: true`

## Error model

`ProjectSystemError` exposes structured failures with stable `code` and `fieldPath` values so the editor UI, diagnostics, and future MCP resources can display actionable validation messages.

Important error classes include:

- Missing `.ada/project.json`.
- Invalid JSON.
- Missing `schemaVersion`.
- Unsupported schema version.
- Unknown build system.
- Invalid, absolute, or traversing paths.
- Missing `Package.swift` when creating default metadata.
- File read/write failures.

## Test coverage

The current tests cover:

- Loading minimal and full committed fixtures.
- Legacy `buildSystem` decoding.
- Ada project detection.
- Missing metadata errors.
- Invalid JSON errors.
- Negative fixture rejection.
- Unsupported build systems.
- Invalid path validation.
- Default metadata generation.
- Default JSON snapshot output.
- SwiftPM manifest requirement for default project creation.

## Verification commands

Smallest relevant verification for this area:

```bash
swift test --filter ProjectSystem
```

Required project-level verification before closing implementation work:

```bash
swift build
```

## Follow-up direction

Keep editor-only project metadata behavior in `AdaEditor`. If the editor is later split into a separate repository/product, `ProjectSystem` and these tests should move with the editor layer rather than back into `AdaUtils`.
