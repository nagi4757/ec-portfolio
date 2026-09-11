#!/usr/bin/env bash

set -euo pipefail

readonly RUNTIME_DIRECTORY="/opt/ec-portfolio/runtime/demo"
readonly SYSTEMD_DIRECTORY="/etc/systemd/system"
readonly WRAPPER_FILE="deploy-api-from-ssm.sh"
readonly DEPLOY_FILE="deploy-api.sh"
readonly INSTALLER_FILE="install-api-convergence.sh"
readonly UNIT_FILE="ec-portfolio-api-converge.service"
readonly SYSTEMCTL_TIMEOUT_SECONDS="30s"
readonly TIMEOUT_KILL_AFTER_SECONDS="5s"

script_directory=""

log() {
    printf '[api-convergence-install] %s\n' "$*"
}

fail() {
    printf '[api-convergence-install] ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command is not available: $1"
}

run_systemctl() {
    timeout --signal=TERM --kill-after="$TIMEOUT_KILL_AFTER_SECONDS" \
        "$SYSTEMCTL_TIMEOUT_SECONDS" systemctl "$@"
}

validate_platform() {
    local command_name os_id os_version_id

    (( EUID == 0 )) || fail "Root privileges are required."
    [[ -r /etc/os-release ]] || fail "Cannot identify the operating system."

    os_id="$(. /etc/os-release; printf '%s' "${ID:-}")"
    os_version_id="$(. /etc/os-release; printf '%s' "${VERSION_ID:-}")"
    [[ "$os_id" == "amzn" && "$os_version_id" == 2023* ]] ||
        fail "Amazon Linux 2023 is required."

    for command_name in dirname install systemctl timeout; do
        require_command "$command_name"
    done
}

resolve_bundle_paths() {
    local bundled_file source_directory

    source_directory="$(dirname -- "${BASH_SOURCE[0]}")"
    if ! script_directory="$(cd -- "$source_directory" && pwd -P)"; then
        fail "Cannot resolve the runtime bundle directory."
    fi

    for bundled_file in "$WRAPPER_FILE" "$DEPLOY_FILE" "$INSTALLER_FILE" "$UNIT_FILE"; do
        [[ -f "$script_directory/$bundled_file" ]] ||
            fail "The bundled artifact is missing: $bundled_file"
    done
}

install_convergence_service() {
    install -d -o root -g root -m 0755 "$RUNTIME_DIRECTORY"
    install -o root -g root -m 0755 \
        "$script_directory/$WRAPPER_FILE" "$RUNTIME_DIRECTORY/$WRAPPER_FILE"
    install -o root -g root -m 0755 \
        "$script_directory/$DEPLOY_FILE" "$RUNTIME_DIRECTORY/$DEPLOY_FILE"
    install -o root -g root -m 0755 \
        "$script_directory/$INSTALLER_FILE" "$RUNTIME_DIRECTORY/$INSTALLER_FILE"
    install -o root -g root -m 0644 \
        "$script_directory/$UNIT_FILE" "$SYSTEMD_DIRECTORY/$UNIT_FILE"

    run_systemctl daemon-reload || fail "systemd daemon-reload failed or timed out."
    run_systemctl enable "$UNIT_FILE" || fail "The convergence service could not be enabled."
    run_systemctl is-enabled --quiet "$UNIT_FILE" ||
        fail "The convergence service is not enabled."
}

main() {
    (( $# == 0 )) || fail "This script does not accept arguments."

    validate_platform
    resolve_bundle_paths
    umask 077
    install_convergence_service

    log "Boot convergence service installed and enabled without starting it."
}

main "$@"
