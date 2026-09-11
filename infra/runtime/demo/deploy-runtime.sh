#!/usr/bin/env bash

# Deploys the reviewed API runtime to the Demo EC2 host through SSM Run
# Command. This never starts the host: if it is not Online, the desired
# image SHA is simply left in Parameter Store for the Phase 5F-3 boot
# convergence path to pick up later. The wrapper, deploy script, convergence
# installer and systemd unit are sent inline. All four are checksummed on the
# host before any temporary file or installation is created, so no GitHub/raw
# URL access or extra network dependency is introduced.
#
# This job is desired-state driven, not commit driven. GITHUB_SHA only decides
# whether this job may run at all (a stale queued job is rejected); the release
# the host actually deploys is whatever /ec-portfolio/demo/deploy/
# desired-image-sha holds at the moment the host-side wrapper reads it. If a
# later main push has already advanced that parameter, this job converges the
# host onto the newer release rather than onto its own commit.

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

readonly EXPECTED_REGION="ap-northeast-1"
readonly SSM_DOCUMENT="AWS-RunShellScript"
readonly REMOTE_RUNTIME_DIR="/opt/ec-portfolio/runtime/demo"
readonly WRAPPER_FILE="deploy-api-from-ssm.sh"
readonly DEPLOY_FILE="deploy-api.sh"
readonly INSTALLER_FILE="install-api-convergence.sh"
readonly UNIT_FILE="ec-portfolio-api-converge.service"

readonly INSTANCE_ID_PATTERN='^i-[0-9a-f]{8,17}$'

# The poll budget has to outlast the host-side deployment, otherwise CI reports
# a timeout for a deployment that actually went on to succeed and the recorded
# state stops matching the host.
#
# deploy-api.sh has these explicitly configured waits. Each readiness attempt
# costs its per-probe HTTP timeout as well as its interval, and every deployment
# after the first also waits for the outgoing container to stop:
#
#   Valkey health        30 x 2s              =  60s
#   candidate readiness  36 x (3s + 5s)       = 288s
#   API stop grace                            =  30s
#   final readiness      36 x (3s + 5s)       = 288s
#                                             ------
#                                               666s
#
# That 666s is a conservative sum of the configured waits, not a measured
# wall-clock figure: it adds up every loop as if each ran to exhaustion, which
# cannot all happen in one successful run. It is also not an upper bound on the
# deployment as a whole, because several steps have no script-level timeout at
# all: both docker pulls, the ECR login, the Parameter Store, STS and ECR API
# calls, the SSM agent picking the command up, and the Docker daemon operations
# themselves.
#
# 90 attempts at 10s gives a 900s observation budget. The roughly 234s above the
# configured waits is operational headroom for that unbounded work, sized from
# how long those steps normally take rather than from any guarantee about them.
# It sits inside the 1200s OIDC credential duration the deploy job requests.
readonly DEFAULT_POLL_ATTEMPTS=90
readonly DEFAULT_POLL_INTERVAL_SECONDS=10

log() {
    printf '[deploy-runtime] %s\n' "$*"
}

fail() {
    printf '[deploy-runtime] ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command is not available: $1"
}

validate_instance_id() {
    [[ "${EC2_INSTANCE_ID:-}" =~ $INSTANCE_ID_PATTERN ]] ||
        fail "EC2_INSTANCE_ID does not match the expected instance id format."
}

instance_ping_status() {
    AWS_PAGER="" aws ssm describe-instance-information \
        --region "$EXPECTED_REGION" \
        --filters "Key=InstanceIds,Values=$EC2_INSTANCE_ID" \
        --query 'InstanceInformationList[0].PingStatus' \
        --output text ||
        fail "Unable to query DescribeInstanceInformation for $EC2_INSTANCE_ID."
}

