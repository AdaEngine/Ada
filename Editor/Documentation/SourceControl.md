# Git and Lore in Ada Studio

The desktop project creation form offers **None**, **Git** and **Lore**. Lore is
selected by default on supported hosts; other hosts default to Git. None creates the project without initializing a repository. Lore
creates a local, offline repository and uses the system user name as its initial
commit identity. Configure an existing Lore remote and credentials with Lore's
own tools when working with a server.

The creation form and Lore panel link to the [official Lore documentation](https://epicgames.github.io/lore/),
including its overview, quickstart and server setup guides.

To opt into the server round-trip test, set `ADAEDITOR_LORE_TEST_SERVER` to a
test endpoint (for example `lore://127.0.0.1:41337`) and run
`swift test --package-path Editor --filter LoreServerIntegrationTests` with the
SDK environment below. The test creates a uniquely named `ada-studio-smoke-*`
repository, pushes a small generated text/binary fixture and clones it back.
It never reads or uploads an existing project. The remote test repository remains
available for inspection; ordinary test runs do not contact a server.

The Source Control panel also offers Git / Lore. The choice persists per project
in `.ada/workspace/source-control.json`. Without a saved choice, Studio detects
the nearest `.git` or `.lore` directory. Git wins when both are in that directory.
Switching providers does not convert repositories or history. The switch is
disabled during a repository command, and closes reviews from the previous
provider before loading the newly selected repository.

Both providers support status, stage/unstage, commits, branches, history and text
diffs. Pull maps to Lore Sync and Push uses Lore Push. Lore staging records which
paths to commit: edits made after staging are included in the commit. The panel
explains this behavior. Stash is available with Git. Binary changes have a binary
message rather than a text diff. Lore metadata is excluded from the project tree,
text search, file watcher refreshes and Android exports.

## Platforms and builds

Lore is available on Windows x64, Linux x86_64/ARM64 and macOS 15+ with Apple
silicon. The macOS build uses the original XCFramework; Windows and Linux use
the official C SDK through the native port of `lore-swift`. Other Studio hosts
retain Git.

The ordinary Windows build/launch scripts prepare the pinned SDK and Swift
package, then bundle `lore.dll` and its license notices. A Lore CLI installation
is not needed to use the local repository features in Studio.

Before a manual Windows SwiftPM build/test, prepare the dependencies required by
`AGENTS.md`, and additionally run from the engine root:

```powershell
$env:LORE_WINDOWS_SDK_PATH = python script/ensure_windows_lore.py
$env:ADAEDITOR_LORE_PACKAGE_PATH = python script/ensure_windows_lore.py --package
$env:Path = "$env:LORE_WINDOWS_SDK_PATH;$env:Path"
swift test --package-path Editor --filter 'LoreRepositoryTests|EditorSourceControlWorkflowTests|GitToolingTests|GitReviewTests|ProjectOpeningLayoutTests|EditorLocalizationTests'
```

See [Tools/Lore](../../Tools/Lore/README.md) for the dependency pin and port patch.

The Linux launcher prepares the SDK and Swift package automatically and sets
`LD_LIBRARY_PATH` for the build and staged executable. The Linux packager includes
`liblore.so` in `lib` and both license notices. For manual Linux builds/tests,
prepare the engine dependencies from `Documentation/Linux.md`, then:

```sh
export LORE_LINUX_SDK_PATH="$(python3 script/ensure_linux_lore.py)"
export ADAEDITOR_LORE_PACKAGE_PATH="$(python3 script/ensure_linux_lore.py --package)"
export LD_LIBRARY_PATH="$LORE_LINUX_SDK_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
swift test --package-path Editor --scratch-path "$ADAENGINE_LINUX_SCRATCH" \
  --filter 'LoreRepositoryTests|EditorSourceControlWorkflowTests'
```

The fork's Linux CI runs the existing local repository suites. Linux SDK staging
and ELF linking can also be checked from another host; these checks do not replace
running the Swift bindings and Studio UI on Linux.
