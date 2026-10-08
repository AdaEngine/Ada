# ADR-0008: Run portable AdaScript projects on iPadOS

- Status: Accepted
- Date: 2026-09-05
- Implementation: Partial (project foundation shipped)

## Context

AdaEditor needs to create, edit, synchronize, and run Ada Script projects on
iPadOS. An iPad application cannot rely on a user-installed Swift toolchain or
compile arbitrary project Swift sources. The native AdaEngine and AdaEditor
code can still ship as a precompiled Swift application while project-owned game
behavior is compiled by the embedded AdaScript runtime.

The existing project model assumes every project is a SwiftPM executable. Even
the Ada Script template emits `Package.swift` and a generated Swift `@main`
bootstrap. The project validator requires that manifest to exist. The existing
Apple window manager can create multiple engine windows, but attaches them to
the currently active UIKit scene instead of requesting a separate iPadOS window
scene.

[ADR-0003](0003-ada-script-components-and-resources.md) also generates native
Swift backing types for every Ada Script component and resource. That is a good
compiled-project representation, but schema changes cannot work in a
AdaScript-only project without a runtime ECS layout.

Projects may live in Files, iCloud Drive, or another File Provider. Those URLs
are not guaranteed to be continuously local and must use coordinated,
security-scoped access. Git repositories add a second synchronization model
whose atomic filesystem operations must not be confused with document sync.

## Decision

### Separate the native host from project code

AdaEditor remains a precompiled Swift application with the only process-level
`@main`. An AdaScript project contains no generated Swift bootstrap and does not
invoke `App.main()`.

The host owns one platform application and creates project runtime sessions.
Each session owns its Ada Script module generation, game world, asset context,
diagnostics, and window identity. Starting a project session must not invoke a
second `UIApplicationMain` or install another process-wide platform plugin.

The existing Swift `App` protocol remains available to native applications.
Its bootstrap will be factored through the same host runtime primitives rather
than becoming an AdaScript protocol.

### Declare the build system in project metadata

Schema version 2 recognizes two build systems:

- `adascript` is a portable project loaded directly from `.ada` sources;
- `swiftpm` is a native or hybrid project that may contain Swift.

An AdaScript project uses `.ada/project.json`, `Sources`, and `Assets` without a
`Package.swift`. Its runtime settings declare a stable module name, an entry
`@view` identifier, and an optional startup scene.

The legacy view entry field is retained for project compatibility but cannot
activate an AdaScript view while [ADR-0016](0016-temporarily-disable-adascript-adaui.md)
is in force.

SwiftPM remains supported on platforms with a suitable native toolchain. On
iPadOS, Build and Run reject every SwiftPM project and every AdaScript project
whose source root contains a `.swift` file. The diagnostic identifies the build
system or offending source path and recommends opening the project on macOS or
converting it to AdaScript.

Opening a project for inspection is distinct from executing it. AdaEditor may
show unsupported source files, but must not silently ignore or attempt to build
them on iPadOS.

### Compile AdaScript in process

Opening or building an AdaScript workspace enumerates its complete source root,
creates target-relative `AdaScriptSource` values, validates annotations and the
configured entry view, and compiles the module through the serialized AdaScript
runtime coordinator. It does not invoke SwiftPM.

Runtime activation follows the immutable-generation and safe-point rules from
[ADR-0007](0007-ada-script-runtime-and-hot-reload.md). A failed build retains
the previous active generation when one exists.

### Use runtime ECS layouts for script data

Maximum iPadOS support requires script-defined components and resources to stop
depending on newly generated Swift metatypes. Script-defined components use a
memory-safe `RuntimeComponentPayload` carrier while every schema receives its
own deterministic `ComponentId`, reflection table, defaults, and coding rules.
This avoids synthesizing unsafe size/alignment/destructor metadata for arbitrary
layouts while preserving the ECS identity that matters to archetypes and
scheduling.

Each script component retains a distinct archetype column and scheduler access
identity. Storing every script component in one dictionary component remains
rejected because it would lose archetype filtering, per-component conflicts,
change tracking, and chunk iteration. Native Swift component types adapt to the
same layout abstraction without losing their typed APIs.

Portable AdaScript builds now accept `@component` and
`@replicated_component` without generating or compiling Swift. Runtime-defined
resources remain unsupported and fail with an explicit diagnostic; they must
never fall back to compiling Swift on iPadOS.

