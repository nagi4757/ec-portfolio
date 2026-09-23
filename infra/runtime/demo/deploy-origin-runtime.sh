#!/usr/bin/env bash

# Installs the origin runtime scripts of one merged main commit on the Demo EC2
# host through SSM Run Command, without replacing anything already installed.
#
# deploy-runtime.sh only ships the API convergence artifacts, so the origin
# scripts had no reviewed way onto the running host. This script follows the
# same safety pattern and adds what an operator-run install needs:
#
#   - The source is the git objects of SOURCE_SHA, never the working tree, and
#     SOURCE_SHA must be origin/main at the time of the run.
#   - Artifacts travel inline as base64. The host verifies every SHA-256 before
#     it creates any file, so no URL, bucket or extra credential is involved.
#   - The destination is a new directory per release,
#     /opt/ec-portfolio/runtime/demo/origin/<SOURCE_SHA>/. Files are written to
#     a staging directory next to it, verified again, and moved into place with
#     one rename, so the release directory is either complete or absent.
#   - An existing release directory is never modified: it is verified, and any
#     difference fails the install.
#
# There is no "current" pointer. Operators run the scripts from the explicit
# release directory, so nothing is switched and a rollback is simply running an
# earlier release directory, which this script never touches.
#
# The artifacts carry no secret. configure-origin.sh and the checks read the
# origin verification token on the host, with the instance role.
#
# Usage (from the repository, with an identity allowed to SendCommand):
#   SOURCE_SHA=<origin/main SHA> ./deploy-origin-runtime.sh plan
#   SOURCE_SHA=<origin/main SHA> EC2_INSTANCE_ID=<id> ./deploy-origin-runtime.sh deploy

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly EXPECTED_REGION="ap-northeast-1"
readonly SSM_DOCUMENT="AWS-RunShellScript"
readonly REMOTE_ORIGIN_ROOT="/opt/ec-portfolio/runtime/demo/origin"
readonly SOURCE_PATH="infra/runtime/demo"
readonly SHA_PATTERN='^[0-9a-f]{40}$'
readonly INSTANCE_ID_PATTERN='^i-[0-9a-f]{8,17}$'
# configure-origin.sh runs the standalone smoke check from its own directory, and
# the rotation check sources configure-origin.sh from its own directory, so these
# three are the smallest set that works on its own.
readonly ARTIFACT_NAMES="configure-origin.sh origin-smoke-check.sh origin-token-rotation-check.sh"
readonly DEFAULT_POLL_ATTEMPTS=30
readonly DEFAULT_POLL_INTERVAL_SECONDS=5

repository_root=""
artifact_count=0
artifact_names=()
artifact_b64=()
artifact_sha256=()

log() {
    printf '[deploy-origin-runtime] %s\n' "$*"
}

fail() {
    printf '[deploy-origin-runtime] ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command is not available: $1"
}

sha256_of_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    else
        shasum -a 256 | awk '{print $1}'
    fi
}

resolve_repository_root() {
    repository_root="$(git -C "$SCRIPT_DIRECTORY" rev-parse --show-toplevel 2>/dev/null)" ||
        fail "Run this script from a clone of the repository."
}

# SOURCE_SHA must be exactly what main points to now: a release that is not the
# merged, reviewed main cannot be installed, and neither can a stale one.
verify_source_sha() {
    local main_sha

    [[ "${SOURCE_SHA:-}" =~ $SHA_PATTERN ]] || fail "SOURCE_SHA must be a full 40-character commit SHA."
    git -C "$repository_root" fetch --quiet origin main || fail "Unable to fetch origin/main."
    main_sha="$(git -C "$repository_root" rev-parse origin/main)"
    [[ "$SOURCE_SHA" == "$main_sha" ]] ||
        fail "SOURCE_SHA is not origin/main (origin/main is $main_sha)."
}

