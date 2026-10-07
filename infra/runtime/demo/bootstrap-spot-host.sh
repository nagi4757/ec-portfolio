#!/usr/bin/env bash

# Brings a replacement ECS EC2 Spot host from first boot to serving-ready, in
# two phases.
#
#   pre   runs inside user data (cloud-final), started by the launch template's
#         loader. It builds the host -- TLS restore, certbot, the IMDS guard,
#         the ECS agent configuration -- and then hands over: it enables the
#         agent for later boots and queues ec-portfolio-spot-post-bootstrap
#         without waiting for either. It never starts the agent synchronously,
#         never polls for registration and never waits for the API task. On the
#         ECS-optimized AMI's packaging, ecs.service is ordered
#         After=cloud-final.service, so an agent started from user data cannot
#         come up until user data has finished; waiting for it from here would
#         only ever time out. The split makes the bootstrap correct whether or
#         not that ordering is present. A pre failure is reported as ABANDON by
#         the loader, which still owns the lifecycle action at that point.
#
#   post  runs from ec-portfolio-spot-post-bootstrap.service, ordered after
#         cloud-final.service and ecs.service. It proves the host -- cluster
#         registration, API readiness, the HTTPS origin and its smoke check --
#         enables certificate renewal and reports CONTINUE. Once the pre phase
#         has queued it, the lifecycle action belongs to this phase: any
#         failure, including systemd's start timeout, takes the host back out
#         of the cluster and reports ABANDON.
#
# The ordering is the contract. A replacement host must restore the origin TLS
# state that Phase 6B stored in S3 rather than ask Let's Encrypt for a new
# certificate: issuing on every replacement would reach the duplicate
# certificate rate limit within days. So the restore happens first, before
# certbot is installed, and there is no path in this script that issues a
# certificate. A restore that fails ends the run.
#
# The ECS agent is held back for the same reason. If it registered at boot, ECS
# would place the API task on a host that has no certificate, no Nginx, no IMDS
# guard and no renewal timer. The agent is disabled first and is only enabled
# after every pre gate has passed, so a half-built host never joins the
# cluster.
#
# This script does not associate the Elastic IP. Taking production traffic is a
# separate, deliberate step: a host proves itself here and is promoted later.
# Since Phase 6C-5c-2 "later" can be automatic, but it is still not here: once
# CONTINUE has been accepted, the post phase leaves a continue-accepted marker
# and, only when the launch template opted in with EIP_ALLOCATION_ID, queues
# ec-portfolio-spot-eip-promotion.service (promote-origin-eip.sh). Nothing in
# this file calls EC2.
#
# Artifact transport is out of scope. The runtime bundle is expected to already
# be present in this script's own directory, delivered by whatever placed this
# file on the host. Nothing is downloaded: a bootstrap that fetched its own code
# from a mutable location would decide at run time what root executes.
#
# What bundle.sha256 does and does not do is worth being precise about. It
# detects a partial or corrupted delivery -- a truncated file, a missing
# artifact, a copy that did not finish -- and refuses to run on one. It is not
# an authenticity check: anyone who can write into this directory can rewrite
# the manifest to match what they wrote. The manifest is trusted because the
# delivery is, not because it sits next to the files it describes.
#
# So authenticity belongs to whatever puts the bundle here, and that is the
# Phase 6C-3 launch template and user_data, not this script. This script is the
# host-side consumer of an already-trusted bundle.

set -euo pipefail

readonly ORIGIN_SERVER_NAME="origin-demo.yoonec.dev"

# Test seam. Empty in production, so every path below is the literal host path;
# the suite points it at a sandbox so the real ordering can be exercised without
# writing to /etc, /run or /usr/local on the machine running the tests.
#
# It is refused outright when this file is executed rather than sourced. Without
# that, one environment variable would redirect /etc/letsencrypt, /etc/ecs and
# /run on a real host -- so a caller who could set the environment of this
# bootstrap could have it restore TLS state somewhere it chose, write an ECS
# agent configuration nothing reads, and then report serving-ready. The suite
# sources the file and calls the step functions, which is a context an
# unprivileged caller of the executable cannot reach.
#
# No opt-out exists: adding a "test mode" variable would restore exactly the
# bypass this removes.
if [[ "${BASH_SOURCE[0]}" == "$0" && -n "${SPOT_BOOTSTRAP_PREFIX:-}" ]]; then
    printf '[spot-bootstrap] ERROR: %s\n' \
        "SPOT_BOOTSTRAP_PREFIX is a test seam and cannot be used when this script is executed." >&2
    exit 1
fi
readonly BOOTSTRAP_PREFIX="${SPOT_BOOTSTRAP_PREFIX:-}"

readonly LETSENCRYPT_DIRECTORY="${BOOTSTRAP_PREFIX}/etc/letsencrypt"
readonly ECS_CONFIG_DIRECTORY="${BOOTSTRAP_PREFIX}/etc/ecs"
readonly ECS_CONFIG_FILE="$ECS_CONFIG_DIRECTORY/ecs.config"
readonly MARKER_DIRECTORY="${BOOTSTRAP_PREFIX}/run/ec-portfolio-demo"
readonly SERVING_READY_MARKER="$MARKER_DIRECTORY/spot-serving-ready"
readonly CONTINUE_ACCEPTED_MARKER="$MARKER_DIRECTORY/spot-continue-accepted"

