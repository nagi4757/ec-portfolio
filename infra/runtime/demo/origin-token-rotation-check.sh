#!/usr/bin/env bash

# Verifies the origin side of an X-Origin-Verify token rotation, on the host.
#
# The rotation keeps the origin accepting two tokens while CloudFront moves from
# the old one to the new one (configure-origin.sh with
# ORIGIN_VERIFY_RETAIN_INSTALLED_TOKEN=true), then drops the old one with a plain
# configure-origin.sh run. Every step is proved with requests rather than by
# reading configuration: HTTPS to the local Nginx with the origin hostname
# pinned to 127.0.0.1, the same way origin-smoke-check.sh does it.
#
#   capture   while the origin accepts two tokens, keep the one that is not the
#             SSM token in a root-only file on tmpfs for the later checks
#   both      the SSM token and the captured token are both accepted
#   new-only  the SSM token is accepted, the captured token is refused, and the
#             installed map holds the SSM token alone
#   forget    delete the captured token
#
# No token is printed. Reports carry HTTP status codes and 12-character SHA-256
# fingerprints only. Tokens reach curl through a root-only config file, never
# through its arguments. The captured token disappears on reboot.
#
# Usage (as root, from the runtime bundle directory):
#   sudo --preserve-env=ORIGIN_SERVER_NAME ./origin-token-rotation-check.sh <mode>

set -euo pipefail

readonly CHECK_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# The token pattern, the SSM read and the installed map parser are the ones
# configure-origin.sh uses, so the check cannot drift from what it verifies.
# shellcheck source=configure-origin.sh
source "$CHECK_DIRECTORY/configure-origin.sh"

readonly ROTATION_STATE_DIRECTORY="/run/ec-portfolio-demo-origin-rotation"
readonly CAPTURED_TOKEN_FILE="$ROTATION_STATE_DIRECTORY/previous-token"
readonly READINESS_PATH="/actuator/health/readiness"
readonly CURL_MAX_TIME_SECONDS="10"

request_directory=""
captured_origin_verify_token=""
export -n captured_origin_verify_token
failures=0

log() {
    printf '[origin-rotation-check] %s\n' "$*"
}

fail() {
    printf '[origin-rotation-check] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup_check() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$request_directory" && -d "$request_directory" ]]; then
        rm -rf -- "$request_directory" || true
    fi
    unset origin_verify_token retained_origin_verify_token captured_origin_verify_token
    exit "$exit_code"
}

fingerprint() {
    printf '%s' "$1" | sha256sum | cut -c1-12
}

# Prints the HTTP status of a readiness request that carries the given token, or
# no X-Origin-Verify header when the token is empty. 000 means no HTTP answer.
request_status() {
    local token="$1"
    local header_file=""
    local status
    local -a curl_arguments=(
        --disable
        --silent
        --output /dev/null
        --write-out '%{http_code}'
        --max-time "$CURL_MAX_TIME_SECONDS"
        --resolve "$ORIGIN_SERVER_NAME:443:127.0.0.1"
    )

    if [[ -n "$token" ]]; then
        header_file="$(mktemp "$request_directory/header.XXXXXX")"
        printf 'header = "X-Origin-Verify: %s"\n' "$token" >"$header_file"
        curl_arguments+=(--config "$header_file")
    fi
    status="$(curl "${curl_arguments[@]}" "https://$ORIGIN_SERVER_NAME$READINESS_PATH" || true)"
    [[ -z "$header_file" ]] || rm -f -- "$header_file"
    printf '%s' "${status:-000}"
}

expect_status() {
    local label="$1"
    local expected="$2"
    local token="$3"
    local actual

    actual="$(request_status "$token")"
    if [[ "$actual" == "$expected" ]]; then
        log "PASS $label: HTTP $actual"
    else
        log "FAIL $label: HTTP $actual, expected $expected"
        failures=$((failures + 1))
    fi
}

