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
#
# Commands:
#   deploy           install the four artifacts and run the wrapper (converge
#                    the API).
#   install-runtime  the gate deploy-api runs before it records a desired image
#                    whose host runtime differs from the one the host last
#                    verified. Boot convergence runs whatever wrapper is
#                    installed and cannot install artifacts, so recording first
#                    would let the host start the new image on the old runtime
#                    at its next boot. The host must be Online and take the
#                    install now; otherwise this fails and the desired image SHA
#                    is never recorded.
#   release          what CI runs on a main push, after any recording.
#                    build-and-push-api decides the scope (publish-api-image.sh
#                    release-scope) and passes it in RELEASE_API_CONVERGE and
#                    RELEASE_RUNTIME_PENDING (true or false):
#                      API converge          -> deploy, as above. An offline
#                                               host is left to boot
#                                               convergence: a desired image
#                                               that needs a newer runtime was
#                                               only recorded after
#                                               install-runtime gave it one.
#                      runtime pending only  -> install the artifacts if the
#                                               host's copies differ, and run
#                                               nothing. An offline host keeps
#                                               the install pending.
#                      neither               -> nothing: no AWS call at all.
#
# A runtime install never runs late: its command carries an SSM delivery
# timeout, so a host that drops offline right after the Online check cannot
# pick it up unobserved at its next boot.
#
# Every install, the deploy command's included, holds the wrapper's deployment
# lock and refuses a release older than the one that last installed the host
# runtime. Anything that still reaches the host late, such as a deploy command
# the SSM agent picks up after a newer release, can therefore never put back an
# older runtime. GITHUB_RUN_NUMBER and GITHUB_SHA identify that release, and only
# the CI workflow on main may send one (GITHUB_WORKFLOW_REF).

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

readonly EXPECTED_REGION="ap-northeast-1"
readonly SSM_DOCUMENT="AWS-RunShellScript"
readonly REMOTE_RUNTIME_DIR="/opt/ec-portfolio/runtime/demo"
readonly WRAPPER_FILE="deploy-api-from-ssm.sh"
readonly DEPLOY_FILE="deploy-api.sh"
readonly INSTALLER_FILE="install-api-convergence.sh"
readonly UNIT_FILE="ec-portfolio-api-converge.service"
readonly REMOTE_SYSTEMD_DIR="/etc/systemd/system"
# The lock the installed wrapper (deploy-api-from-ssm.sh) takes for a deployment.
# Every install holds it too, so no install runs beside a deployment or another
# install, and nothing can change the host copies between an install and its
# check of them.
readonly REMOTE_DEPLOY_LOCK_FILE="/var/lock/ec-portfolio-demo-deploy.lock"
# The newest release that has taken the host runtime, "<run number> <commit>".
# It is written under the lock, after the release order check and before
# anything is installed, so an install that is interrupted or fails afterwards
# still leaves no room for an older release to follow it.
readonly REMOTE_RELEASE_RECORD="$REMOTE_RUNTIME_DIR/.runtime-release"
# Releases are ordered by GITHUB_RUN_NUMBER, which GitHub documents as starting at
# 1 and growing with each new run of one workflow, unchanged by a re-run, which
# also keeps GITHUB_SHA. GITHUB_RUN_ID is only documented as unique, and numbers
# of two workflows are not comparable, so only the CI workflow on main, the one
# workflow that sends installs, may build a payload.
readonly RELEASE_ORDER_PATTERN='^[1-9][0-9]{0,17}$'
readonly RELEASE_SHA_PATTERN='^[0-9a-f]{40}$'
readonly RELEASE_WORKFLOW_REF_PATTERN='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/\.github/workflows/ci\.yml@refs/heads/main$'

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