readonly SYNC_TARGET="${BOOTSTRAP_PREFIX}/usr/local/sbin/ec-portfolio-sync-origin-tls"
readonly RENEW_TARGET="${BOOTSTRAP_PREFIX}/usr/local/sbin/ec-portfolio-renew-origin-cert"
readonly IMDS_GUARD_TARGET="${BOOTSTRAP_PREFIX}/usr/local/sbin/ec-portfolio-imds-guard"
readonly ENV_DIRECTORY="${BOOTSTRAP_PREFIX}/etc/ec-portfolio"
readonly ENV_TARGET="$ENV_DIRECTORY/origin-tls.env"
readonly POST_BOOTSTRAP_ENV_FILE="$ENV_DIRECTORY/spot-post-bootstrap.env"
readonly SYSTEMD_UNIT_DIRECTORY="${BOOTSTRAP_PREFIX}/etc/systemd/system"
readonly RENEW_UNIT_TARGET="$SYSTEMD_UNIT_DIRECTORY/ec-portfolio-certbot-renew.service"
readonly RENEW_TIMER_TARGET="$SYSTEMD_UNIT_DIRECTORY/ec-portfolio-certbot-renew.timer"
readonly IMDS_GUARD_UNIT="ec-portfolio-imds-guard.service"
readonly IMDS_GUARD_UNIT_TARGET="$SYSTEMD_UNIT_DIRECTORY/$IMDS_GUARD_UNIT"
readonly POST_BOOTSTRAP_UNIT="ec-portfolio-spot-post-bootstrap.service"
readonly POST_BOOTSTRAP_UNIT_TARGET="$SYSTEMD_UNIT_DIRECTORY/$POST_BOOTSTRAP_UNIT"
readonly PROMOTION_UNIT="ec-portfolio-spot-eip-promotion.service"
readonly PROMOTION_UNIT_TARGET="$SYSTEMD_UNIT_DIRECTORY/$PROMOTION_UNIT"

# The runtime bundle this host must carry. Checked as a set before any checksum
# is verified: sha256sum --check only validates the entries a manifest happens
# to list, so a manifest that simply omits a file would pass while the file it
# should have covered is whatever was delivered.
#
# The same list lives in two more places: spot_bundle_manifest_artifacts in
# infra/terraform/demo/runtime_artifacts.tf, which builds the archive, and the
# loader in templates/ecs-spot-user-data.sh.tftpl, which sets file modes after
# extraction. spot-runtime-bundle.test.sh fails when the three disagree.
readonly REQUIRED_BUNDLE_ARTIFACTS=(
    "sync-origin-tls.sh"
    "renew-origin-cert.sh"
    "configure-origin.sh"
    "origin-smoke-check-ecs.sh"
    "ec-portfolio-certbot-renew.service"
    "ec-portfolio-certbot-renew.timer"
    "imds-guard.sh"
    "ec-portfolio-imds-guard.service"
    "ec-portfolio-spot-post-bootstrap.service"
    "promote-origin-eip.sh"
    "ec-portfolio-spot-eip-promotion.service"
)
readonly BUNDLE_MANIFEST_NAME="bundle.sha256"

# The only Region this Demo runs in. Passed explicitly to every AWS child rather
# than left to the CLI's own resolution: a host that picked up a Region from an
# inherited profile or a stray config file would read a different parameter
# store than the one this deployment owns.
readonly EXPECTED_AWS_REGION="ap-northeast-1"

# Every inherited credential source is cleared before an AWS child runs. The
# instance role is the only identity this host is meant to have; anything in the
# caller environment is either a mistake or an attempt to make this host act as
# somebody else.
readonly AWS_CREDENTIAL_ENV=(
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
    AWS_PROFILE AWS_DEFAULT_PROFILE AWS_CREDENTIAL_FILE
    AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE
)

# Clearing static keys is not enough on its own. The credential chain has other
# entry points that would each hand a child a different identity: a web identity
# token, a container credential endpoint, or metadata turned off or redirected
# so the instance role cannot be reached at all.
readonly AWS_PROVIDER_ENV=(
    AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN
    AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_CREDENTIALS_RELATIVE_URI
    AWS_EC2_METADATA_DISABLED AWS_EC2_METADATA_SERVICE_ENDPOINT
    AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE
)

# Where the call goes and who it trusts. An endpoint override would send an SSM
# or S3 read to a host of the caller's choosing, and a substituted trust store
# would let that host present a certificate of its own. The same list
# renew-origin-cert.sh already blocks, extended with the S3 and SSM endpoints
# this bootstrap uses.
readonly AWS_ENDPOINT_ENV=(
    AWS_ENDPOINT_URL AWS_ENDPOINT_URL_S3 AWS_ENDPOINT_URL_SSM AWS_ENDPOINT_URL_ROUTE53
    AWS_CA_BUNDLE REQUESTS_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR BOTO_CONFIG
)

# Test seams belonging to the helpers this script calls. They are cleared too:
# a seam that redirects where TLS state is restored, or which certbot
# configuration is validated, must not be reachable by setting the environment
# of this bootstrap.
readonly HELPER_SEAM_ENV=(
    ORIGIN_TLS_PARENT_DIRECTORY CERTBOT_CONFIG_PREFIX ORIGIN_SMOKE_MODE
    SPOT_BOOTSTRAP_PREFIX
)

