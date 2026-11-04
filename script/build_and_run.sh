#!/usr/bin/env bash
set -euo pipefail
: "${ADAEXAMPLES_PATH:?Set ADAEXAMPLES_PATH to an AdaExamples checkout}"
exec "$ADAEXAMPLES_PATH/Examples/Technical/A2UIForm/script/build_and_run.sh" "$@"
