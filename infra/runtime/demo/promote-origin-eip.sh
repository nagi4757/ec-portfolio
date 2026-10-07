#!/usr/bin/env bash

# Phase 6C-5c-2: moves the origin Elastic IP to this Spot host, once, after the
# host has been accepted InService.
#
# bootstrap-spot-host.sh never associates the Elastic IP. Its job ends at "this
# host is healthy", reported as CONTINUE. Taking production traffic is this
# separate step: ec-portfolio-spot-eip-promotion.service runs it, queued by the
# post phase only after Auto Scaling has accepted that CONTINUE, and only when
# the launch template opted the host in by passing EIP_ALLOCATION_ID.
#
# The order is the contract. Every step must pass before the next one runs:
#   1. the inputs, and both markers the post phase leaves: serving-ready, and
#      continue-accepted, which exists only once CONTINUE was accepted;
#   2. this instance's ID, read back from IMDSv2, equals INSTANCE_ID;
#   3. the ECS origin smoke check again: time has passed since the post phase
#      proved the host, and the address must only move to a host that serves;
#   4. the Auto Scaling group still wants this capacity: desired capacity of at
#      least one, and this instance InService in it. A group at zero is being
#      closed down for the night, and promoting into it would take the address
#      back from the host it was just returned to;
#   5. the current holder: when it is already this instance, nothing is called;
#   6. associate-address --dry-run. Only DryRunOperation goes on. An
#      UnauthorizedOperation is final: the role does not allow this move, and
#      no real call is made;
#   7. associate-address, with reassociation, so the address moves from its
#      current holder without ec2:DisassociateAddress;
#   8. the holder read back must be this instance.
#
# Failure is fail-safe and never fatal to the host. The lifecycle action is
# already complete, so there is nothing to report, and an Elastic IP API error
# (throttling, a permission, a race) says nothing about this host's health:
# turning it into an ABANDON would kill a healthy host and start a replacement
# loop. So this script never completes a lifecycle action, never terminates or
# stops anything, never takes the ECS agent down and never disassociates. The
# host stays InService as capacity, traffic stays with the current holder, and
# the outcome is left in /run for the operator: spot-eip-promoted, or
# spot-eip-promotion-failed holding one reason word.
#
# Transient errors are retried a bounded number of times. Authorization
# failures, a group that no longer wants this host and a dry run that does not
# answer DryRunOperation are not retried.

set -euo pipefail

readonly ORIGIN_SERVER_NAME="origin-demo.yoonec.dev"
readonly EXPECTED_AWS_REGION="ap-northeast-1"

# Test seam, refused when executed rather than sourced, for the reason
# bootstrap-spot-host.sh gives: one environment variable must not be able to
# move where a root process reads its markers from.
if [[ "${BASH_SOURCE[0]}" == "$0" && -n "${SPOT_PROMOTION_PREFIX:-}" ]]; then
    printf '[spot-eip-promotion] ERROR: %s\n' \
        "SPOT_PROMOTION_PREFIX is a test seam and cannot be used when this script is executed." >&2
    exit 1
fi
readonly PROMOTION_PREFIX="${SPOT_PROMOTION_PREFIX:-}"

# Written by bootstrap-spot-host.sh. Both live under /run, so a reboot clears
# them: a host that came back up has not re-proven itself.
readonly MARKER_DIRECTORY="${PROMOTION_PREFIX}/run/ec-portfolio-demo"
readonly SERVING_READY_MARKER="$MARKER_DIRECTORY/spot-serving-ready"
readonly CONTINUE_ACCEPTED_MARKER="$MARKER_DIRECTORY/spot-continue-accepted"
readonly PROMOTED_MARKER="$MARKER_DIRECTORY/spot-eip-promoted"
readonly PROMOTION_FAILED_MARKER="$MARKER_DIRECTORY/spot-eip-promotion-failed"

readonly IMDS_BASE_URL="http://169.254.169.254/latest"
readonly IMDS_TOKEN_TTL_SECONDS=60

