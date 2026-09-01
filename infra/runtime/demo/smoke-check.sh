#!/usr/bin/env bash

set -euo pipefail

readonly API_CONTAINER="ec-portfolio-demo-api"
readonly VALKEY_CONTAINER="ec-portfolio-demo-valkey"
readonly READINESS_URL="http://127.0.0.1:8080/actuator/health/readiness"

log() {
    printf '[smoke] %s\n' "$*"
}

fail() {
    printf '[smoke] ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command is not available: $1"
}

container_is_running() {
    [[ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]
}

if (( $# != 0 )); then
    fail "This script does not accept arguments."
fi

require_command curl
require_command docker
require_command grep

docker info >/dev/null 2>&1 || fail "Docker daemon is not available."
container_is_running "$VALKEY_CONTAINER" || fail "Valkey container is not running."
container_is_running "$API_CONTAINER" || fail "API container is not running."

valkey_ports="$(docker port "$VALKEY_CONTAINER" 2>/dev/null || true)"
[[ -z "$valkey_ports" ]] || fail "Valkey must not publish any host port."

api_binding="$(docker port "$API_CONTAINER" 8080/tcp 2>/dev/null || true)"
[[ "$api_binding" == "127.0.0.1:8080" ]] ||
    fail "API must publish exactly 127.0.0.1:8080:8080."

readiness_response="$(curl --fail --silent --show-error --max-time 5 "$READINESS_URL")" ||
    fail "API readiness endpoint did not return HTTP 200."
printf '%s' "$readiness_response" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"UP"' ||
    fail "API readiness status is not UP."

log "Docker, containers, private Valkey, loopback API binding, and readiness are healthy."
