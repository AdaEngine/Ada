#!/usr/bin/env bash
# Build and stage the complete Linux Standalone distribution, then open it.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/adaengine/studio-linux"
scratch="${ADA_STUDIO_SCRATCH_PATH:-$cache/build}"
configuration="${ADA_STUDIO_CONFIGURATION:-release}"
version="${ADA_STUDIO_VERSION:-development-$(date +%Y%m%d-%H%M%S)}"
: "${ADAENGINE_SWAN_PACKAGE_PATH:?Prepare Linux Swan first; see Documentation/Linux.md}"
: "${SWAN_LOCAL_DAWN:?Set SWAN_LOCAL_DAWN to the Linux Dawn artifact relative to Swan}"
: "${TINT_EXECUTABLE:?Set TINT_EXECUTABLE to the pinned Linux Tint executable}"
export ADAENGINE_GRAVITY_PACKAGE_PATH="${ADAENGINE_GRAVITY_PACKAGE_PATH:-$root/Sources/gravity-lang}"
export ADAENGINE_PACKAGE_PATH="$root"
export ADAENGINE_SKIP_SWIFTLINT=1
LORE_LINUX_SDK_PATH="$(python3 "$root/script/ensure_linux_lore.py")"
export LORE_LINUX_SDK_PATH
if [[ -z "${ADAEDITOR_LORE_PACKAGE_PATH:-}" ]]; then
    ADAEDITOR_LORE_PACKAGE_PATH="$(python3 "$root/script/ensure_linux_lore.py" --package)"
    export ADAEDITOR_LORE_PACKAGE_PATH
fi
export LD_LIBRARY_PATH="$LORE_LINUX_SDK_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
if [[ -z "${ADA_MCP_LOCAL_PATH:-}" ]]; then
    ADA_MCP_LOCAL_PATH="$(python3 "$root/script/ensure_windows_mcp.py")"
    export ADA_MCP_LOCAL_PATH
fi
swift build --package-path "$root/Editor" --scratch-path "$scratch" -c "$configuration" --jobs "${ADAENGINE_SWIFT_JOBS:-4}"
binary="$(swift build --package-path "$root/Editor" --scratch-path "$scratch" -c "$configuration" --show-bin-path)"
compiler="$ADAENGINE_GRAVITY_PACKAGE_PATH"
distribution="$(python3 "$root/script/package_studio_linux.py" \
    --binary-directory "$binary" --compiler "$compiler" --tint "$TINT_EXECUTABLE" \
    --swan "$ADAENGINE_SWAN_PACKAGE_PATH" --dawn "$SWAN_LOCAL_DAWN" \
    --output "$cache/distributions" --version "$version" | tail -n 1)"
exec "$distribution/ada-studio" "$@"