readonly DNF_TIMEOUT_SECONDS="10m"
readonly SYSTEMCTL_TIMEOUT_SECONDS="30s"
readonly AWS_TIMEOUT_SECONDS="5m"
readonly IMDS_GUARD_TIMEOUT_SECONDS="60s"
readonly TIMEOUT_KILL_AFTER_SECONDS="5s"

# Bounded waits, in the post phase only. A replacement that cannot reach these
# states is a failure to report, not something to sit on: the ASG will try
# again with a new instance.
readonly REGISTRATION_ATTEMPTS="${SPOT_REGISTRATION_ATTEMPTS:-60}"
readonly REGISTRATION_INTERVAL_SECONDS="${SPOT_REGISTRATION_INTERVAL_SECONDS:-5}"
readonly READINESS_ATTEMPTS="${SPOT_READINESS_ATTEMPTS:-60}"
readonly READINESS_INTERVAL_SECONDS="${SPOT_READINESS_INTERVAL_SECONDS:-5}"

script_directory=""

# pre | post, set by main() or by the suite. Decides who reports a failure: the
# loader for pre, this script for post.
bootstrap_mode=""

# Cleanup state. Each flag is raised *before* the command that could create the
# side effect it describes, not after it succeeds: `systemctl enable --now` can
# enable a unit and then fail to start it, and an enabled unit would come back
# on the next boot. The name says "may be" because that is all the caller can
# know from a non-zero exit. For the ECS agent this is true from the very first
# step: the AMI ships the unit enabled, so the host arrives with it already
# active and the bootstrap's own disable can fail halfway.
ecs_agent_may_be_active="false"
renew_timer_may_be_enabled="false"
post_bootstrap_may_be_queued="false"
bootstrap_committed="false"

log() {
    printf '[spot-bootstrap] %s\n' "$*"
}

warn() {
    printf '[spot-bootstrap] WARNING: %s\n' "$*" >&2
}

fail() {
    printf '[spot-bootstrap] ERROR: %s\n' "$*" >&2
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

run_systemctl() {
    run_with_timeout "$SYSTEMCTL_TIMEOUT_SECONDS" systemctl "$@"
}

# Runs a child with the instance role as its only identity and with every helper
# seam removed, and with the Region stated rather than discovered.
run_aws_child() {
    local -a clear=()
    local name
    for name in "${AWS_CREDENTIAL_ENV[@]}" "${AWS_PROVIDER_ENV[@]}" \
        "${AWS_ENDPOINT_ENV[@]}" "${HELPER_SEAM_ENV[@]}"; do
        clear+=(-u "$name")
    done
    env "${clear[@]}" \
        AWS_REGION="$EXPECTED_AWS_REGION" \
        AWS_DEFAULT_REGION="$EXPECTED_AWS_REGION" \
        "$@"
}

# CompleteLifecycleAction carries both outcomes. Called only by the post phase:
# until the pre phase queues the post unit, the loader owns the action.
#
# The cleanup can reach this before validate_inputs has run, so the identifiers
# are checked here as well; with any of them missing or malformed nothing is
# sent, and the hook's ABANDON default decides instead.
report_lifecycle_action() {
    local result="$1"
    [[ "${AUTOSCALING_GROUP_NAME:-}" =~ ^[A-Za-z0-9_.-]{1,255}$ &&
        "${LIFECYCLE_HOOK_NAME:-}" =~ ^[A-Za-z0-9_.-]{1,255}$ &&
        "${INSTANCE_ID:-}" =~ ^i-[0-9a-f]{8,17}$ ]] || return 1
    log "Reporting $result to the launch lifecycle hook."
    run_aws_child AWS_PAGER="" \
        timeout --signal=TERM --kill-after="$TIMEOUT_KILL_AFTER_SECONDS" "$AWS_TIMEOUT_SECONDS" \
        aws autoscaling complete-lifecycle-action \
        --region "$EXPECTED_AWS_REGION" \
        --auto-scaling-group-name "$AUTOSCALING_GROUP_NAME" \
        --lifecycle-hook-name "$LIFECYCLE_HOOK_NAME" \
        --instance-id "$INSTANCE_ID" \
        --lifecycle-action-result "$result" >/dev/null
}

# A failure anywhere before the commit point must leave this host out of the
# cluster. Without this the agent would keep running after a failed
# registration, readiness or smoke gate, and ECS would place work on a host that
# never finished building itself.
#
# Cleanup is best effort and must not change the exit code: the reason the
# bootstrap failed is more useful than a failure to tidy up after it.
#
# In the post phase the cleanup also reports ABANDON, because nothing else will
# before the hook's heartbeat runs out. The same path runs when systemd stops
# the unit at its start timeout: the TERM trap below turns the signal into a
# non-zero exit, so a hung post-bootstrap is abandoned, not left waiting.
cleanup() {
    local exit_code=$?
    # Captured first, then the signals ignored, and only then the EXIT trap
    # cleared, for the reason deploy-api.sh gives: a second TERM must not cut
    # the cleanup in half.
    trap '' TERM INT
    trap - EXIT

    if (( exit_code != 0 )) && [[ "$bootstrap_committed" != "true" ]]; then
        rm -f "$SERVING_READY_MARKER" 2>/dev/null || true
        if [[ "$post_bootstrap_may_be_queued" == "true" ]]; then
            printf '[spot-bootstrap] %s\n' \
                "Bootstrap failed after the post-bootstrap was queued; cancelling it." >&2
            run_systemctl stop --no-block "$POST_BOOTSTRAP_UNIT" >/dev/null 2>&1 || true
        fi
        if [[ "$renew_timer_may_be_enabled" == "true" ]]; then
            printf '[spot-bootstrap] %s\n' \
                "Bootstrap failed after the renewal timer was touched; disabling it." >&2
            run_systemctl disable --now ec-portfolio-certbot-renew.timer >/dev/null 2>&1 || true
        fi
        if [[ "$ecs_agent_may_be_active" == "true" ]]; then
            printf '[spot-bootstrap] %s\n' \
                "Bootstrap failed after the ECS agent was touched; taking the host back out of the cluster." >&2
            run_systemctl disable --now ecs >/dev/null 2>&1 || true
        fi
        if [[ "$bootstrap_mode" == "post" ]]; then
            report_lifecycle_action ABANDON >/dev/null 2>&1 ||
                printf '[spot-bootstrap] %s\n' \
                    "ABANDON could not be reported; the launch hook will time out into its ABANDON default." >&2
        fi
    fi

    exit "$exit_code"
}

# Bash runs the EXIT trap when an untrapped SIGTERM ends the shell, but the
# status cleanup() then observes is 0, so it would take the success path. The
# conventional 128+signal exit makes the failure path run on a signal as well --
# which is how systemd's start timeout on the post unit becomes an ABANDON.
trap 'exit 143' TERM
trap 'exit 130' INT
trap cleanup EXIT

validate_platform() {
    (( EUID == 0 )) || fail "This script must run as root."
    [[ -r /etc/os-release ]] || fail "Cannot identify the operating system."
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "amzn" && "${VERSION_ID:-}" == 2023* ]] ||
        fail "Amazon Linux 2023 is required."

    local command_name
    for command_name in aws curl dnf grep install iptables mktemp rm setpriv sha256sum ss systemctl timeout; do
        require_command "$command_name"
    done
}

