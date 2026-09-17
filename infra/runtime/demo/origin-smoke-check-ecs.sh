#!/usr/bin/env bash

# End-to-end origin validation for an ECS host, where the API and Valkey run as
# ECS tasks in host network mode.
#
# This is a sibling of origin-smoke-check.sh, not a replacement for it. That
# script validates the standalone Docker host and is still the only check that
# runs there; it asserts container names and `docker port` bindings, neither of
# which exists under host networking. Rather than teach one script two runtimes
# and risk the On-Demand origin on every change, the ECS contract is asserted
# here and the standalone file is left alone.
#
# The origin security contract is identical and is asserted the same way: HTTPS
# only, certificate and hostname verified, and the CloudFront verification
# header required. What differs is how "the API is private" is established --
# by the listener addresses on the host rather than by Docker port bindings.
#
# Certificate material and the verification token never reach stdout or stderr.

set -euo pipefail

readonly ORIGIN_VERIFY_PARAMETER="/ec-portfolio/demo/origin/verify-token"
readonly READINESS_PATH="/actuator/health/readiness"
readonly API_PORT=8080
readonly VALKEY_PORT=6379
readonly AWS_TIMEOUT_SECONDS="30s"
readonly TIMEOUT_KILL_AFTER_SECONDS="5s"

runtime_directory=""
origin_verify_token=""
export -n origin_verify_token
curl_secret_config=""

log() {
    printf '[origin-smoke-ecs] %s\n' "$*"
}

fail() {
    printf '[origin-smoke-ecs] ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command is not available: $1"
}

run_with_timeout() {
    local duration="$1"
    shift
    timeout --signal=TERM --kill-after="$TIMEOUT_KILL_AFTER_SECONDS" "$duration" "$@"
}

cleanup() {
    local exit_code=$?
    trap - EXIT

    if [[ -n "$runtime_directory" && "$runtime_directory" == /run/ec-portfolio-demo-origin-smoke-ecs.* ]]; then
        rm -rf -- "$runtime_directory" || true
    fi

    unset origin_verify_token
    exit "$exit_code"
}

trap cleanup EXIT

# Listening sockets are read per address family and matched from a here-string.
# Piping ss into `grep -q` would let grep exit on its first match, ss die of
# SIGPIPE, and pipefail report 141 -- which reads as "no match" and would turn
# an exposed port into a passing check.
#
# The families are queried separately rather than parsed out of one listing.
# ss renders an IPv6 wildcard as "*", "[::]" or ":::" depending on version and
# flags, so a check that searched the combined output for a literal "[::]:8080"
# would miss the same exposure rendered another way. Asking ss for IPv4 only and
# IPv6 only removes the rendering from the decision: what matters is whether a
# family has a listener at all, and for IPv4, at which address.
listening_ipv4() {
    local port="$1"
    ss -H -ltn4 "sport = :$port" 2>/dev/null || true
}

listening_ipv6() {
    local port="$1"
    ss -H -ltn6 "sport = :$port" 2>/dev/null || true
}

listener_on_any_port() {
    local port="$1" sockets
    sockets="$(ss -H -ltn 2>/dev/null || true)"
    grep -Eq ":$port " <<<"$sockets"
}

# The local address is the fourth whitespace-separated field of ss -H output:
# State Recv-Q Send-Q Local:Port Peer:Port.
local_addresses() {
    awk '{ n = split($4, parts, ":"); addr = ""; for (i = 1; i < n; i++) addr = addr (i > 1 ? ":" : "") parts[i]; print addr }'
}

# A task in host network mode must be reachable by Nginx on loopback and by
# nothing else. On the standalone host this was enforced by `docker port`
# returning exactly 127.0.0.1:8080; here it is enforced directly.
#
# The contract per port is: exactly one IPv4 listener, bound to 127.0.0.1, and
# no IPv6 listener at all. Anything else -- a wildcard, a routable address, a
# second binding, an IPv6 socket -- fails.
verify_private_loopback_port() {
    local port="$1" label="$2"
    local ipv4_sockets ipv6_sockets address_count addresses

    ipv4_sockets="$(listening_ipv4 "$port")"
    [[ -n "$ipv4_sockets" ]] ||
        fail "No IPv4 listener was found on port $port; the $label task is not serving on loopback."

    addresses="$(local_addresses <<<"$ipv4_sockets" | sort -u)"
    address_count="$(grep -c . <<<"$addresses" || true)"
    (( address_count == 1 )) ||
        fail "The $label task must have exactly one IPv4 listener on port $port (found $address_count addresses)."
    [[ "$addresses" == "127.0.0.1" ]] ||
        fail "The $label task must listen on 127.0.0.1:$port only, not on $addresses."

    ipv6_sockets="$(listening_ipv6 "$port")"
    [[ -z "$ipv6_sockets" ]] ||
        fail "The $label task must not have an IPv6 listener on port $port."
}