# A runtime install only decodes four files, copies them and reloads systemd
# (whose calls the installer bounds at 30s each), so it gets a much shorter
# budget than a deployment. SSM drops the command if the host has not started it
# within the delivery timeout, which is the minimum SendCommand accepts; the
# poll budget outlasts it, so a command that never starts is seen as TimedOut
# rather than given up on while it could still run. In deploy-api the install
# and a deployment share one credential, which deploy-runtime.test.sh checks.
readonly RUNTIME_INSTALL_DELIVERY_TIMEOUT_SECONDS=30
readonly RUNTIME_INSTALL_POLL_ATTEMPTS=12
readonly RUNTIME_INSTALL_POLL_INTERVAL_SECONDS=10

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

# Checked before any AWS call: a payload is never built without the release order
# the host compares against.
validate_release_identity() {
    [[ "${GITHUB_WORKFLOW_REF-}" =~ $RELEASE_WORKFLOW_REF_PATTERN ]] ||
        fail "GITHUB_WORKFLOW_REF must be the CI workflow on main (.github/workflows/ci.yml@refs/heads/main): only its run numbers order runtime installs on the host."
    [[ "${GITHUB_RUN_NUMBER-}" =~ $RELEASE_ORDER_PATTERN ]] ||
        fail "GITHUB_RUN_NUMBER must be the run number of this workflow run: it orders runtime installs on the host."
    [[ "${GITHUB_SHA-}" =~ $RELEASE_SHA_PATTERN ]] ||
        fail "GITHUB_SHA must be the full lowercase commit SHA of this release."
}

instance_ping_status() {
    AWS_PAGER="" aws ssm describe-instance-information \
        --region "$EXPECTED_REGION" \
        --filters "Key=InstanceIds,Values=$EC2_INSTANCE_ID" \
        --query 'InstanceInformationList[0].PingStatus' \
        --output text ||
        fail "Unable to query DescribeInstanceInformation for $EC2_INSTANCE_ID."
}

# The host runtime artifacts this script installs, one file name per line.
# publish-api-image.sh release-scope reads this list to decide whether a release
# changes the host runtime.
runtime_artifact_files() {
    printf '%s\n' "$WRAPPER_FILE" "$DEPLOY_FILE" "$INSTALLER_FILE" "$UNIT_FILE"
}

# Prints, one per line, the commands both remote command lists start with. The
# four reviewed artifacts travel inline and each is checked against its SHA256
# before any host file is read or created; only then are they decoded into a
# temporary directory that is removed on exit. Artifact content never contains a
# secret; deploy-api.sh resolves the database password and JWT secret itself, on
# the host, with the EC2 instance role.
verified_artifact_commands() {
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

    printf '%s\n' \
        "set -euo pipefail" \
        "wrapper_b64='$wrapper_b64'" \
        "deploy_b64='$deploy_b64'" \
        "installer_b64='$installer_b64'" \
        "unit_b64='$unit_b64'" \
        "[ \"\$(printf '%s' \"\$wrapper_b64\" | base64 -d | sha256sum | awk '{print \$1}')\" = \"$wrapper_sha256\" ] || { echo '$WRAPPER_FILE checksum mismatch' >&2; exit 1; }" \
        "[ \"\$(printf '%s' \"\$deploy_b64\" | base64 -d | sha256sum | awk '{print \$1}')\" = \"$deploy_sha256\" ] || { echo '$DEPLOY_FILE checksum mismatch' >&2; exit 1; }" \
        "[ \"\$(printf '%s' \"\$installer_b64\" | base64 -d | sha256sum | awk '{print \$1}')\" = \"$installer_sha256\" ] || { echo '$INSTALLER_FILE checksum mismatch' >&2; exit 1; }" \
        "[ \"\$(printf '%s' \"\$unit_b64\" | base64 -d | sha256sum | awk '{print \$1}')\" = \"$unit_sha256\" ] || { echo '$UNIT_FILE checksum mismatch' >&2; exit 1; }" \
        "tmp_dir=\"\$(mktemp -d /tmp/ec-portfolio-deploy.XXXXXX)\"" \
        "trap 'rm -rf \"\$tmp_dir\"' EXIT" \
        "printf '%s' \"\$wrapper_b64\" | base64 -d > \"\$tmp_dir/$WRAPPER_FILE\"" \
        "printf '%s' \"\$deploy_b64\" | base64 -d > \"\$tmp_dir/$DEPLOY_FILE\"" \
        "printf '%s' \"\$installer_b64\" | base64 -d > \"\$tmp_dir/$INSTALLER_FILE\"" \
        "printf '%s' \"\$unit_b64\" | base64 -d > \"\$tmp_dir/$UNIT_FILE\""
}