# Stores the installed token that is not the SSM token.
capture_previous_token() {
    local secret_config="$1"
    local state_directory="$2"

    select_retained_origin_verify_token "$secret_config"
    [[ -n "$retained_origin_verify_token" ]] ||
        fail "The origin accepts only the SSM token. Run configure-origin.sh with ORIGIN_VERIFY_RETAIN_INSTALLED_TOKEN=true first."

    (umask 077 && mkdir -p -- "$state_directory")
    chmod 700 "$state_directory"
    (umask 077 && printf '%s' "$retained_origin_verify_token" >"$state_directory/previous-token")
    log "Captured the previous token. ssm=$(fingerprint "$origin_verify_token") previous=$(fingerprint "$retained_origin_verify_token")"
}

read_captured_token() {
    local captured_file="$1"

    [[ -f "$captured_file" ]] || fail "No captured token. Run capture while the origin accepts two tokens."
    captured_origin_verify_token="$(<"$captured_file")"
    [[ "$captured_origin_verify_token" =~ $ORIGIN_VERIFY_TOKEN_PATTERN ]] || fail "The captured token is malformed."
    [[ "$captured_origin_verify_token" != "$origin_verify_token" ]] ||
        fail "The captured token is the SSM token; nothing is being rotated."
}

verify_rotation_state() {
    local mode="$1"
    local secret_config="$2"
    local captured_file="$3"
    local installed_tokens

    read_captured_token "$captured_file"
    log "ssm=$(fingerprint "$origin_verify_token") previous=$(fingerprint "$captured_origin_verify_token")"

    expect_status "no header" 403 ""
    expect_status "invalid token" 403 "invalid"
    expect_status "SSM token" 200 "$origin_verify_token"
    case "$mode" in
        both)
            expect_status "previous token" 200 "$captured_origin_verify_token"
            ;;
        new-only)
            expect_status "previous token" 403 "$captured_origin_verify_token"
            installed_tokens="$(read_installed_origin_verify_tokens "$secret_config")" ||
                fail "The installed origin verification map is missing or not in the managed format."
            if [[ "$installed_tokens" == "$origin_verify_token" ]]; then
                log "PASS installed map: the SSM token only"
            else
                log "FAIL installed map: expected the SSM token only"
                failures=$((failures + 1))
            fi
            ;;
    esac

    ((failures == 0)) || fail "$failures check(s) failed."
    log "All $mode checks passed."
}

forget_captured_token() {
    local state_directory="$1"

    rm -f -- "$state_directory/previous-token"
    rmdir -- "$state_directory" 2>/dev/null || true
    log "The captured token was deleted."
}

main() {
    (($# == 1)) || fail "Usage: origin-token-rotation-check.sh capture|both|new-only|forget"
    local mode="$1"

    ((EUID == 0)) || fail "Run as root: sudo --preserve-env=ORIGIN_SERVER_NAME $0 $mode"
    trap cleanup_check EXIT

    if [[ "$mode" == "forget" ]]; then
        forget_captured_token "$ROTATION_STATE_DIRECTORY"
        return 0
    fi

    require_environment ORIGIN_SERVER_NAME
    [[ "$ORIGIN_SERVER_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ &&
        "$ORIGIN_SERVER_NAME" == *.* && "$ORIGIN_SERVER_NAME" != *..* ]] ||
        fail "ORIGIN_SERVER_NAME must be a valid DNS hostname."
    [[ -z "${ORIGIN_VERIFY_TOKEN:-}" ]] ||
        fail "The origin verification token must not be supplied through the environment."
    for command_name in aws curl cut mktemp sha256sum timeout; do
        require_command "$command_name"
    done

    umask 077
    request_directory="$(mktemp -d /run/ec-portfolio-demo-origin-check.XXXXXX)"
    read_origin_verify_token

    case "$mode" in
        capture)
            capture_previous_token "$NGINX_SECRET_CONFIG" "$ROTATION_STATE_DIRECTORY"
            ;;
        both | new-only)
            verify_rotation_state "$mode" "$NGINX_SECRET_CONFIG" "$CAPTURED_TOKEN_FILE"
            ;;
        *)
            fail "Unknown mode: $mode"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