# Builds the AWS-RunShellScript command list that verifies all four reviewed
# artifacts before creating any host-side file, runs the idempotent installer,
# and executes the installed wrapper only after installation succeeds. Artifact
# content never contains a secret; deploy-api.sh resolves the database password
# and JWT secret itself, on the host, with the EC2 instance role.
build_install_and_run_commands() {
    local wrapper_b64 deploy_b64 installer_b64 unit_b64
    local wrapper_sha256 deploy_sha256 installer_sha256 unit_sha256

    wrapper_b64="$(base64 <"$SCRIPT_DIRECTORY/$WRAPPER_FILE" | tr -d '\n')"
    deploy_b64="$(base64 <"$SCRIPT_DIRECTORY/$DEPLOY_FILE" | tr -d '\n')"
    installer_b64="$(base64 <"$SCRIPT_DIRECTORY/$INSTALLER_FILE" | tr -d '\n')"
    unit_b64="$(base64 <"$SCRIPT_DIRECTORY/$UNIT_FILE" | tr -d '\n')"
    wrapper_sha256="$(sha256sum "$SCRIPT_DIRECTORY/$WRAPPER_FILE" | awk '{print $1}')"
    deploy_sha256="$(sha256sum "$SCRIPT_DIRECTORY/$DEPLOY_FILE" | awk '{print $1}')"
    installer_sha256="$(sha256sum "$SCRIPT_DIRECTORY/$INSTALLER_FILE" | awk '{print $1}')"
    unit_sha256="$(sha256sum "$SCRIPT_DIRECTORY/$UNIT_FILE" | awk '{print $1}')"

    local -a commands=(
        "set -euo pipefail"
        "wrapper_b64='$wrapper_b64'"
        "deploy_b64='$deploy_b64'"
        "installer_b64='$installer_b64'"
        "unit_b64='$unit_b64'"
        "[ \"\$(printf '%s' \"\$wrapper_b64\" | base64 -d | sha256sum | awk '{print \$1}')\" = \"$wrapper_sha256\" ] || { echo '$WRAPPER_FILE checksum mismatch' >&2; exit 1; }"
        "[ \"\$(printf '%s' \"\$deploy_b64\" | base64 -d | sha256sum | awk '{print \$1}')\" = \"$deploy_sha256\" ] || { echo '$DEPLOY_FILE checksum mismatch' >&2; exit 1; }"
        "[ \"\$(printf '%s' \"\$installer_b64\" | base64 -d | sha256sum | awk '{print \$1}')\" = \"$installer_sha256\" ] || { echo '$INSTALLER_FILE checksum mismatch' >&2; exit 1; }"
        "[ \"\$(printf '%s' \"\$unit_b64\" | base64 -d | sha256sum | awk '{print \$1}')\" = \"$unit_sha256\" ] || { echo '$UNIT_FILE checksum mismatch' >&2; exit 1; }"
        "tmp_dir=\"\$(mktemp -d /tmp/ec-portfolio-deploy.XXXXXX)\""
        "trap 'rm -rf \"\$tmp_dir\"' EXIT"
        "printf '%s' \"\$wrapper_b64\" | base64 -d > \"\$tmp_dir/$WRAPPER_FILE\""
        "printf '%s' \"\$deploy_b64\" | base64 -d > \"\$tmp_dir/$DEPLOY_FILE\""
        "printf '%s' \"\$installer_b64\" | base64 -d > \"\$tmp_dir/$INSTALLER_FILE\""
        "printf '%s' \"\$unit_b64\" | base64 -d > \"\$tmp_dir/$UNIT_FILE\""
        "bash \"\$tmp_dir/$INSTALLER_FILE\""
        "$REMOTE_RUNTIME_DIR/$WRAPPER_FILE"
    )

    printf '%s\n' "${commands[@]}" | jq -R . | jq -s .
}

send_deploy_command() {
    local commands_json parameters_json

    commands_json="$(build_install_and_run_commands)"
    parameters_json="$(jq -n --argjson commands "$commands_json" '{commands: $commands}')"

    AWS_PAGER="" aws ssm send-command \
        --region "$EXPECTED_REGION" \
        --document-name "$SSM_DOCUMENT" \
        --instance-ids "$EC2_INSTANCE_ID" \
        --comment "ec-portfolio demo API deploy ${GITHUB_SHA:-manual}" \
        --parameters "$parameters_json" \
        --query 'Command.CommandId' \
        --output text ||
        fail "Unable to send the deployment command."
}

await_command() {
    local command_id="$1"
    local poll_attempts="${DEPLOY_POLL_ATTEMPTS:-$DEFAULT_POLL_ATTEMPTS}"
    local poll_interval_seconds="${DEPLOY_POLL_INTERVAL_SECONDS:-$DEFAULT_POLL_INTERVAL_SECONDS}"
    local attempt invocation status

    for ((attempt = 1; attempt <= poll_attempts; attempt++)); do
        invocation="$(AWS_PAGER="" aws ssm get-command-invocation \
            --region "$EXPECTED_REGION" \
            --command-id "$command_id" \
            --instance-id "$EC2_INSTANCE_ID" 2>&1)" || true
        status="$(printf '%s' "$invocation" | jq -r '.Status // empty' 2>/dev/null || true)"

        case "$status" in
        Success)
            log "Deployment command succeeded."
            printf '%s' "$invocation" | jq -r '.StandardOutputContent // empty'
            return 0
            ;;
        Failed | Cancelled | TimedOut | Cancelling)
            printf '%s' "$invocation" | jq -r '.StandardErrorContent // empty' >&2
            fail "Deployment command finished with status $status."
            ;;
        *)
            sleep "$poll_interval_seconds"
            ;;
        esac
    done

    fail "Timed out waiting for the deployment command to reach a terminal status."
}

deploy() {
    local ping_status command_id

    validate_instance_id
    ping_status="$(instance_ping_status)"

    if [[ "$ping_status" != "Online" ]]; then
        log "EC2 instance $EC2_INSTANCE_ID is not Online (status: $ping_status)."
        log "No install or SendCommand attempted; the desired image SHA is left for Phase 5F-3 boot convergence."
        return 0
    fi

    command_id="$(send_deploy_command)"
    log "Deployment command sent: $command_id"
    await_command "$command_id"
}

main() {
    local command_name="${1-}"

    (($# == 1)) || fail "Usage: deploy-runtime.sh deploy"

    for command_name_check in aws jq base64 sha256sum; do
        require_command "$command_name_check"
    done

    case "$command_name" in
    deploy) deploy ;;
    *) fail "Unknown command: $command_name" ;;
    esac
}

# Sourcing the script exposes the command builder without running a deployment,
# which is how deploy-runtime.test.sh executes the generated payload for real.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