# Reads every artifact from the git objects of SOURCE_SHA.
collect_artifacts() {
    local name object

    artifact_count=0
    artifact_names=()
    artifact_b64=()
    artifact_sha256=()
    for name in $ARTIFACT_NAMES; do
        object="$SOURCE_SHA:$SOURCE_PATH/$name"
        git -C "$repository_root" cat-file -e "$object" 2>/dev/null ||
            fail "$name does not exist at $SOURCE_SHA."
        artifact_names[artifact_count]="$name"
        artifact_b64[artifact_count]="$(git -C "$repository_root" show "$object" | base64 | tr -d '\n')"
        artifact_sha256[artifact_count]="$(git -C "$repository_root" show "$object" | sha256_of_stdin)"
        artifact_count=$((artifact_count + 1))
    done
}

# Builds the AWS-RunShellScript command list. Nothing on the host is created or
# changed until every artifact has been verified, and nothing that already
# exists is ever replaced.
build_origin_install_commands() {
    local index name expected
    local -a commands=(
        "set -euo pipefail"
        "umask 077"
        "source_sha='$SOURCE_SHA'"
        "origin_root='$REMOTE_ORIGIN_ROOT'"
        "target=\"\$origin_root/\$source_sha\""
    )

    for ((index = 0; index < artifact_count; index++)); do
        commands+=("payload_$index='${artifact_b64[index]}'")
    done
    for ((index = 0; index < artifact_count; index++)); do
        name="${artifact_names[index]}"
        expected="${artifact_sha256[index]}"
        commands+=("[ \"\$(printf '%s' \"\$payload_$index\" | base64 -d | sha256sum | awk '{print \$1}')\" = '$expected' ] || { echo '$name checksum mismatch; nothing was installed' >&2; exit 1; }")
    done

    commands+=(
        "install -d -o root -g root -m 0755 \"\$origin_root\""
        "if [ -e \"\$target\" ] || [ -L \"\$target\" ]; then"
        "  { [ -d \"\$target\" ] && [ ! -L \"\$target\" ]; } || { echo \"\$target exists and is not a directory; refusing to touch it\" >&2; exit 1; }"
        "  [ \"\$(find \"\$target\" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')\" = '$artifact_count' ] || { echo \"\$target does not hold exactly the reviewed files; refusing to touch it\" >&2; exit 1; }"
    )
    for ((index = 0; index < artifact_count; index++)); do
        name="${artifact_names[index]}"
        expected="${artifact_sha256[index]}"
        commands+=("  [ -f \"\$target/$name\" ] && [ \"\$(sha256sum \"\$target/$name\" | awk '{print \$1}')\" = '$expected' ] || { echo 'installed $name differs from the reviewed release; refusing to overwrite' >&2; exit 1; }")
    done
    commands+=(
        "  echo \"Release \$source_sha is already installed and verified; nothing changed.\""
        "  exit 0"
        "fi"
        "staging=\"\$(mktemp -d \"\$origin_root/.staging.XXXXXX\")\""
        "trap 'rm -rf -- \"\$staging\"' EXIT"
    )
    for ((index = 0; index < artifact_count; index++)); do
        name="${artifact_names[index]}"
        expected="${artifact_sha256[index]}"
        commands+=(
            "printf '%s' \"\$payload_$index\" | base64 -d > \"\$staging/$name\""
            "[ \"\$(sha256sum \"\$staging/$name\" | awk '{print \$1}')\" = '$expected' ] || { echo 'written $name differs from the reviewed release' >&2; exit 1; }"
        )
    done
    commands+=(
        "chown root:root \"\$staging\" \"\$staging\"/*"
        "chmod 0700 \"\$staging\" \"\$staging\"/*"
        # One rename publishes the whole release. mv -T never replaces a
        # directory that has content, so a concurrent install fails instead of
        # being overwritten.
        "mv -T \"\$staging\" \"\$target\" || { echo \"could not publish \$target; refusing to replace an existing release\" >&2; exit 1; }"
        "trap - EXIT"
        "echo \"Installed release \$source_sha into \$target:\""
        "(cd \"\$target\" && sha256sum -- *)"
    )

    printf '%s\n' "${commands[@]}" | jq -R . | jq -s .
}