# The same identity, endpoint and seam variables bootstrap-spot-host.sh clears
# before an AWS child runs. The instance role is the only identity this host is
# meant to have, and an endpoint or trust store override would send the
# association, or the smoke check's parameter read, somewhere else.
readonly CLEARED_ENV=(
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
    AWS_PROFILE AWS_DEFAULT_PROFILE AWS_CREDENTIAL_FILE
    AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE
    AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN
    AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_CREDENTIALS_RELATIVE_URI
    AWS_EC2_METADATA_DISABLED AWS_EC2_METADATA_SERVICE_ENDPOINT
    AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE
    AWS_ENDPOINT_URL AWS_ENDPOINT_URL_EC2 AWS_ENDPOINT_URL_AUTO_SCALING AWS_ENDPOINT_URL_SSM
    AWS_CA_BUNDLE REQUESTS_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR BOTO_CONFIG
    ORIGIN_SMOKE_MODE SPOT_PROMOTION_PREFIX SPOT_BOOTSTRAP_PREFIX
)

readonly AWS_TIMEOUT_SECONDS="60s"
readonly SMOKE_TIMEOUT_SECONDS="120s"
readonly TIMEOUT_KILL_AFTER_SECONDS="5s"
readonly PROMOTION_ATTEMPTS="${SPOT_PROMOTION_ATTEMPTS:-3}"
readonly PROMOTION_INTERVAL_SECONDS="${SPOT_PROMOTION_INTERVAL_SECONDS:-10}"

script_directory=""
failure_reason=""
aws_error=""

log() {
    printf '[spot-eip-promotion] %s\n' "$*"
}

fail() {
    printf '[spot-eip-promotion] ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command is not available: $1"
}

# The instance role as the only identity, the Region stated rather than
# discovered, every seam removed. Callers put timeout in the command, as
# bootstrap-spot-host.sh does: env can only execute programs, not functions.
run_clean_child() {
    local -a clear=()
    local name
    for name in "${CLEARED_ENV[@]}"; do
        clear+=(-u "$name")
    done
    env "${clear[@]}" \
        AWS_REGION="$EXPECTED_AWS_REGION" \
        AWS_DEFAULT_REGION="$EXPECTED_AWS_REGION" \
        AWS_PAGER="" \
        "$@"
}

# One AWS call. Prints the response on stdout. On failure sets aws_error to a
# fixed word taken from the error code; the CLI's own message, which carries
# the account and an encoded authorization message, is never echoed.
aws_call() {
    local error_file status=0
    aws_error=""
    error_file="$(mktemp)" || fail "Unable to stage an AWS call."
    run_clean_child timeout --signal=TERM --kill-after="$TIMEOUT_KILL_AFTER_SECONDS" "$AWS_TIMEOUT_SECONDS" \
        aws --region "$EXPECTED_AWS_REGION" "$@" 2>"$error_file" || status=$?
    if (( status != 0 )); then
        case "$(cat "$error_file")" in
            *"(DryRunOperation)"*) aws_error="DryRunOperation" ;;
            *"(UnauthorizedOperation)"*) aws_error="UnauthorizedOperation" ;;
            *"(AccessDenied)"* | *"(AccessDeniedException)"*) aws_error="AccessDenied" ;;
            *"(InvalidAllocationID.NotFound)"*) aws_error="InvalidAllocationID.NotFound" ;;
            *"(InvalidInstanceID"*) aws_error="InvalidInstanceID" ;;
            *) aws_error="Other" ;;
        esac
    fi
    rm -f "$error_file"
    return "$status"
}

record_outcome() {
    local marker="$1" content="$2"
    install -d -o root -g root -m 0755 "$MARKER_DIRECTORY" || return 1
    rm -f "$PROMOTED_MARKER" "$PROMOTION_FAILED_MARKER"
    printf '%s\n' "$content" >"$marker"
}

