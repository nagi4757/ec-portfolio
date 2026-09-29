#!/usr/bin/env bash

# Keeps every non-root process on an ECS EC2 Spot host away from the EC2
# instance metadata service (IMDS).
#
# The Phase 6C-4 API and Valkey tasks run in host network mode and share the
# host's network namespace. The launch template's IMDSv2 hop limit of 1 stops a
# container on a bridge network, whose packets cross one extra hop, but a
# host-network container crosses none, so the hop limit does nothing for it.
# Without this guard, one HTTP request from a compromised API process would
# return the Spot instance role's credentials, and with them the origin TLS
# archive write, the ACME TXT record, the origin verification token and the
# launch lifecycle action.
#
# The rule matches the socket owner, not the container:
#   - UID 0 keeps IMDS. The ECS agent, ecs-init, the SSM agent, cloud-init, the
#     bootstrap and the certbot renewal all run as root and need the instance
#     role.
#   - Every other UID is rejected. That is deliberately wider than the two
#     container UIDs this phase knows about, so a UID introduced later is
#     refused by default rather than allowed by omission.
#
# Residual risk, stated here because the rule cannot address it: a
# host-network container that runs as UID 0 is indistinguishable from the host
# and keeps IMDS. Container UIDs are therefore part of the contract, and the
# Phase 6C-4 task definition must not run any container as root.
#
# Scope is exactly 169.254.169.254/32 on locally generated traffic (the filter
# table's OUTPUT chain). No chain policy is changed and nothing else is matched.
# The launch template does not enable the instance's IPv6 metadata endpoint, so
# there is no IPv6 path to cover.
#
# The iptables frontend is used as installed. It is the one Docker and ecs-init
# use on the host, and every operation here (-N, -I, -D, -C, -S and the owner
# match) behaves the same on the legacy and the nf_tables backend, so no backend
# is assumed. The listing format is not parsed beyond the rule order and the
# target; whether a rule is the expected one is asked of the frontend with -C.
#
# Subcommands:
#   apply   install or repair the rules and check their shape. Idempotent: a
#           second run only reads. Needs no network, which is why it can run at
#           every boot from ec-portfolio-imds-guard.service, ordered before
#           ecs.service and required by it.
#   verify  prove the effect: root obtains an IMDSv2 token and every probe UID
#           is refused. Run once by the pre-bootstrap, before the ECS agent is
#           allowed to start. The token is discarded, never printed.

set -euo pipefail

readonly GUARD_CHAIN="EC_PORTFOLIO_IMDS"
readonly IMDS_DESTINATION="169.254.169.254/32"
readonly IMDS_TOKEN_URL="http://169.254.169.254/latest/api/token"

# The only UID the rule lets through.
readonly ALLOWED_UID="0"

# The UIDs the Phase 6C-4 containers run as, each proven from its image rather
# than assumed:
#   10001  API: apps/api/Dockerfile ends with `USER 10001:10001`.
#   999    Valkey: valkey/valkey:8.1.9-alpine runs `adduser -S -G valkey -u 999
#          valkey`, and its docker-entrypoint.sh drops to that user with
#          `setpriv --reuid=valkey` when it is started as root with
#          valkey-server.
# The rule does not list them; it refuses every non-root UID. verify probes
# these two because they are the ones that carry the risk.
readonly PROBE_UIDS="10001 999"

readonly IPTABLES_WAIT_SECONDS="5"
readonly PROBE_MAX_TIME_SECONDS="3"
readonly TOKEN_TTL_SECONDS="60"

# curl's exit status for "failed to connect", which is what a REJECTed
# connection produces. Anything else -- a timeout, a missing binary, a proxy --
# is not evidence of the block and is refused as such.
readonly CURL_COULDNT_CONNECT="7"

# Every rule names the destination itself, so the chain can never affect
# anything but IMDS, even if something other than the OUTPUT jump reached it.
ROOT_RETURN_RULE=(-d "$IMDS_DESTINATION" -m owner --uid-owner "$ALLOWED_UID" -j RETURN)
REJECT_RULE=(-d "$IMDS_DESTINATION" -j REJECT --reject-with icmp-port-unreachable)
JUMP_RULE=(-d "$IMDS_DESTINATION" -j "$GUARD_CHAIN")

log() {
    printf '[imds-guard] %s\n' "$*"
}

