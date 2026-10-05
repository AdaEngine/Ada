#!/usr/bin/env bash
set -euo pipefail
android_repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ -f "$android_repo_root/.build-android/local-env.sh" ]]; then
    source "$android_repo_root/.build-android/local-env.sh"
fi
exec python3 "$android_repo_root/Tools/Android/android.py" run "$@"