validate_inputs() {
    (( $# == 0 )) || fail "Inputs are passed through the environment, not as arguments."

    [[ "${EIP_ALLOCATION_ID:-}" =~ ^eipalloc-[0-9a-f]{8,17}$ ]] ||
        fail "EIP_ALLOCATION_ID is missing or is not an Elastic IP allocation ID."
    [[ "${INSTANCE_ID:-}" =~ ^i-[0-9a-f]{8,17}$ ]] ||
        fail "INSTANCE_ID is missing or is not an EC2 instance ID."
    [[ "${AUTOSCALING_GROUP_NAME:-}" =~ ^[A-Za-z0-9_.-]{1,255}$ ]] ||
        fail "AUTOSCALING_GROUP_NAME is missing or is not a valid Auto Scaling group name."

    local supplied_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
    if [[ -n "$supplied_region" && "$supplied_region" != "$EXPECTED_AWS_REGION" ]]; then
        fail "This promotion only runs in $EXPECTED_AWS_REGION."
    fi
}

# The unit's ConditionPathExists already keeps it from starting without both
# markers. Checked again here so that the script, run any other way, holds the
# same rule: no AWS call before the host is known to be InService.
require_accepted_host() {
    [[ -e "$SERVING_READY_MARKER" ]] ||
        fail "No serving-ready marker: this host has not proven itself since boot."
    [[ -e "$CONTINUE_ACCEPTED_MARKER" ]] ||
        fail "No continue-accepted marker: Auto Scaling has not accepted this host's CONTINUE."
}

resolve_script_directory() {
    script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" ||
        fail "Cannot resolve the runtime bundle directory."
    [[ -x "$script_directory/origin-smoke-check-ecs.sh" ]] ||
        fail "The runtime bundle has no executable origin-smoke-check-ecs.sh."
}

# INSTANCE_ID comes from the post phase's environment file. Reading it back
# from IMDSv2 makes sure the address goes to the instance this script runs on,
# not to whatever ID that file holds.
verify_instance_identity() {
    local token observed
    token="$(curl --disable --silent --fail --max-time 5 -X PUT "$IMDS_BASE_URL/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: $IMDS_TOKEN_TTL_SECONDS")" ||
        fail "Unable to obtain an IMDSv2 token."
    observed="$(curl --disable --silent --fail --max-time 5 \
        -H "X-aws-ec2-metadata-token: $token" "$IMDS_BASE_URL/meta-data/instance-id")" ||
        fail "Unable to read the instance ID from IMDS."
    [[ "$observed" == "$INSTANCE_ID" ]] ||
        fail "IMDS reports a different instance ID than INSTANCE_ID; refusing to move the address."
}

# Returns 0 when the origin serves, 1 otherwise.
smoke_passes() {
    log "Running the ECS origin smoke check before moving the address."
    run_clean_child ORIGIN_SERVER_NAME="$ORIGIN_SERVER_NAME" \
        timeout --signal=TERM --kill-after="$TIMEOUT_KILL_AFTER_SECONDS" "$SMOKE_TIMEOUT_SECONDS" \
        "$script_directory/origin-smoke-check-ecs.sh"
}

# Returns 0 when the group wants this host, 1 when it does not (final), 2 when
# the read failed (retryable).
group_wants_this_host() {
    local answer desired in_service
    answer="$(aws_call autoscaling describe-auto-scaling-groups \
        --auto-scaling-group-names "$AUTOSCALING_GROUP_NAME" \
        --query "AutoScalingGroups[?AutoScalingGroupName=='$AUTOSCALING_GROUP_NAME'].[DesiredCapacity, length(Instances[?InstanceId=='$INSTANCE_ID' && LifecycleState=='InService'])]" \
        --output text)" || return 2
    read -r desired in_service <<<"$answer" || true
    [[ "${desired:-}" =~ ^[0-9]+$ && "${in_service:-}" =~ ^[0-9]+$ ]] || return 2
    if (( desired < 1 )); then
        log "The Auto Scaling group's desired capacity is $desired; the address is not moved."
        return 1
    fi
    if (( in_service != 1 )); then
        log "This instance is not InService in $AUTOSCALING_GROUP_NAME; the address is not moved."
        return 1
    fi
    return 0
}

# Prints the instance holding the address, or "None". Returns non-zero when the
# read failed or the answer is not one of those two shapes.
current_holder() {
    local holder
    holder="$(aws_call ec2 describe-addresses --allocation-ids "$EIP_ALLOCATION_ID" \
        --query 'Addresses[0].InstanceId' --output text)" || return 1
    [[ "$holder" == "None" || "$holder" =~ ^i-[0-9a-f]{8,17}$ ]] || return 1
    printf '%s\n' "$holder"
}

associate() {
    aws_call ec2 associate-address "$@" \
        --allocation-id "$EIP_ALLOCATION_ID" \
        --instance-id "$INSTANCE_ID" \
        --allow-reassociation >/dev/null
}

# One pass of steps 3 to 8. Returns 0 promoted, 1 retryable, 2 final. Sets
# failure_reason to one word.
promote_once() {
    local holder status

    if ! smoke_passes; then
        failure_reason="origin-smoke-failed"
        return 1
    fi

    status=0
    group_wants_this_host || status=$?
    case "$status" in
        0) ;;
        1) failure_reason="group-does-not-want-this-host"; return 2 ;;
        *) failure_reason="group-read-failed"; return 1 ;;
    esac

    if ! holder="$(current_holder)"; then
        failure_reason="holder-read-failed"
        return 1
    fi
    if [[ "$holder" == "$INSTANCE_ID" ]]; then
        log "This instance already holds the origin Elastic IP."
        return 0
    fi
    log "The origin Elastic IP is held by ${holder}; asking EC2 whether this host may take it."

    if associate --dry-run; then
        failure_reason="dry-run-did-not-answer-dry-run-operation"
        return 2
    fi
    case "$aws_error" in
        DryRunOperation) ;;
        UnauthorizedOperation | AccessDenied)
            failure_reason="dry-run-unauthorized"
            return 2 ;;
        *)
            failure_reason="dry-run-failed"
            return 1 ;;
    esac

    log "The dry run allows the move. Associating the origin Elastic IP with this instance."
    if ! associate; then
        case "$aws_error" in
            UnauthorizedOperation | AccessDenied) failure_reason="associate-unauthorized"; return 2 ;;
            *) failure_reason="associate-failed"; return 1 ;;
        esac
    fi

    if ! holder="$(current_holder)"; then
        failure_reason="verify-read-failed"
        return 1
    fi
    if [[ "$holder" != "$INSTANCE_ID" ]]; then
        failure_reason="holder-is-not-this-instance"
        return 1
    fi
    return 0
}

