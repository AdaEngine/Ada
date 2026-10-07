#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(uuidgen)"
PROOF="${ADA_EDITOR_A2UI_PROOF:-/private/tmp/adaeditor-a2ui-proof}/$RUN_ID"
mkdir -p "$PROOF"
export ADA_EDITOR_LOG_PATH="$PROOF/runtime.log"
ARGS=(--verify --agent-a2ui-smoke "--editor-project=$PROOF/Project" "--a2ui-proof-directory=$PROOF" --mcp-port=2527)
if [[ "${1:-}" == --fixture ]]; then
    # The fixture uses absolute executable paths and does not require interactive shell startup.
    export ADA_EDITOR_QA_SHELL=/bin/sh
    ARGS+=("--a2ui-fixture=$REPO_ROOT/Editor/Tests/AdaEditorTests/Fixtures/a2ui-acp-agent.py")
fi
"$REPO_ROOT/script/run_studio_a2ui.sh" "${ARGS[@]}" > "$PROOF/build.log" 2>&1
for attempt in {1..240}; do
    if [[ -f "$ADA_EDITOR_LOG_PATH" ]]; then
        if rg -q '^Studio A2UI PASS:' "$ADA_EDITOR_LOG_PATH"; then
            cat "$ADA_EDITOR_LOG_PATH"
            echo "Proof: $PROOF"
            exit 0
        fi
        if rg -q '^Studio A2UI FAIL:' "$ADA_EDITOR_LOG_PATH"; then
            tail -40 "$ADA_EDITOR_LOG_PATH"
            echo "Proof: $PROOF" >&2
            exit 1
        fi
    fi
    sleep 1
 done
tail -40 "$ADA_EDITOR_LOG_PATH" || true
echo "Studio A2UI verification timed out. Proof: $PROOF" >&2
exit 1
