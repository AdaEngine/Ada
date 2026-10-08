# ADR-0001: Use annotation-driven Ada Script modules

- Status: Accepted
- Date: 2026-08-31
- Implementation: Partial (foundation shipped)

## Implementation status

Last verified: 2026-08-31.

Shipped:

- [x] Gravity parses declaration annotations and retains their normalized
  metadata in the compiled binary.
- [x] The Swift Gravity binding exposes annotations and can load a module
  without invoking `main()`.
- [x] Ada Script discovers `@system` classes and nested `@query` properties
  without executing a manifest.
- [x] Ada Script rejects `main()` and the legacy `AdaPlugin`, `AdaSystem`, and
  `AdaQuery` registration path has been removed.
- [x] The build generator, Editor template, completion, diagnostics, demo, and
  documentation use the annotation-driven entry model.

Remaining before this ADR is implemented:

- [x] Embed the complete target-relative source map and install one VM/plugin
  for the Swift target rather than one plugin per source file.
- [x] Resolve selected relative imports, extension omission, reachable shared
  declarations, canonical paths, duplicate paths, target-root escapes, and
  complete import cycles before entering Gravity.
- [x] Scope Editor completion to selected imports and diagnose unresolved or
  workspace-escaping paths.
- [ ] Implement namespace imports and enforce public/private selected-import
  visibility instead of exposing every declaration in a reachable file.
- [ ] Populate the `AdaEngine` and `AdaUI` virtual modules.
- [ ] Share one import parser/resolution model between runtime code generation
  and the Editor, including cycle diagnostics in the LSP.
- [ ] Retain complete target-relative source ranges and qualified declaration
  identities in annotation metadata and diagnostics.
- [ ] Diagnose unknown AdaEngine annotations and every unsupported annotation
  target in the semantic layer.
- [x] Generate one deterministic target-level registration entry point.

## Context

The current Ada Script integration embeds every `.ada` file independently and
expects its `main()` function to return an `AdaPlugin` manifest assembled from
`AdaSystem` and `AdaQuery` values. This repeats registration boilerplate in
every file, prevents a coherent project module graph, and makes imports and
cross-file symbols difficult to model.

Ada Script has no external users whose source compatibility must be preserved.
The new API can therefore replace the manifest API instead of maintaining two
ways to declare the same system.

Gravity already tokenizes `@` separately and has a compiler file-loading
callback, but it does not expose general declaration annotations or a complete
module/import model. The Swift build plugin already discovers `.ada` files and
can embed generated Swift source.

## Decision

### General Gravity annotations

Gravity will gain a general annotation facility. AdaEngine-specific annotation
names will not be hard-coded into the Gravity parser.

Annotations may target:

- a source module;
- a class or struct;
- a function;
- a stored property;
- a query declaration.

The supported forms are:

```ada
@name
@name(value)
@name(key: value, other: value)
```

Annotation arguments are compile-time metadata. They may contain symbols,
strings, booleans, integers, floating-point values, null, lists, and maps. They
must not execute arbitrary user code during discovery.

The Gravity AST and compiled module metadata retain:

- the annotation name;
- normalized arguments;
- the annotated declaration identity;
- the source file and source range.

Unknown annotations remain representable by Gravity. The Ada Script semantic
layer diagnoses unknown AdaEngine annotations and invalid targets.

### Ada Script module entry

An `.ada` source module is discovered from annotations. It does not define or
return a manual plugin manifest.

```ada
@system(scheduler: "update")
class MovementSystem {
    func update(context) {
    }
}
```

`main()` has no role in Ada Script. Declaring it in an `.ada` module is an Ada
Script compilation error. Standalone Gravity programs may continue to use
`main()` outside Ada Script mode.

The following legacy Ada Script surface is removed rather than deprecated:

- `AdaPlugin.create`;
- `AdaSystem.create`;
- `AdaSystem.createBatch`;
- `AdaQuery.read`;
- `AdaQuery.write`;
- `AdaQuery.readWrite`;
- entity and batch execution modes;
- manifest parsing through the result of `main()`.

### One script module plugin per Swift target

The build plugin generates one `GravityScriptModulePlugin` for a Swift target,
not one plugin for every source file. The generated source contains:

- the module name;
- a map from target-relative source paths to source text;
- generated backing types described by [ADR-0003](0003-ada-script-components-and-resources.md);
- generated registration code;
- one Ada Script plugin installation point.

This source map is also the module resolver input. Compilation and execution do
not require arbitrary runtime filesystem access and therefore behave the same
way on native platforms and WebAssembly.

### Imports

Ada Script supports explicit module imports:

```ada
import {
    Health,
    GameBalance
} from "./GameplayData.ada";

import * as Combat from "./Combat.ada";

import {
    Transform,
    DeltaTime
} from "AdaEngine";

import {
    VStack,
    Text,
    Button
} from "AdaUI";
```

Import resolution follows these rules:

- `./` and `../` are relative to the importing source file;
- the `.ada` extension may be omitted;
- absolute filesystem paths are rejected;
- `AdaEngine` and `AdaUI` are built-in virtual modules;
- canonical target-relative paths are module identities;
- a module is compiled and initialized at most once;
- import cycles produce a diagnostic containing the complete cycle;
- only public declarations are imported;
- private declarations remain module-local;
- duplicate exported symbol names require qualification or an alias.

Annotated systems, scriptable objects, components, and resources are discovery
roots. Helper declarations remain module-scoped and must be imported before use.

## Consequences

- Ordinary Ada Script code contains declarations rather than plugin assembly.
- Cross-file analysis, completion, definition lookup, and diagnostics share one
  module graph.
- The build plugin and Editor workspace resolver must use identical canonical
  path and import rules.
- Gravity needs an API that initializes a compiled module without invoking
  `main()` and exposes annotation metadata through the Swift binding.
- A target uses one coherent Gravity module environment, although VM execution
  remains serialized while the underlying Gravity runtime is non-reentrant.

## Rejected alternatives

### Keep the manifest API as a compatibility mode

Rejected because there are no external users and dual registration paths would
increase parser, runtime, documentation, and test complexity.

### Generate a hidden source-level `main()`

Rejected because annotations should compile to module metadata, not another
manifest function that has to execute user code for discovery.

### Use textual `#include` as the import system

Rejected because textual inclusion does not provide module identity, visibility,
cycle diagnostics, namespace isolation, or reliable LSP navigation.

### Compile every `.ada` file as an independent plugin

Rejected because shared declarations and imports require a target-level source
graph and stable module identities.
