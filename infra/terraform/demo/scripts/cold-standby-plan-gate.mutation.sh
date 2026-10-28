#!/usr/bin/env bash
# AST guard mutations; each must be killed by the unchanged fixture suite.
set -euo pipefail
readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -I -B "$SCRIPT_DIRECTORY/cold-standby-plan-test.py" --mutation
