#!/usr/bin/env bash

set -euo pipefail

readonly NETWORK_NAME="ec-portfolio-demo"

log() {
    printf '[bootstrap] %s\n' "$*"
}

fail() {
    printf '[bootstrap] ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command is not available: $1"
}

if (( $# != 0 )); then
    fail "This script does not accept arguments."
fi

if (( EUID != 0 )); then
    require_command sudo
    log "Root privileges are required; re-running with sudo."
    exec sudo -- "$0" "$@"
fi

[[ -r /etc/os-release ]] || fail "Cannot identify the operating system."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "amzn" && "${VERSION_ID:-}" == 2023* ]] ||
    fail "Amazon Linux 2023 is required."

require_command dnf
require_command systemctl

log "Installing the Docker package."
dnf install -y docker

require_command docker
require_command aws
require_command curl

log "Enabling and starting the Docker daemon."
systemctl enable --now docker
docker info >/dev/null

if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    log "Docker network already exists: $NETWORK_NAME"
else
    log "Creating Docker network: $NETWORK_NAME"
    docker network create --driver bridge "$NETWORK_NAME" >/dev/null
fi

network_contract="$(docker network inspect --format '{{.Driver}}|{{.Scope}}|{{.Internal}}' "$NETWORK_NAME")"
[[ "$network_contract" == "bridge|local|false" ]] ||
    fail "Existing network does not match the required local bridge contract: $NETWORK_NAME"

log "Host bootstrap completed. No secrets, images, or application containers were handled."
