#!/usr/bin/env bash
# Replace SwiftPM's build-directory library lookup in the packaged executable.
set -euo pipefail

binary="${1:?Expected a staged executable}"
build_rpath="${2:?Expected the build products directory}/PackageFrameworks"
bundle_rpath='@executable_path/../Frameworks'

rpaths="$(/usr/bin/otool -l "$binary" | /usr/bin/awk '
    $1 == "cmd" { is_rpath = ($2 == "LC_RPATH") }
    is_rpath && $1 == "path" {
        sub(/^[[:space:]]*path[[:space:]]+/, "")
        sub(/[[:space:]]+\(offset [0-9]+\)$/, "")
        print
        is_rpath = 0
    }
')"

if /usr/bin/grep -Fqx "$build_rpath" <<< "$rpaths"; then
    if /usr/bin/grep -Fqx "$bundle_rpath" <<< "$rpaths"; then
        /usr/bin/install_name_tool -delete_rpath "$build_rpath" "$binary"
    else
        /usr/bin/install_name_tool -rpath "$build_rpath" "$bundle_rpath" "$binary"
    fi
fi