# Prints the commands both remote command lists run once the artifacts are
# verified and before any host copy is read. They take the deployment lock
# without waiting, so an install or deployment still running on the host makes
# this command fail instead of interleaving with it. They then refuse a release
# older than the newest one recorded on the host, which covers what the lock
# cannot: a command that reaches the host only after a newer release. A record
# that cannot be read, or that names another commit for the same run number,
# refuses every install until an operator looks at it. This release is recorded
# before anything is installed. Last, they define how the installed copies are
# compared with the verified artifacts.
locked_install_commands() {
    printf '%s\n' \
        "exec 9>'$REMOTE_DEPLOY_LOCK_FILE'" \
        "flock --nonblock 9 || { echo 'Another deployment or runtime install is running on this host; nothing was installed.' >&2; exit 1; }" \
        "release_record='$REMOTE_RELEASE_RECORD'" \
        "release_order='$GITHUB_RUN_NUMBER'" \
        "release_sha='$GITHUB_SHA'" \
        "record_unreadable() { echo \"The host runtime install record \$release_record is unreadable; nothing was installed. An operator has to inspect it.\" >&2; exit 1; }" \
        "if [ -e \"\$release_record\" ]; then read -r installed_order installed_sha <\"\$release_record\" || true; case \"\$installed_order\" in '' | *[!0-9]*) record_unreadable ;; esac; case \"\$installed_sha\" in '' | *[!0-9a-f]*) record_unreadable ;; esac; [ \"\${#installed_order}\" -le 18 ] && [ \"\${#installed_sha}\" -eq 40 ] || record_unreadable; if [ \"\$installed_order\" -gt \"\$release_order\" ]; then echo \"The host runtime was taken by a newer release (run \$installed_order, \$installed_sha); this older release (run \$release_order) installs nothing.\" >&2; exit 1; fi; if [ \"\$installed_order\" -eq \"\$release_order\" ] && [ \"\$installed_sha\" != \"\$release_sha\" ]; then echo \"The host runtime record names run \$installed_order with commit \$installed_sha, not \$release_sha; nothing was installed. An operator has to inspect it.\" >&2; exit 1; fi; fi" \
        "{ mkdir -p '$REMOTE_RUNTIME_DIR' && printf '%s %s\\n' \"\$release_order\" \"\$release_sha\" >\"\$release_record.tmp\" && mv -f \"\$release_record.tmp\" \"\$release_record\"; } || { echo 'Unable to record this release on the host; nothing was installed.' >&2; exit 1; }" \
        "same_file() { [ -f \"\$2\" ] && [ \"\$(sha256sum <\"\$1\" | awk '{print \$1}')\" = \"\$(sha256sum <\"\$2\" | awk '{print \$1}')\" ]; }" \
        "runtime_current() { same_file \"\$tmp_dir/$WRAPPER_FILE\" '$REMOTE_RUNTIME_DIR/$WRAPPER_FILE' && same_file \"\$tmp_dir/$DEPLOY_FILE\" '$REMOTE_RUNTIME_DIR/$DEPLOY_FILE' && same_file \"\$tmp_dir/$INSTALLER_FILE\" '$REMOTE_RUNTIME_DIR/$INSTALLER_FILE' && same_file \"\$tmp_dir/$UNIT_FILE\" '$REMOTE_SYSTEMD_DIR/$UNIT_FILE'; }"
}

