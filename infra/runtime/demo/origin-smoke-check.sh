#!/usr/bin/env bash

set -euo pipefail

readonly API_CONTAINER="ec-portfolio-demo-api"
readonly VALKEY_CONTAINER="ec-portfolio-demo-valkey"
readonly ORIGIN_VERIFY_PARAMETER="/ec-portfolio/demo/origin/verify-token"
readonly READINESS_PATH="/actuator/health/readiness"

runtime_directory=""
origin_verify_token=""
curl_secret_config=""

log() {
    printf '[origin-smoke] %s\n' "$*"
}

fail() {
    printf '[origin-smoke] ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command is not available: $1"
}

cleanup() {
    local exit_code=$?
    trap - EXIT

    if [[ -n "$runtime_directory" && "$runtime_directory" == /run/ec-portfolio-demo-origin-smoke.* ]]; then
        rm -rf -- "$runtime_directory"
    fi

    unset origin_verify_token
    exit "$exit_code"
}

trap cleanup EXIT

listener_exists() {
    local port="$1"
    ss -H -ltn "sport = :$port" | grep -q .
}

container_is_running() {
    [[ "$(docker inspect --format '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]
}

read_origin_verify_token() {
    local aws_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
    local -a region_arguments=()

    if [[ -n "$aws_region" ]]; then
        [[ "$aws_region" =~ ^[a-z0-9-]{5,32}$ ]] || fail "The configured AWS Region is invalid."
        region_arguments=(--region "$aws_region")
    fi

    origin_verify_token="$(
        AWS_PAGER="" aws ssm get-parameter \
            "${region_arguments[@]}" \
            --name "$ORIGIN_VERIFY_PARAMETER" \
            --with-decryption \
            --query 'Parameter.Value' \
            --output text
    )"

    [[ "$origin_verify_token" != "None" && ${#origin_verify_token} -ge 32 && ${#origin_verify_token} -le 128 &&
        "$origin_verify_token" =~ ^[A-Za-z0-9_-]+$ ]] ||
        fail "The origin verification parameter is missing or does not satisfy the token policy."
}

write_curl_secret_config() {
    umask 077
    runtime_directory="$(mktemp -d /run/ec-portfolio-demo-origin-smoke.XXXXXX)"
    curl_secret_config="$runtime_directory/curl-origin-secret.conf"
    printf 'header = "X-Origin-Verify: %s"\n' "$origin_verify_token" >"$curl_secret_config"
}

request_readiness() {
    local request_mode="$1"
    local response_file="$2"
    local -a authentication_arguments=()

    case "$request_mode" in
        none)
            ;;
        invalid)
            authentication_arguments=(--header 'X-Origin-Verify: invalid')
            ;;
        valid)
            authentication_arguments=(--config "$curl_secret_config")
            ;;
        *)
            fail "Unknown readiness request mode."
            ;;
    esac

    curl --disable \
        "${authentication_arguments[@]}" \
        --silent \
        --show-error \
        --output "$response_file" \
        --write-out '%{http_code}' \
        --max-time 10 \
        --proto '=https' \
        --tlsv1.2 \
        --resolve "$ORIGIN_SERVER_NAME:443:127.0.0.1" \
        "https://$ORIGIN_SERVER_NAME$READINESS_PATH"
}

main() {
    local api_binding
    local command_name
    local http_status
    local valkey_ports

    if (( EUID != 0 )); then
        require_command sudo
        log "Root privileges are required; re-running with sudo."
        exec sudo --preserve-env=ORIGIN_SERVER_NAME,AWS_REGION,AWS_DEFAULT_REGION -- "$0" "$@"
    fi

    (( $# == 0 )) || fail "This script does not accept arguments."
    [[ -n "${ORIGIN_SERVER_NAME:-}" ]] || fail "Required environment variable is missing: ORIGIN_SERVER_NAME"
    case "$ORIGIN_SERVER_NAME" in
        *$'\n'* | *$'\r'*) fail "ORIGIN_SERVER_NAME must not contain line breaks." ;;
    esac
    [[ "$ORIGIN_SERVER_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ &&
        "$ORIGIN_SERVER_NAME" == *.* && "$ORIGIN_SERVER_NAME" != *..* ]] ||
        fail "ORIGIN_SERVER_NAME must be a valid DNS hostname."

    for command_name in aws curl docker grep mktemp rm ss systemctl; do
        require_command "$command_name"
    done

    systemctl is-active --quiet nginx || fail "Nginx is not active."
    listener_exists 443 || fail "No TCP 443 listener was found."
    if listener_exists 80; then
        fail "A TCP 80 listener violates the Demo origin contract."
    fi

    docker info >/dev/null 2>&1 || fail "Docker daemon is not available."
    container_is_running "$API_CONTAINER" || fail "API container is not running."
    container_is_running "$VALKEY_CONTAINER" || fail "Valkey container is not running."

    api_binding="$(docker port "$API_CONTAINER" 8080/tcp 2>/dev/null || true)"
    [[ "$api_binding" == "127.0.0.1:8080" ]] ||
        fail "API must publish exactly 127.0.0.1:8080:8080."

    valkey_ports="$(docker port "$VALKEY_CONTAINER" 2>/dev/null || true)"
    [[ -z "$valkey_ports" ]] || fail "Valkey must not publish any host port."

    log "Reading the origin verification SecureString with the EC2 instance role."
    read_origin_verify_token
    write_curl_secret_config

    http_status="$(request_readiness none "$runtime_directory/no-header.response")" ||
        fail "HTTPS certificate or hostname verification failed for the no-header request."
    [[ "$http_status" == "403" ]] || fail "A request without origin verification must return HTTP 403."

    http_status="$(request_readiness invalid "$runtime_directory/invalid-header.response")" ||
        fail "HTTPS certificate or hostname verification failed for the invalid-header request."
    [[ "$http_status" == "403" ]] || fail "A request with invalid origin verification must return HTTP 403."

    http_status="$(request_readiness valid "$runtime_directory/valid-header.response")" ||
        fail "HTTPS certificate or hostname verification failed for the valid-header request."
    [[ "$http_status" == "200" ]] || fail "Verified origin readiness must return HTTP 200."
    grep -Eq '"status"[[:space:]]*:[[:space:]]*"UP"' "$runtime_directory/valid-header.response" ||
        fail "Verified origin readiness status is not UP."

    log "Nginx HTTPS, certificate verification, origin verification, loopback API, private Valkey, and readiness are healthy."
}

main "$@"