run_promotion() {
    local attempt status

    if [[ -e "$PROMOTED_MARKER" ]]; then
        log "This host has already promoted itself since boot; nothing to do."
        return 0
    fi

    for ((attempt = 1; attempt <= PROMOTION_ATTEMPTS; attempt++)); do
        status=0
        promote_once || status=$?
        if (( status == 0 )); then
            record_outcome "$PROMOTED_MARKER" "$INSTANCE_ID" ||
                log "The promoted marker could not be written; the association stands."
            log "Promoted: this instance holds the origin Elastic IP."
            return 0
        fi
        log "Attempt $attempt of $PROMOTION_ATTEMPTS did not promote: $failure_reason."
        (( status == 2 )) && break
        (( attempt < PROMOTION_ATTEMPTS )) && sleep "$PROMOTION_INTERVAL_SECONDS"
    done

    record_outcome "$PROMOTION_FAILED_MARKER" "$failure_reason" ||
        log "The failure marker could not be written."
    printf '[spot-eip-promotion] ERROR: %s\n' \
        "Not promoted ($failure_reason). The host stays InService; the address stays with its current holder." >&2
    return 1
}

main() {
    (( EUID == 0 )) || fail "This script must run as root."
    local command_name
    for command_name in aws curl install mktemp timeout; do
        require_command "$command_name"
    done
    validate_inputs "$@"
    require_accepted_host
    resolve_script_directory
    verify_instance_identity
    run_promotion
}

# Sourcing exposes the steps to the test suite without running a promotion.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
