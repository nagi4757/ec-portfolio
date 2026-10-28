#!/usr/bin/env bash
# Offline fixtures evaluated against the real HCL/ASL/SSM source.
set -euo pipefail
readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -I -B "$SCRIPT_DIRECTORY/cold-standby-plan-test.py" "$@"