### Give each runtime session its own platform resources

Assets, input routing, render extraction, and windows must be scoped to the
project session. In particular, `AssetsManager` cannot keep one mutable
process-wide project root when the editor and a game window are active
together. Input events are routed by engine window identifier to the owning
world.

On iPadOS, running a game requests a new `UIWindowScene` and associates its
scene session with the AdaEditor project-session identifier. The editor and
game therefore participate in native iPad multitasking and lifecycle
restoration instead of placing two engine windows in one UIKit scene.

### Treat Files as the document authority

The canonical portable representation is a directory package with the
`.adaproject` extension. AdaEditor registers its content type and opens it with
a document browser. Existing directory projects may be imported.

Document access uses `UIDocument` or `NSFilePresenter` with `NSFileCoordinator`.
External directories use security-scoped URLs and persistent bookmarks. The
runtime consumes a coordinated snapshot and does not assume that iCloud or
third-party File Provider content is already downloaded.

iCloud Drive support comes from the system document browser. A separate
CloudKit data model is not required for the initial implementation.

### Keep Git worktrees local

Git integration uses `swift-libgit2` behind an actor because remote operations
are synchronous and must not block the main actor. Credentials belong in the
Keychain and are never stored in project metadata.

Git worktrees live in AdaEditor's local application container. A `.git`
directory is not synchronized as part of an iCloud document package. Import,
export, clone, and explicit synchronization connect local Git worktrees with
Files documents without allowing two independent systems to coordinate Git
lock files and atomic renames.

## Implementation status

Shipped in the first foundation slice:

- [x] Schema version 2 and the `adascript` build-system value.
- [x] AdaScript project validation without `Package.swift`.
- [x] Stable runtime module and entry-view settings.
- [x] A pure Ada Script template with no generated Swift source.
- [x] Native `App.main()` delegates process startup through `AppRuntime`.
- [x] iPadOS compatibility diagnostics for SwiftPM and `.swift` sources.
- [x] In-process AdaScript workspace compilation without SwiftPM.
- [x] Explicit rejection of script data schemas until runtime ECS layouts ship.
- [x] `.adaproject` directory packages, exported iOS content type, and in-place
  Files project picker.
- [x] iPad application metadata opts into document browsing and multiple scenes.

Remaining:

- [ ] Extract project schema/runtime loading from the Editor target into a
  reusable engine-level module.
- [ ] Add isolated project runtime sessions and project-scoped assets/input.
- [ ] Launch and restore a separate game `UIWindowScene` on iPadOS.
- [ ] Implement runtime ECS component and resource layouts.
- [ ] Add `UIDocument` coordination, security-scoped bookmark persistence, and
  relaunch restoration for cloud-backed projects.
- [ ] Integrate `swift-libgit2` using local worktrees and Keychain credentials.
- [ ] Validate a real iCloud project open, AdaScript build, separate-window run,
  editing, save, relaunch, and restoration flow on an iPad device.

## Consequences

- Portable projects no longer need a Swift package or generated application
  entry point.
- Hybrid projects remain first-class on desktop but cannot execute on iPadOS.
- Project settings become the source of truth for AdaScript startup.
- The Editor can compile portable projects on device before the complete game
  session and Files layers ship.
- Runtime ECS layouts and session-scoped platform resources are foundational
  engine changes rather than iPad-only adapters.
- App Store presentation must keep executable project source visible and
  editable and describe AdaEditor as a programming environment.

## Rejected alternatives

### Make AdaScript implement the Swift `App` protocol

Rejected because an AdaScript value cannot be the process entry point of the
precompiled iPad application, and starting a second application lifecycle is
invalid. Project sessions are the correct dynamic boundary.

### Keep a hidden generated Swift bootstrap

Rejected because it still requires a Swift compilation step and makes a
supposedly portable project depend on host toolchain behavior.

### Run hybrid projects while ignoring Swift files

Rejected because the observed game would differ from the project and could
silently omit initialization, systems, registrations, or gameplay behavior.

### Synchronize `.git` through iCloud Drive

Rejected because Git and File Provider both coordinate mutable file trees and
temporary lock files. A local worktree with explicit document transfer has a
clearer owner and failure model.
