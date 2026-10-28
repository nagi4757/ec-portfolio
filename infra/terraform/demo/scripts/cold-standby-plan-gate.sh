#!/usr/bin/env bash
# Offline saved-plan gate. No AWS or Terraform plan/apply is executed.
set -euo pipefail
readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 -I -B "$SCRIPT_DIRECTORY/cold-standby-plan-gate.py" "$@"