fail() {
    printf '[imds-guard] ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command is not available: $1"
}

ipt() {
    iptables -w "$IPTABLES_WAIT_SECONDS" "$@"
}

# A probe UID must be a canonical decimal (no sign, no leading zero), must not
# be root, and must be below (uid_t)-1, which the kernel reserves as "no UID".
is_valid_probe_uid() {
    local uid="$1"
    [[ "$uid" =~ ^[1-9][0-9]{0,9}$ ]] || return 1
    (( uid <= 4294967294 ))
}

validate_probe_uids() {
    local -a uids=()
    local uid
    read -r -a uids <<<"$1" || true
    (( ${#uids[@]} > 0 )) || fail "No probe UID is configured."
    for uid in "${uids[@]}"; do
        is_valid_probe_uid "$uid" || fail "Probe UID is not a valid non-root UID: '$uid'"
    done
}

validate_configuration() {
    [[ "$ALLOWED_UID" == "0" ]] ||
        fail "Only UID 0 may be allowed through the IMDS guard."
    [[ "$IMDS_DESTINATION" == "169.254.169.254/32" ]] ||
        fail "The IMDS guard must match the metadata address and nothing else."
    [[ "$GUARD_CHAIN" =~ ^[A-Z][A-Z0-9_]{0,27}$ ]] ||
        fail "The guard chain name is not a valid iptables chain name."
    validate_probe_uids "$PROBE_UIDS"
}

# The -A lines of one chain, in order.
appended_rules() {
    local chain="$1" listing
    listing="$(ipt -S "$chain")" || return 1
    printf '%s\n' "$listing" | grep -E -- "^-A $chain( |\$)" || true
}

count_lines() {
    if [[ -z "$1" ]]; then
        printf '0\n'
    else
        printf '%s\n' "$1" | grep -c .
    fi
}

chain_exists() {
    ipt -S "$GUARD_CHAIN" >/dev/null 2>&1
}

is_guard_jump() {
    [[ "$1" == *" -j $GUARD_CHAIN" ]]
}

# Exactly two rules, the root RETURN first and the REJECT second.
guard_chain_is_expected() {
    local rules first
    rules="$(appended_rules "$GUARD_CHAIN")" || return 1
    [[ "$(count_lines "$rules")" == "2" ]] || return 1
    first="$(printf '%s\n' "$rules" | head -n 1)"
    [[ "$first" == *"--uid-owner $ALLOWED_UID "* && "$first" == *" -j RETURN"* ]] || return 1
    ipt -C "$GUARD_CHAIN" "${ROOT_RETURN_RULE[@]}" >/dev/null 2>&1 || return 1
    ipt -C "$GUARD_CHAIN" "${REJECT_RULE[@]}" >/dev/null 2>&1
}

# The jump is the first rule in OUTPUT, so no earlier rule can accept IMDS
# traffic before the guard sees it, and it is the only jump to the chain.
guard_jump_is_first_and_only() {
    local rules first line count=0
    rules="$(appended_rules OUTPUT)" || return 1
    first="$(printf '%s\n' "$rules" | head -n 1)"
    is_guard_jump "$first" || return 1
    [[ "$first" == *"-d $IMDS_DESTINATION "* ]] || return 1
    while IFS= read -r line; do
        if is_guard_jump "$line"; then
            count=$((count + 1))
        fi
    done <<<"$rules"
    (( count == 1 )) || return 1
    ipt -C OUTPUT "${JUMP_RULE[@]}" >/dev/null 2>&1
}

rule_shape_is_expected() {
    chain_exists && guard_chain_is_expected && guard_jump_is_first_and_only
}

# Removes every rule of a chain after the first $2, from the bottom up so the
# remaining rule numbers do not move under the loop.
delete_rules_after() {
    local chain="$1" keep="$2" rules total
    rules="$(appended_rules "$chain")" || return 1
    total="$(count_lines "$rules")"
    while (( total > keep )); do
        ipt -D "$chain" "$total" || return 1
        total=$((total - 1))
    done
}

# Removes every jump to the chain except the first rule of OUTPUT. Rule numbers
# are collected first and deleted highest first, for the same reason.
delete_duplicate_jumps() {
    local rules line position=0 numbers="" number
    rules="$(appended_rules OUTPUT)" || return 1
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        position=$((position + 1))
        if (( position > 1 )) && is_guard_jump "$line"; then
            numbers="$position $numbers"
        fi
    done <<<"$rules"
    for number in $numbers; do
        ipt -D OUTPUT "$number" || return 1
    done
}

# Repairs are ordered so that a non-root UID is never let through while they
# run. The new rules go in at the top of the chain -- the REJECT first, then the
# root RETURN above it -- before anything older is removed, so the only
# transient state is one where root is refused as well. Likewise the jump is
# inserted at the top of OUTPUT before any duplicate is deleted.
apply_rules() {
    if ! chain_exists; then
        log "Creating the $GUARD_CHAIN chain."
        ipt -N "$GUARD_CHAIN" || fail "Unable to create the $GUARD_CHAIN chain."
    fi

    if ! guard_chain_is_expected; then
        log "Writing the $GUARD_CHAIN rules."
        ipt -I "$GUARD_CHAIN" 1 "${REJECT_RULE[@]}" ||
            fail "Unable to insert the IMDS REJECT rule."
        ipt -I "$GUARD_CHAIN" 1 "${ROOT_RETURN_RULE[@]}" ||
            fail "Unable to insert the root RETURN rule."
        delete_rules_after "$GUARD_CHAIN" 2 ||
            fail "Unable to remove stale rules from $GUARD_CHAIN."
    fi

    if ! guard_jump_is_first_and_only; then
        log "Placing the IMDS jump first in OUTPUT."
        ipt -I OUTPUT 1 "${JUMP_RULE[@]}" ||
            fail "Unable to insert the IMDS jump into OUTPUT."
        delete_duplicate_jumps ||
            fail "Unable to remove duplicate IMDS jumps from OUTPUT."
    fi

    rule_shape_is_expected ||
        fail "The IMDS guard rules are not in the expected shape after apply."
    log "The IMDS guard is active: only UID $ALLOWED_UID reaches $IMDS_DESTINATION."
}

# Prints nothing and returns curl's exit status. The token, when there is one,
# goes to /dev/null. --disable skips any .curlrc and --noproxy keeps a proxy
# variable from answering in IMDS's place.
probe_imds() {
    curl --disable --noproxy '*' --silent --output /dev/null \
        --max-time "$PROBE_MAX_TIME_SECONDS" -X PUT \
        -H "X-aws-ec2-metadata-token-ttl-seconds: $TOKEN_TTL_SECONDS" \
        "$@" "$IMDS_TOKEN_URL"
}

verify_effect() {
    local code uid status

    rule_shape_is_expected ||
        fail "The IMDS guard rules are not in place. Run apply first."

    code="$(probe_imds --write-out '%{http_code}')" ||
        fail "Root could not obtain an IMDSv2 token; the guard must not block UID $ALLOWED_UID."
    [[ "$code" == "200" ]] ||
        fail "Root received HTTP $code from IMDS instead of 200."
    log "UID $ALLOWED_UID obtains an IMDSv2 token."

    # The owner match reads only the UID; the group is set to the same number
    # simply so the probe carries no group of root's.
    for uid in $PROBE_UIDS; do
        status=0
        setpriv --reuid="$uid" --regid="$uid" --clear-groups -- \
            curl --disable --noproxy '*' --silent --output /dev/null \
            --max-time "$PROBE_MAX_TIME_SECONDS" -X PUT \
            -H "X-aws-ec2-metadata-token-ttl-seconds: $TOKEN_TTL_SECONDS" \
            "$IMDS_TOKEN_URL" || status=$?
        (( status == CURL_COULDNT_CONNECT )) ||
            fail "UID $uid was not refused by the IMDS guard (curl exit $status, expected $CURL_COULDNT_CONNECT)."
        log "UID $uid is refused at $IMDS_DESTINATION."
    done
}

main() {
    (( $# == 1 )) || fail "Usage: ec-portfolio-imds-guard apply|verify"
    (( EUID == 0 )) || fail "This script must run as root."
    validate_configuration
    require_command iptables
    require_command grep
    require_command head

    case "$1" in
        apply)
            apply_rules
            ;;
        verify)
            require_command curl
            require_command setpriv
            verify_effect
            ;;
        *)
            fail "Unknown subcommand: $1"
            ;;
    esac
}

# Sourcing exposes the functions to the test suite without touching iptables.
# The same guard is used by bootstrap-spot-host.sh and deploy-api.sh.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
