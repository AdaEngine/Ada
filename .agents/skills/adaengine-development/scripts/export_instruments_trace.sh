#!/bin/bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: export_instruments_trace.sh --trace PATH.trace [--output DIR] [--force]

Exports useful Instruments schemas from a temporary copy of PATH.trace.
When --output is omitted, a new directory under ${TMPDIR:-/tmp} is created.
EOF
}

trace_path=""
output_dir=""
force=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --trace)
            trace_path="${2:-}"
            shift 2
            ;;
        --output)
            output_dir="${2:-}"
            shift 2
            ;;
        --force)
            force=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "$trace_path" || ! -d "$trace_path" || "$trace_path" != *.trace ]]; then
    echo "error: --trace must name an existing .trace directory" >&2
    exit 2
fi

if ! command -v xcrun >/dev/null 2>&1; then
    echo "error: xcrun is required" >&2
    exit 127
fi

if [[ -z "$output_dir" ]]; then
    output_dir="$(mktemp -d "${TMPDIR:-/tmp}/adaengine-trace-export.XXXXXX")"
else
    mkdir -p "$output_dir"
    if [[ -n "$(find "$output_dir" -mindepth 1 -maxdepth 1 -print -quit)" && "$force" -ne 1 ]]; then
        echo "error: output directory is not empty; pass --force to replace generated files" >&2
        exit 2
    fi
fi

generated_files=(
    toc.xml
    time-profile.xml
    potential-hangs.xml
    ca-present.xml
    metal-application.xml
    run-issues.tsv
)

if [[ "$force" -eq 1 ]]; then
    for file_name in "${generated_files[@]}"; do
        rm -f "$output_dir/$file_name"
    done
fi

working_root="$(mktemp -d "${TMPDIR:-/tmp}/adaengine-trace-working.XXXXXX")"
working_trace="$working_root/input.trace"
cleanup() {
    rm -rf "$working_root"
}
trap cleanup EXIT

cp -R "$trace_path" "$working_trace"

xcrun xctrace export \
    --input "$working_trace" \
    --toc \
    --output "$output_dir/toc.xml"

export_schema() {
    local schema="$1"
    local destination="$2"
    local required="$3"
    local xpath="/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$schema\"]"

    if xcrun xctrace export --input "$working_trace" --xpath "$xpath" --output "$destination"; then
        if [[ -s "$destination" ]]; then
            return 0
        fi
    fi

    rm -f "$destination"
    if [[ "$required" -eq 1 ]]; then
        echo "error: failed to export required schema $schema" >&2
        exit 1
    fi
    echo "warning: schema $schema was unavailable" >&2
}

export_schema "time-profile" "$output_dir/time-profile.xml" 1
export_schema "potential-hangs" "$output_dir/potential-hangs.xml" 0
export_schema "ca-client-present-request" "$output_dir/ca-present.xml" 0
export_schema "metal-application-intervals" "$output_dir/metal-application.xml" 0

issue_store="$working_trace/Trace1.run/RunIssues.storedata"
if [[ -f "$issue_store" ]] && command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 -header -tabs "$issue_store" \
        'SELECT ZCOUNT AS count, ZRELATIVETIMESTAMP AS timestamp_ns, ZMESSAGE AS message FROM ZISSUE ORDER BY ZRELATIVETIMESTAMP;' \
        > "$output_dir/run-issues.tsv"
fi

echo "$output_dir"