print_plan() {
    local index payload_bytes

    log "source: $SOURCE_SHA (origin/main)"
    log "target: $REMOTE_ORIGIN_ROOT/$SOURCE_SHA/"
    for ((index = 0; index < artifact_count; index++)); do
        log "  ${artifact_sha256[index]}  ${artifact_names[index]}"
    done
    payload_bytes="$(build_origin_install_commands | wc -c | tr -d ' ')"
    log "payload: $payload_bytes bytes of commands"
}

instance_ping_status() {
    AWS_PAGER="" aws ssm describe-instance-information \
        --region "$EXPECTED_REGION" \
        --filters "Key=InstanceIds,Values=$EC2_INSTANCE_ID" \
        --query 'InstanceInformationList[0].PingStatus' \
        --output text ||
        fail "Unable to query DescribeInstanceInformation for $EC2_INSTANCE_ID."
}

send_install_command() {
    local commands_json parameters_json

    commands_json="$(build_origin_install_commands)"
    parameters_json="$(jq -n --argjson commands "$commands_json" '{commands: $commands}')"

    AWS_PAGER="" aws ssm send-command \
        --region "$EXPECTED_REGION" \
        --document-name "$SSM_DOCUMENT" \
        --instance-ids "$EC2_INSTANCE_ID" \
        --comment "ec-portfolio origin runtime ${SOURCE_SHA:0:12}" \
        --parameters "$parameters_json" \
        --query 'Command.CommandId' \
        --output text ||
        fail "Unable to send the install command."
}

await_command() {
    local command_id="$1"
    local poll_attempts="${ORIGIN_DEPLOY_POLL_ATTEMPTS:-$DEFAULT_POLL_ATTEMPTS}"
    local poll_interval_seconds="${ORIGIN_DEPLOY_POLL_INTERVAL_SECONDS:-$DEFAULT_POLL_INTERVAL_SECONDS}"
    local attempt invocation status

    for ((attempt = 1; attempt <= poll_attempts; attempt++)); do
        invocation="$(AWS_PAGER="" aws ssm get-command-invocation \
            --region "$EXPECTED_REGION" \
            --command-id "$command_id" \
            --instance-id "$EC2_INSTANCE_ID" 2>&1)" || true
        status="$(printf '%s' "$invocation" | jq -r '.Status // empty' 2>/dev/null || true)"

        case "$status" in
            Success)
                printf '%s' "$invocation" | jq -r '.StandardOutputContent // empty'
                log "Install command succeeded."
                return 0
                ;;
            Failed | Cancelled | TimedOut | Cancelling)
                printf '%s' "$invocation" | jq -r '.StandardErrorContent // empty' >&2
                fail "Install command finished with status $status."
                ;;
            *)
                sleep "$poll_interval_seconds"
                ;;
        esac
    done

    fail "Timed out waiting for the install command to reach a terminal status."
}

deploy() {
    local ping_status command_id

    [[ "${EC2_INSTANCE_ID:-}" =~ $INSTANCE_ID_PATTERN ]] ||
        fail "EC2_INSTANCE_ID does not match the expected instance id format."
    print_plan

    # Unlike the CI deploy, an operator install has nothing to defer to: a host
    # that is not Online is a failure, and no command is sent.
    ping_status="$(instance_ping_status)"
    [[ "$ping_status" == "Online" ]] ||
        fail "EC2 instance $EC2_INSTANCE_ID is not Online (status: $ping_status); nothing was sent."

    command_id="$(send_install_command)"
    log "Install command sent: $command_id"
    await_command "$command_id"
}

main() {
    (($# == 1)) || fail "Usage: deploy-origin-runtime.sh plan|deploy"
    local mode="$1"
    local command_name

    for command_name in git base64 jq awk; do
        require_command "$command_name"
    done
    resolve_repository_root
    verify_source_sha
    collect_artifacts

    case "$mode" in
        plan)
            print_plan
            ;;
        deploy)
            require_command aws
            deploy
            ;;
        *)
            fail "Unknown mode: $mode"
            ;;
    esac
}

# Sourcing exposes the command builder without sending anything, which is how
# the test executes the generated payload against a local sandbox.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
