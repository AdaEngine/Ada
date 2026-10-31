# Lore Swift native ports

Studio uses [AdaEngine/lore-swift](https://github.com/AdaEngine/lore-swift), forked
from [mattt/lore-swift](https://github.com/mattt/lore-swift). The base revision is
pinned in `toolchain.json` and `Editor/Package.swift`.

`native-support.patch` contains the combined Windows and Linux port, including
SDK fetchers and CI workflows. Both Studio hosts apply it through the shared
`script/ensure_lore.py` implementation until the port is published in the fork.
`windows-support.patch` retains the earlier Windows-only patch for reference.
Once published, replace the
local patched dependency with the fork's immutable commit and remove the temporary
source preparation step.

The port preserves the upstream macOS XCFramework. Windows links the official
MSVC import library; Linux x86_64 and ARM64 link the ordinary GNU `liblore.so`
release, without requiring the Neoverse-specific build. Both use the matching C
header in CLore's public include directory. The port also normalizes
C enum signedness between MSVC and Darwin, supplies Windows test environment
helpers, and uses Swift Crypto for tests that otherwise import CryptoKit.

`script/ensure_windows_lore.py` and `script/ensure_linux_lore.py` select the host
SDK, verify SHA-256 and stage only known regular files under `.build-tools`.
The Linux helper also verifies ELF64 architecture and accepts `--architecture`
for explicit cross-target staging. `LORE_WINDOWS_SDK_PATH` / `LORE_LINUX_SDK_PATH`
override the SDK destination. The `--package` option checks out the pinned Swift
source and applies the shared patch into a separate
directory. The script refuses to overwrite an existing unmarked checkout. When
updating the patch, bump `swift_patch_version` and the corresponding default path
in `Editor/Package.swift`; do not reset an existing prepared package.

The Windows release packager copies `lore.dll` through its PE dependency resolver.
Linux distributions copy `liblore.so` into `lib`, selected by the launcher's
`LD_LIBRARY_PATH`, and check the library's dependencies with `ldd`. Both include
`LICENSE.txt` and `THIRD-PARTY-NOTICES.txt`. Preserve those notices when
updating the SDK. The bindings and native Lore library are MIT licensed.