read_origin_verify_token() {
    local aws_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
    local -a aws_arguments=(
        ssm get-parameter
        --name "$ORIGIN_VERIFY_PARAMETER"
        --with-decryption
        --query 'Parameter.Value'
        --output text
        --cli-connect-timeout 10
        --cli-read-timeout 20
    )

    if [[ -n "$aws_region" ]]; then
        [[ "$aws_region" =~ ^[a-z0-9-]{5,32}$ ]] || fail "The configured AWS Region is invalid."
        aws_arguments+=(--region "$aws_region")
    fi

    # Defence in depth. The bootstrap already strips these before invoking
    # anything that talks to AWS, but this script is executable on its own, and
    # the identity it must use is the instance role -- not whatever credential
    # happened to be in the environment of whoever ran it.
    origin_verify_token="$(
        AWS_PAGER="" run_with_timeout "$AWS_TIMEOUT_SECONDS" \
            env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
                -u AWS_SECURITY_TOKEN -u AWS_PROFILE -u AWS_DEFAULT_PROFILE \
                -u AWS_CREDENTIAL_FILE -u AWS_SHARED_CREDENTIALS_FILE -u AWS_CONFIG_FILE \
            aws "${aws_arguments[@]}"
    )"

    [[ "$origin_verify_token" != "None" && ${#origin_verify_token} -ge 32 && ${#origin_verify_token} -le 128 &&
        "$origin_verify_token" =~ ^[A-Za-z0-9_-]+$ ]] ||
        fail "The origin verification parameter is missing or does not satisfy the token policy."
}

# The token is written to a root-only file under /run and handed to curl through
# --config, so it never appears in a command line, in the environment of a child
# process, or in any log.
write_curl_secret_config() {
    umask 077
    runtime_directory="$(mktemp -d /run/ec-portfolio-demo-origin-smoke-ecs.XXXXXX)"
    curl_secret_config="$runtime_directory/curl-origin-secret.conf"
    printf 'header = "X-Origin-Verify: %s"\n' "$origin_verify_token" >"$curl_secret_config"
}

request_readiness() {
    local request_mode="$1"
    local response_file="$2"
    local -a curl_arguments=(--disable)

    case "$request_mode" in
        none)
            ;;
        invalid)
            curl_arguments+=(--header 'X-Origin-Verify: invalid')
            ;;
        valid)
            curl_arguments+=(--config "$curl_secret_config")
            ;;
        *)
            fail "Unknown readiness request mode."
            ;;
    esac

    curl "${curl_arguments[@]}" \
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

validate_inputs() {
    (( $# == 0 )) || fail "This script does not accept arguments."
    [[ -z "${ORIGIN_VERIFY_TOKEN:-}" ]] ||
        fail "The origin verification token must not be supplied through the environment."
    [[ -n "${ORIGIN_SERVER_NAME:-}" ]] || fail "Required environment variable is missing: ORIGIN_SERVER_NAME"
    case "$ORIGIN_SERVER_NAME" in
        *$'\n'* | *$'\r'*) fail "ORIGIN_SERVER_NAME must not contain line breaks." ;;
    esac
    [[ "$ORIGIN_SERVER_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ &&
        "$ORIGIN_SERVER_NAME" == *.* && "$ORIGIN_SERVER_NAME" != *..* ]] ||
        fail "ORIGIN_SERVER_NAME must be a valid DNS hostname."
}

validate_host_network_contract() {
    verify_private_loopback_port "$API_PORT" "API"
    verify_private_loopback_port "$VALKEY_PORT" "Valkey"
}

validate_origin_listeners() {
    systemctl is-active --quiet nginx || fail "Nginx is not active."
    listener_on_any_port 443 || fail "No TCP 443 listener was found."
    if listener_on_any_port 80; then
        fail "A TCP 80 listener violates the Demo origin contract."
    fi
}

# Everything the check actually does, separated from the privilege escalation
# in main() so the suite can drive it without being root. Production behaviour
# is unchanged: main() still refuses to run unprivileged.
run_smoke_checks() {
    local command_name
    local http_status

    for command_name in awk aws curl grep mktemp rm sort ss systemctl timeout; do
        require_command "$command_name"
    done

    validate_origin_listeners
    validate_host_network_contract

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

    log "Nginx HTTPS, certificate verification, origin verification, loopback API and Valkey, and readiness are healthy."
}

main() {
    if (( EUID != 0 )); then
        require_command sudo
        log "Root privileges are required; re-running with sudo."
        exec sudo --preserve-env=ORIGIN_SERVER_NAME,AWS_REGION,AWS_DEFAULT_REGION -- "$0" "$@"
    fi

    validate_inputs "$@"
    run_smoke_checks
}

# Sourcing exposes the contract functions to the test suite without running a
# check. The same guard is used by deploy-api.sh and renew-origin-cert.sh.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
