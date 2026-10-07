#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ADA_EDITOR_STANDALONE_SWIFTPM=1
export ADA_EDITOR_SCRATCH="${ADA_EDITOR_SCRATCH:-/private/tmp/adaeditor-a2ui-build}"
mkdir -p "$ADA_EDITOR_SCRATCH"
ADA_EDITOR_SCRATCH="$(cd "$ADA_EDITOR_SCRATCH" && pwd -P)"
export ADA_EDITOR_APP_NAME="Ada Studio A2UI"
export ADAENGINE_PACKAGE_PATH="${ADAENGINE_PACKAGE_PATH:-${ADA_EDITOR_SCRATCH}/package-roots/AdaEngine}"
exec "$REPO_ROOT/Editor/script/build_and_run.sh" "$@"