# The command that fails the install unless the host now holds exactly the
# verified artifacts, whatever the installer reported.
installed_copies_check_command() {
    printf '%s\n' "runtime_current || { echo 'The installed host runtime does not match this release after installation.' >&2; exit 1; }"
}

# Builds the AWS-RunShellScript command list that verifies all four reviewed
# artifacts before creating any host-side file, installs them under the
# deployment lock and checks the installed copies, and executes the installed
# wrapper only after that. The lock is released just before the wrapper runs,
# because the wrapper takes the same lock itself and would otherwise refuse to
# run beside this command.
build_install_and_run_commands() {
    {
        verified_artifact_commands
        locked_install_commands
        printf '%s\n' "bash \"\$tmp_dir/$INSTALLER_FILE\""
        installed_copies_check_command
        printf '%s\n' \
            "exec 9>&-" \
            "$REMOTE_RUNTIME_DIR/$WRAPPER_FILE"
    } | jq -R . | jq -s .
}

# Builds the command list that brings the host runtime to this release without
# touching the API. Under the same lock and release check, the installer runs
# only if an installed copy differs from its verified artifact, and the installed
# copies are compared again afterwards, so the command succeeds only once the
# host holds exactly these four files. The wrapper never runs: no container is
# touched and no image is pulled.
build_install_runtime_commands() {
    {
        verified_artifact_commands
        locked_install_commands
        printf '%s\n' \
            "if runtime_current; then echo 'The host runtime already matches this release; nothing installed.'; exit 0; fi" \
            "bash \"\$tmp_dir/$INSTALLER_FILE\""
        installed_copies_check_command
        printf '%s\n' "echo 'Host runtime installed and verified; the API was not redeployed.'"
    } | jq -R . | jq -s .
}

# send_command <commands json> <comment> [delivery timeout seconds]: sends the
# command list and prints the command ID. With a delivery timeout, SSM drops the
# command unless the host has started it within that many seconds.
send_command() {
    local commands_json="$1"
    local comment="$2"
    local delivery_timeout_seconds="${3-}"
    local parameters_json
    local timeout_arguments=()

    parameters_json="$(jq -n --argjson commands "$commands_json" '{commands: $commands}')"
    [[ -z "$delivery_timeout_seconds" ]] ||
        timeout_arguments=(--timeout-seconds "$delivery_timeout_seconds")

    AWS_PAGER="" aws ssm send-command \
        --region "$EXPECTED_REGION" \
        --document-name "$SSM_DOCUMENT" \
        --instance-ids "$EC2_INSTANCE_ID" \
        --comment "$comment" \
        ${timeout_arguments[@]+"${timeout_arguments[@]}"} \
        --parameters "$parameters_json" \
        --query 'Command.CommandId' \
        --output text ||
        fail "Unable to send the deployment command."
}

send_deploy_command() {
    send_command "$(build_install_and_run_commands)" "ec-portfolio demo API deploy ${GITHUB_SHA:-manual}"
}

send_runtime_install_command() {
    send_command "$(build_install_runtime_commands)" "ec-portfolio demo runtime install ${GITHUB_SHA:-manual}" \
        "$RUNTIME_INSTALL_DELIVERY_TIMEOUT_SECONDS"
}