# Both phases take the same inputs. The pre phase receives them from the loader
# and writes them to the post unit's environment file; the post phase receives
# them back from systemd. Each is checked where it is used, not trusted because
# the other phase checked it.
validate_inputs() {
    (( $# == 0 )) || fail "Inputs are passed through the environment, not as arguments."

    [[ -n "${ECS_CLUSTER_NAME:-}" ]] ||
        fail "Required environment variable is missing: ECS_CLUSTER_NAME"
    [[ "$ECS_CLUSTER_NAME" =~ ^[A-Za-z0-9_-]{1,255}$ ]] ||
        fail "ECS_CLUSTER_NAME is not a valid cluster name."

    [[ -n "${ORIGIN_TLS_BUCKET:-}" ]] ||
        fail "Required environment variable is missing: ORIGIN_TLS_BUCKET"
    [[ "$ORIGIN_TLS_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] ||
        fail "ORIGIN_TLS_BUCKET is not a valid bucket name."

    # What the post phase needs to report the launch lifecycle action. The
    # names are the fixed Terraform locals the loader carries; the instance ID
    # is the loader's own, read from IMDSv2.
    [[ -n "${AUTOSCALING_GROUP_NAME:-}" ]] ||
        fail "Required environment variable is missing: AUTOSCALING_GROUP_NAME"
    [[ "$AUTOSCALING_GROUP_NAME" =~ ^[A-Za-z0-9_.-]{1,255}$ ]] ||
        fail "AUTOSCALING_GROUP_NAME is not a valid Auto Scaling group name."

    [[ -n "${LIFECYCLE_HOOK_NAME:-}" ]] ||
        fail "Required environment variable is missing: LIFECYCLE_HOOK_NAME"
    [[ "$LIFECYCLE_HOOK_NAME" =~ ^[A-Za-z0-9_.-]{1,255}$ ]] ||
        fail "LIFECYCLE_HOOK_NAME is not a valid lifecycle hook name."

    [[ -n "${INSTANCE_ID:-}" ]] ||
        fail "Required environment variable is missing: INSTANCE_ID"
    [[ "$INSTANCE_ID" =~ ^i-[0-9a-f]{8,17}$ ]] ||
        fail "INSTANCE_ID is not a valid EC2 instance ID."

    # Phase 6C-5c-2, optional. The launch template opts a host into promoting
    # itself by naming the origin Elastic IP's allocation. Without it no
    # promotion unit is installed or queued, and the host only serves once an
    # operator moves the address.
    if [[ -n "${EIP_ALLOCATION_ID:-}" ]]; then
        [[ "$EIP_ALLOCATION_ID" =~ ^eipalloc-[0-9a-f]{8,17}$ ]] ||
            fail "EIP_ALLOCATION_ID is not a valid Elastic IP allocation ID."
    fi

    # Stated, not discovered. If a caller supplies one it must be the Region
    # this deployment lives in; anything else would point the AWS children at a
    # different parameter store and a different bucket.
    local supplied_region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
    if [[ -n "$supplied_region" ]]; then
        [[ "$supplied_region" =~ ^[a-z0-9-]{5,32}$ ]] ||
            fail "The supplied AWS Region is not a valid Region name."
        [[ "$supplied_region" == "$EXPECTED_AWS_REGION" ]] ||
            fail "This bootstrap only runs in $EXPECTED_AWS_REGION (got $supplied_region)."
    fi
}

# Every artifact is resolved next to this script and checked against the SHA256
# the caller states. A bundle that does not match is refused before anything is
# installed, so a tampered or partial delivery cannot reach root execution.
resolve_bundle() {
    local source_directory
    source_directory="$(dirname -- "${BASH_SOURCE[0]}")"
    script_directory="$(cd -- "$source_directory" && pwd -P)" ||
        fail "Cannot resolve the runtime bundle directory."

    local name
    for name in "${REQUIRED_BUNDLE_ARTIFACTS[@]}"; do
        [[ -f "$script_directory/$name" ]] ||
            fail "The runtime bundle is missing $name. This script does not download artifacts."
        if [[ "$name" == *.sh ]]; then
            [[ -x "$script_directory/$name" ]] ||
                fail "Bundled script is not executable: $name"
        fi
    done
}

# sha256sum --check validates the entries a manifest lists and says nothing
# about the ones it does not. A manifest that omitted configure-origin.sh would
# pass while that file was whatever the delivery left behind, so the manifest is
# first checked for shape: every required artifact named exactly once, nothing
# addressed outside this directory.
verify_bundle_manifest_covers_artifacts() {
    local manifest="$1"
    local artifact path count

    # Entry paths are the second field. Reject anything that could name a file
    # outside the bundle before sha256sum is asked to read it.
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        [[ "$path" != /* ]] ||
            fail "The bundle manifest contains an absolute path: $path"
        [[ "$path" != *".."* ]] ||
            fail "The bundle manifest contains a parent traversal entry: $path"
    done < <(awk '{ sub(/^[*]/, "", $2); print $2 }' "$manifest")

    for artifact in "${REQUIRED_BUNDLE_ARTIFACTS[@]}"; do
        count="$(awk -v want="$artifact" '{ sub(/^[*]/, "", $2); if ($2 == want) n++ } END { print n + 0 }' "$manifest")"
        (( count == 1 )) ||
            fail "The bundle manifest must name $artifact exactly once (found $count)."
    done
}

verify_bundle_checksums() {
    local manifest="$script_directory/$BUNDLE_MANIFEST_NAME"

    [[ -f "$manifest" ]] ||
        fail "The runtime bundle checksum manifest is missing: $manifest"

    verify_bundle_manifest_covers_artifacts "$manifest"

    log "Verifying the runtime bundle against $BUNDLE_MANIFEST_NAME."
    ( cd -- "$script_directory" && sha256sum --check --status -- "$BUNDLE_MANIFEST_NAME" ) ||
        fail "The runtime bundle does not match its expected SHA256 manifest."
}

# A host that already carries certbot state is not a fresh replacement. Rather
# than reason about merging, stop: the operator decides what that host is.
verify_letsencrypt_absent() {
    [[ ! -e "$LETSENCRYPT_DIRECTORY" && ! -L "$LETSENCRYPT_DIRECTORY" ]] ||
        fail "$LETSENCRYPT_DIRECTORY already exists. This bootstrap only runs on a host with no certbot state."
}

# Held back before anything else, so no failure below can leave an agent that
# registers and receives a task.
disable_ecs_agent() {
    log "Holding the ECS agent back until the host is ready."
    # The ECS-optimized AMI ships the agent enabled, so this call has something
    # to undo from the first moment the host boots. It carries the same partial
    # failure hazard as `enable --now`: `disable --now` is also two operations,
    # and a non-zero exit can leave the unit enabled for the next boot. The flag
    # is therefore raised before the call, not after a later one -- otherwise a
    # bootstrap that failed right here would exit with the agent still enabled
    # and nothing in the cleanup willing to touch it.
    #
    # On an AMI whose ecs.service is ordered After=cloud-final.service, the
    # agent's boot-time start job is still waiting at this point, and stopping
    # the unit cancels it; nothing here waits for cloud-final.
    ecs_agent_may_be_active="true"
    run_systemctl disable --now ecs ||
        fail "Unable to disable the ECS agent before bootstrap."
}

restore_origin_tls_state() {
    log "Restoring the origin TLS state from S3."
    install -o root -g root -m 0755 "$script_directory/sync-origin-tls.sh" "$SYNC_TARGET" ||
        fail "Unable to install the origin TLS helper."

    run_aws_child ORIGIN_TLS_BUCKET="$ORIGIN_TLS_BUCKET" "$SYNC_TARGET" restore ||
        fail "The origin TLS restore failed. Refusing to continue; this host will not request a new certificate."
}

install_certbot_packages() {
    log "Installing certbot after the restore, never before it."
    run_with_timeout "$DNF_TIMEOUT_SECONDS" \
        dnf install -y certbot python3-certbot-dns-route53 ||
        fail "Certbot package installation failed or timed out."
    require_command certbot
}

# The renewal script owns this contract and is the reviewed implementation of
# it. Sourcing it runs no renewal: the file guards its own main().
verify_global_certbot_config() {
    log "Verifying the package-owned Certbot global configuration."
    install -o root -g root -m 0755 "$script_directory/renew-origin-cert.sh" "$RENEW_TARGET" ||
        fail "Unable to install the renewal script."

    run_aws_child bash -c 'source "$1"; verify_global_certbot_config_contract' _ "$RENEW_TARGET" ||
        fail "The Certbot global configuration does not satisfy the managed contract."
}

install_renewal_runtime() {
    log "Installing the renewal env file, unit and timer."
    install -d -o root -g root -m 0755 "$ENV_DIRECTORY" ||
        fail "Unable to create $ENV_DIRECTORY."

    local staged
    staged="$(mktemp)" || fail "Unable to stage the renewal env file."
    printf 'ORIGIN_TLS_BUCKET=%s\n' "$ORIGIN_TLS_BUCKET" >"$staged"
    install -o root -g root -m 0644 "$staged" "$ENV_TARGET" ||
        fail "Unable to install $ENV_TARGET."
    rm -f "$staged"

    install -o root -g root -m 0644 \
        "$script_directory/ec-portfolio-certbot-renew.service" "$RENEW_UNIT_TARGET" ||
        fail "Unable to install the renewal service unit."
    install -o root -g root -m 0644 \
        "$script_directory/ec-portfolio-certbot-renew.timer" "$RENEW_TIMER_TARGET" ||
        fail "Unable to install the renewal timer."
}

# Phase 6C-4a. The API and Valkey tasks run in host network mode, where the
# launch template's IMDSv2 hop limit does not apply. imds-guard.sh keeps every
# non-root UID away from 169.254.169.254; its unit is ordered before
# ecs.service and required by it, so from here on the agent cannot start --
# on this boot or any later one -- without the rules in place.
install_imds_guard() {
    log "Installing the container IMDS guard."
    install -o root -g root -m 0755 "$script_directory/imds-guard.sh" "$IMDS_GUARD_TARGET" ||
        fail "Unable to install the IMDS guard."
    install -o root -g root -m 0644 \
        "$script_directory/$IMDS_GUARD_UNIT" "$IMDS_GUARD_UNIT_TARGET" ||
        fail "Unable to install the IMDS guard unit."
}

# The post phase's inputs, handed over through the unit's EnvironmentFile. None
# of them is a secret; the file is root-only anyway, like the rest of /etc/ecs.
install_post_bootstrap() {
    log "Installing the post-bootstrap unit and its environment."
    install -d -o root -g root -m 0755 "$ENV_DIRECTORY" ||
        fail "Unable to create $ENV_DIRECTORY."

    local staged
    staged="$(mktemp)" || fail "Unable to stage the post-bootstrap environment."
    {
        printf 'ECS_CLUSTER_NAME=%s\n' "$ECS_CLUSTER_NAME"
        printf 'ORIGIN_TLS_BUCKET=%s\n' "$ORIGIN_TLS_BUCKET"
        printf 'AUTOSCALING_GROUP_NAME=%s\n' "$AUTOSCALING_GROUP_NAME"
        printf 'LIFECYCLE_HOOK_NAME=%s\n' "$LIFECYCLE_HOOK_NAME"
        printf 'INSTANCE_ID=%s\n' "$INSTANCE_ID"
        printf 'AWS_REGION=%s\n' "$EXPECTED_AWS_REGION"
        if [[ -n "${EIP_ALLOCATION_ID:-}" ]]; then
            printf 'EIP_ALLOCATION_ID=%s\n' "$EIP_ALLOCATION_ID"
        fi
    } >"$staged"
    install -o root -g root -m 0600 "$staged" "$POST_BOOTSTRAP_ENV_FILE" ||
        fail "Unable to install $POST_BOOTSTRAP_ENV_FILE."
    rm -f "$staged"

    install -o root -g root -m 0644 \
        "$script_directory/$POST_BOOTSTRAP_UNIT" "$POST_BOOTSTRAP_UNIT_TARGET" ||
        fail "Unable to install the post-bootstrap unit."

    # Opt-in only: a host that was not given an allocation has no promotion
    # unit to start, by anyone. It reads the same environment file.
    if [[ -n "${EIP_ALLOCATION_ID:-}" ]]; then
        install -o root -g root -m 0644 \
            "$script_directory/$PROMOTION_UNIT" "$PROMOTION_UNIT_TARGET" ||
            fail "Unable to install the Elastic IP promotion unit."
    fi
}

reload_systemd() {
    run_systemctl daemon-reload || fail "systemd daemon-reload failed or timed out."
}

# The guard's effect is proven rather than assumed: verify obtains an IMDSv2
# token as root and checks that the container UIDs are refused. A guard that
# installed but did not work fails the bootstrap before the ECS agent can be
# started. The guard has no ordering against cloud-final, so starting it from
# here does not wait on user data.
#
# Nothing in the cleanup undoes it: a guard left enabled on a failed host only
# makes that host stricter, and keeps its agent down on the next boot.
start_imds_guard() {
    log "Enabling the IMDS guard and proving its effect."
    run_systemctl enable --now "$IMDS_GUARD_UNIT" ||
        fail "The IMDS guard could not be enabled."
    run_with_timeout "$IMDS_GUARD_TIMEOUT_SECONDS" "$IMDS_GUARD_TARGET" verify ||
        fail "The IMDS guard did not keep non-root UIDs away from IMDS."
}

# Deliberately separate from installing the units, and deliberately last. The
# timer is Persistent=true, so nothing is lost by starting it at the end, and a
# host that never became ready should not be running renewals against a
# certificate it is not serving.
enable_renewal_timer() {
    log "Enabling the renewal timer."
    # Same hazard as the agent: a host that failed its bootstrap must not come
    # back from a reboot renewing certificates and writing them to S3.
    renew_timer_may_be_enabled="true"
    run_systemctl enable --now ec-portfolio-certbot-renew.timer ||
        fail "The renewal timer could not be enabled."
}

# Written only once every pre gate above has passed. Until this file exists the
# agent has no cluster to join, which is what keeps a half-built host out of
# the cluster.
#
# The whole file is written on every run and replaced in one step, so a rerun
# leaves exactly these lines, each once, in this order.
#
# ECS_ENABLE_AWSLOGS_EXECUTIONROLE_OVERRIDE: the Amazon ECS task execution role
# guide requires it for tasks on the EC2 launch type that take secrets from
# Systems Manager Parameter Store through the task execution role. The Phase
# 6C-4 API task does.
write_ecs_config() {
    log "Writing the ECS agent configuration."
    install -d -o root -g root -m 0755 "$ECS_CONFIG_DIRECTORY" ||
        fail "Unable to create $ECS_CONFIG_DIRECTORY."

    local staged
    staged="$(mktemp)" || fail "Unable to stage the ECS agent configuration."
    {
        printf 'ECS_CLUSTER=%s\n' "$ECS_CLUSTER_NAME"
        printf 'ECS_ENABLE_SPOT_INSTANCE_DRAINING=true\n'
        printf 'ECS_ENABLE_AWSLOGS_EXECUTIONROLE_OVERRIDE=true\n'
    } >"$staged"
    install -o root -g root -m 0644 "$staged" "$ECS_CONFIG_FILE" ||
        fail "Unable to install $ECS_CONFIG_FILE."
    rm -f "$staged"
}

# Enabled, not started. The agent comes back on later boots -- after the guard,
# which ecs.service now requires -- and on this boot it is started by the post
# unit's Wants=, not from inside user data.
enable_ecs_agent() {
    log "Enabling the ECS agent for later boots, without starting it from user data."
    # Already true: disable_ecs_agent raised it at the top of the run. Repeated
    # here so the invariant is stated where the side effect is.
    ecs_agent_may_be_active="true"
    run_systemctl enable ecs || fail "The ECS agent could not be enabled."
}

# The hand-over. --no-block queues the job and returns: the unit is ordered
# after cloud-final.service, and waiting for it here would wait for this very
# script to exit. From here on the post phase owns the lifecycle action.
queue_post_bootstrap() {
    log "Queueing $POST_BOOTSTRAP_UNIT to run after user data finishes."
    post_bootstrap_may_be_queued="true"
    run_systemctl start --no-block "$POST_BOOTSTRAP_UNIT" ||
        fail "The post-bootstrap could not be queued."
}

# Registration is only interesting if it is registration with the cluster this
# host was told to join. An agent that came up against "default", or against
# another cluster, would report a Cluster key and would be scheduled by somebody
# else entirely.
wait_for_cluster_registration() {
    local attempt metadata registered

    log "Waiting for ECS cluster registration."
    for ((attempt = 1; attempt <= REGISTRATION_ATTEMPTS; attempt++)); do
        metadata="$(curl --disable --silent --fail --max-time 3 \
            http://localhost:51678/v1/metadata 2>/dev/null || true)"
        if [[ -n "$metadata" ]]; then
            registered="$(sed -n 's/.*"Cluster"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<<"$metadata")"
            if [[ "$registered" == "$ECS_CLUSTER_NAME" ]]; then
                log "The ECS agent is registered with $ECS_CLUSTER_NAME."
                return 0
            fi
            if [[ -n "$registered" ]]; then
                fail "The ECS agent registered with '$registered' rather than '$ECS_CLUSTER_NAME'."
            fi
        fi
        sleep "$REGISTRATION_INTERVAL_SECONDS"
    done
    fail "The ECS agent did not register with $ECS_CLUSTER_NAME within the configured budget."
}

wait_for_api_readiness() {
    local attempt
    log "Waiting for the API task to become ready on loopback."
    for ((attempt = 1; attempt <= READINESS_ATTEMPTS; attempt++)); do
        if curl --disable --silent --fail --max-time 3 \
            http://127.0.0.1:8080/actuator/health/readiness 2>/dev/null |
            grep -Eq '"status"[[:space:]]*:[[:space:]]*"UP"'; then
            log "The API task is ready."
            return 0
        fi
        sleep "$READINESS_INTERVAL_SECONDS"
    done
    fail "The API task did not become ready within the configured budget."
}

# Runs after the task is serving, not before. configure-origin.sh installs the
# Nginx configuration and then validates the live origin end to end, rolling the
# configuration back if that validation fails. That contract only means
# something once there is an API behind Nginx to answer, and nothing is lost by
# waiting: this host holds no Elastic IP yet, so it is taking no traffic.
configure_origin() {
    log "Configuring the HTTPS origin and validating it end to end."
    # configure-origin.sh and the ECS smoke it runs both read the origin
    # verification SecureString, so they go through the same hardened child:
    # instance role only, Region stated, helper seams cleared. ORIGIN_SMOKE_MODE
    # is set here rather than inherited, which is why the seam list clears it
    # first.
    run_aws_child ORIGIN_SERVER_NAME="$ORIGIN_SERVER_NAME" \
        ORIGIN_CERT_FILE="$LETSENCRYPT_DIRECTORY/live/$ORIGIN_SERVER_NAME/fullchain.pem" \
        ORIGIN_KEY_FILE="$LETSENCRYPT_DIRECTORY/live/$ORIGIN_SERVER_NAME/privkey.pem" \
        ORIGIN_SMOKE_MODE=ecs \
        "$script_directory/configure-origin.sh" ||
        fail "The HTTPS origin configuration or its end-to-end validation failed."
}

reset_serving_ready_marker() {
    install -d -o root -g root -m 0755 "$MARKER_DIRECTORY" ||
        fail "Unable to create $MARKER_DIRECTORY."
    rm -f "$SERVING_READY_MARKER" "$CONTINUE_ACCEPTED_MARKER"
}

# It lives under /run so a reboot clears it: a host that came back up has not
# re-proven itself and must not be treated as ready. Written before CONTINUE and
# removed again by the cleanup if CONTINUE cannot be reported.
record_serving_ready_marker() {
    install -d -o root -g root -m 0755 "$MARKER_DIRECTORY" ||
        fail "Unable to create $MARKER_DIRECTORY."
    install -o root -g root -m 0644 /dev/null "$SERVING_READY_MARKER" ||
        fail "Unable to record the serving-ready marker."
}

# The commit point. Only a CONTINUE that Auto Scaling accepted makes this host
# InService, so only then is the cleanup told to stand down.
report_continue() {
    report_lifecycle_action CONTINUE ||
        fail "CONTINUE could not be reported to the launch lifecycle hook."
    bootstrap_committed="true"
    log "Serving-ready and InService. The Elastic IP is NOT associated by this script."
}

# Phase 6C-5c-2. After the commit point, and only then: the marker that tells
# the promotion unit Auto Scaling accepted CONTINUE, and -- when the launch
# template opted in -- the promotion queued behind this unit (its After= makes
# it start once this one has finished). Nothing here may fail the bootstrap any
# more. The host is InService, and a host that cannot promote itself is still
# healthy capacity, so a problem is logged, never turned into an ABANDON.
hand_over_promotion() {
    [[ "$bootstrap_committed" == "true" ]] || return 0
    if ! install -o root -g root -m 0644 /dev/null "$CONTINUE_ACCEPTED_MARKER"; then
        warn "The continue-accepted marker could not be written; the Elastic IP stays with its current holder."
        return 0
    fi
    if [[ -z "${EIP_ALLOCATION_ID:-}" ]]; then
        log "No EIP_ALLOCATION_ID: this host does not promote itself. The Elastic IP stays with its current holder."
        return 0
    fi
    log "Queueing $PROMOTION_UNIT to run after this unit."
    run_systemctl start --no-block "$PROMOTION_UNIT" ||
        warn "$PROMOTION_UNIT could not be queued; the Elastic IP stays with its current holder."
    return 0
}

# The pre phase, separated from the platform and privilege checks in main() so
# the suite can drive it without being root. Nothing here polls the agent or
# the API task.
run_pre_bootstrap_steps() {
    bootstrap_mode="pre"
    disable_ecs_agent
    reset_serving_ready_marker
    resolve_bundle
    verify_bundle_checksums
    verify_letsencrypt_absent
    restore_origin_tls_state
    install_certbot_packages
    verify_global_certbot_config
    install_renewal_runtime
    install_imds_guard
    install_post_bootstrap
    reload_systemd
    start_imds_guard
    write_ecs_config
    enable_ecs_agent
    queue_post_bootstrap
    log "Pre-bootstrap complete. $POST_BOOTSTRAP_UNIT reports the launch lifecycle action."
}

# The post phase. The agent is already running -- systemd started it for the
# unit's Wants= -- so any failure from the first line on must take it down.
run_post_bootstrap_steps() {
    bootstrap_mode="post"
    ecs_agent_may_be_active="true"
    resolve_bundle
    verify_bundle_checksums
    wait_for_cluster_registration
    wait_for_api_readiness
    configure_origin
    enable_renewal_timer
    record_serving_ready_marker
    report_continue
    hand_over_promotion
}

main() {
    (( $# == 1 )) || fail "Usage: bootstrap-spot-host.sh pre|post"
    local mode="$1"
    case "$mode" in
        pre | post) ;;
        *) fail "Unknown phase: $mode (expected pre or post)." ;;
    esac
    # Set before the checks below so a post-phase input failure is reported as
    # ABANDON too, rather than left to the hook's timeout.
    bootstrap_mode="$mode"

    validate_platform
    validate_inputs
    if [[ "$mode" == "pre" ]]; then
        run_pre_bootstrap_steps
    else
        run_post_bootstrap_steps
    fi
}

# Sourcing exposes the contract functions to the test suite without running a
# bootstrap. The same guard is used by deploy-api.sh and renew-origin-cert.sh.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
