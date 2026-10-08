# AdaScript Libraries

Share reusable AdaScript functions, systems, and scriptable objects through a GitHub repository.
AdaEditor installs the library and its transitive dependencies into the project. Run, Play Mode,
Preview, and `AdaScriptBuildPlugin` load the same installed sources without network access.

## Create a library

Place `ada-library.json` in the repository root:

```json
{
  "schemaVersion": 1,
  "id": "example.gameplay",
  "version": "1.0.0",
  "api": 1,
  "sources": ["Sources/Health.ada"],
  "dependencies": []
}
```

IDs use lowercase letters, digits, dots, and hyphens. Versions are exact `major.minor.patch`
values; API and schema versions currently equal `1`. List every `.ada` source explicitly,
including helpers imported by other files. Files must be regular UTF-8 files inside the repository.
A library can contain up to 256 sources, 1 MB per file and 8 MB total.

For example, `Sources/Health.ada` can contain:

```swift
func remainingHealth(current, damage) {
    if (damage >= current) { return 0; }
    return current - damage;
}
```

Publish the repository and optionally tag its commit `v1.0.0`. The repository name and library ID
can differ. The manifest's version describes the release; the resolved commit pins its exact content.

## Install and use

Open **Settings → Project → AdaScript Libraries**, enter `owner/repository` or its
`https://github.com/owner/repository` URL, enter a tag or commit, and select **Install / Update**.
Rebuild or restart Play to activate the installed code.

Import helpers from any game source without depending on its directory depth:

```swift
import { remainingHealth } from "@example.gameplay/Sources/Health";
```

Imports inside a library can use relative paths such as `./Shared/Math`, or the same `@id/path`
form for another library. Extensions are optional in imports. Library paths are exposed as
`Libraries/<id>/<source-path>` in diagnostics.

Library `@system` and `@scriptable` declarations participate in the game's normal
discovery and registration. Systems run automatically with the game's plugin. Enable the native
engine features they need in Runtime Settings. Libraries share the game's module: use distinct
class names, function names, and annotation IDs to avoid collisions. Imports do not create namespaces.
Library authors should not declare `main()`.

Pure AdaScript projects can register supported runtime-defined component layouts. SwiftPM games
generate native backing types through `AdaScriptBuildPlugin`. Installing a library does not compile
arbitrary Swift or install native binaries. See <doc:AdaScriptAnnotations> for schema rules.

## Dependencies and reproducibility

Declare transitive dependencies using exact, lowercase 40-character GitHub commit SHAs:

```json
"dependencies": [
  {
    "id": "example.math",
    "source": {
      "provider": "github",
      "location": "owner/math-library",
      "revision": "0123456789abcdef0123456789abcdef01234567"
    }
  }
]
```

The SHA above illustrates the format; replace it with a commit from the dependency repository.
Use lowercase `owner/repository` locations in dependencies. Version ranges are not supported.
Cycles, missing libraries, identity mismatches, and conflicting commits fail the complete operation.
Installation downloads code without executing it. It activates a complete graph through one atomic lock write.

Commit `.ada/libraries.lock.json` and `.ada/libraries/` to share a fully offline project.
Alternatively commit the lock and use **Restore Locked Libraries** on another machine. Restoration
fetches the pinned commits, even if a tag has moved. Reinstall a root library to explicitly update it.
Builds never resolve tags or download packages. Missing files produce an actionable restore error.

**Remove** removes a direct dependency. Dependencies still needed by another root stay active.
Unreferenced installation directories remain cached; they are not loaded by the lock.

For SwiftPM games, apply `AdaScriptBuildPlugin` to the game target and install libraries in that
package's root. The generator embeds the locked sources alongside the target's `.ada` files, so the
built executable does not need the installation directories. Each target using the plugin consumes
the package's library set; avoid registering that set again from another target in the same game.

## Providers

The initial provider supports public GitHub repositories through the GitHub REST API, including
on hosts without a Git executable. Private repositories and authentication are not implemented.
GitHub API rate limits are surfaced as installation errors.

The editor's `AdaScriptLibraryProvider` protocol accepts a provider/location/revision reference and
returns a pinned manifest plus source files. An Assets Store adapter can implement this same contract
without changing source imports, runtime loading, or the lock format. The store service, catalog,
authentication, and purchasing flows are future work.