# await_command <command id> [poll attempts] [poll interval seconds]: polls the
# command to a terminal status within the given budget, the deployment budget by
# default. DEPLOY_POLL_ATTEMPTS and DEPLOY_POLL_INTERVAL_SECONDS override every
# budget, which is how the tests keep polling instant.
await_command() {
    local command_id="$1"
    local poll_attempts="${DEPLOY_POLL_ATTEMPTS:-${2:-$DEFAULT_POLL_ATTEMPTS}}"
    local poll_interval_seconds="${DEPLOY_POLL_INTERVAL_SECONDS:-${3:-$DEFAULT_POLL_INTERVAL_SECONDS}}"
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

await_runtime_install_command() {
    await_command "$1" "$RUNTIME_INSTALL_POLL_ATTEMPTS" "$RUNTIME_INSTALL_POLL_INTERVAL_SECONDS"
}

deploy() {
    local ping_status command_id

    validate_instance_id
    validate_release_identity
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

# install-runtime: see the command list at the top of this file. Anything but a
# verified install fails, so the step that records the desired image SHA never
# runs after it.
install_runtime() {
    local ping_status command_id

    validate_instance_id
    validate_release_identity
    ping_status="$(instance_ping_status)"

    [[ "$ping_status" == "Online" ]] ||
        fail "EC2 instance $EC2_INSTANCE_ID is not Online (status: $ping_status). This release changes the host runtime, which boot convergence cannot install, so its desired image SHA must not be recorded yet. Nothing was sent; re-run this job once the host is Online."

    command_id="$(send_runtime_install_command)"
    log "Runtime installation command sent: $command_id"
    await_runtime_install_command "$command_id"
    log "The host runtime matches this release, so its desired image SHA may be recorded."
}

# release: the main push path. Reads the scope build-and-push-api decided and
# does only what it requires; see the command list at the top of this file.
release() {
    local api_converge="${RELEASE_API_CONVERGE-}"
    local runtime_pending="${RELEASE_RUNTIME_PENDING-}"
    local ping_status command_id

    # Anything but an explicit true or false is a scope this job cannot trust:
    # an empty value means build-and-push-api produced no decision.
    [[ "$api_converge" == "true" || "$api_converge" == "false" ]] ||
        fail "RELEASE_API_CONVERGE must be true or false, not '$api_converge'."
    [[ "$runtime_pending" == "true" || "$runtime_pending" == "false" ]] ||
        fail "RELEASE_RUNTIME_PENDING must be true or false, not '$runtime_pending'."

    if [[ "$api_converge" == "false" && "$runtime_pending" == "false" ]]; then
        log "Nothing to release to the host: the API image and the host runtime are unchanged. No AWS call is made."
        return 0
    fi

    validate_instance_id
    validate_release_identity
    ping_status="$(instance_ping_status)"

    if [[ "$ping_status" != "Online" ]]; then
        log "EC2 instance $EC2_INSTANCE_ID is not Online (status: $ping_status)."
        if [[ "$api_converge" == "true" ]]; then
            log "No install or SendCommand attempted; the desired image SHA is left for Phase 5F-3 boot convergence."
            if [[ "$runtime_pending" == "true" ]]; then
                log "Boot convergence starts that image on the installed runtime: a desired image that needed a newer runtime was recorded only after install-runtime installed it. Any later runtime change stays pending for the next release that finds the host Online."
            fi
        else
            log "The host runtime install stays pending. It is measured from the last known good image, so the next release that runs while the host is Online installs it."
        fi
        return 0
    fi

    if [[ "$api_converge" == "true" ]]; then
        command_id="$(send_deploy_command)"
        log "Deployment command sent: $command_id"
        await_command "$command_id"
    else
        command_id="$(send_runtime_install_command)"
        log "Runtime installation command sent: $command_id"
        await_runtime_install_command "$command_id"
    fi
}

main() {
    local command_name="${1-}"

    (($# == 1)) || fail "Usage: deploy-runtime.sh deploy|install-runtime|release"

    for command_name_check in aws jq base64 sha256sum; do
        require_command "$command_name_check"
    done

    case "$command_name" in
    deploy) deploy ;;
    install-runtime) install_runtime ;;
    release) release ;;
    *) fail "Unknown command: $command_name" ;;
    esac
}

# Sourcing the script exposes the command builder without running a deployment,
# which is how deploy-runtime.test.sh executes the generated payload for real.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
