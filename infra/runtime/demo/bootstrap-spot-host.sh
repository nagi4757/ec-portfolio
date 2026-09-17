#!/usr/bin/env bash

# Brings a replacement ECS EC2 Spot host from first boot to serving-ready.
#
# The ordering is the contract. A replacement host must restore the origin TLS
# state that Phase 6B stored in S3 rather than ask Let's Encrypt for a new
# certificate: issuing on every replacement would reach the duplicate
# certificate rate limit within days. So the restore happens first, before
# certbot is installed, and there is no path in this script that issues a
# certificate. A restore that fails ends the run.
#
# The ECS agent is held back for the same reason. If it registered at boot, ECS
# would place the API task on a host that has no certificate, no Nginx and no
# renewal timer, and CloudFront would be pointed at it the moment the EIP moved.
# The agent is disabled first and is only enabled after every gate below has
# passed, so a half-built host never joins the cluster.
#
# This script does not associate the Elastic IP. Taking production traffic is a
# separate, deliberate step: a host proves itself here and is promoted later.
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

readonly SYNC_TARGET="${BOOTSTRAP_PREFIX}/usr/local/sbin/ec-portfolio-sync-origin-tls"
readonly RENEW_TARGET="${BOOTSTRAP_PREFIX}/usr/local/sbin/ec-portfolio-renew-origin-cert"
readonly ENV_DIRECTORY="${BOOTSTRAP_PREFIX}/etc/ec-portfolio"
readonly ENV_TARGET="$ENV_DIRECTORY/origin-tls.env"
readonly RENEW_UNIT_TARGET="${BOOTSTRAP_PREFIX}/etc/systemd/system/ec-portfolio-certbot-renew.service"
readonly RENEW_TIMER_TARGET="${BOOTSTRAP_PREFIX}/etc/systemd/system/ec-portfolio-certbot-renew.timer"

# The runtime bundle this host must carry. Checked as a set before any checksum
# is verified: sha256sum --check only validates the entries a manifest happens
# to list, so a manifest that simply omits a file would pass while the file it
# should have covered is whatever was delivered.
readonly REQUIRED_BUNDLE_ARTIFACTS=(
    "sync-origin-tls.sh"
    "renew-origin-cert.sh"
    "configure-origin.sh"
    "origin-smoke-check-ecs.sh"
    "ec-portfolio-certbot-renew.service"
    "ec-portfolio-certbot-renew.timer"
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
readonly TIMEOUT_KILL_AFTER_SECONDS="5s"

# Bounded waits. A replacement that cannot reach these states is a failure to
# report, not something to sit on: the ASG will try again with a new instance.
readonly REGISTRATION_ATTEMPTS="${SPOT_REGISTRATION_ATTEMPTS:-60}"
readonly REGISTRATION_INTERVAL_SECONDS="${SPOT_REGISTRATION_INTERVAL_SECONDS:-5}"
readonly READINESS_ATTEMPTS="${SPOT_READINESS_ATTEMPTS:-60}"
readonly READINESS_INTERVAL_SECONDS="${SPOT_READINESS_INTERVAL_SECONDS:-5}"

script_directory=""

# Cleanup state. The agent is only left running on a host that finished.
ecs_agent_started="false"
bootstrap_committed="false"

log() {
    printf '[spot-bootstrap] %s\n' "$*"
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
    for name in "${AWS_CREDENTIAL_ENV[@]}" "${HELPER_SEAM_ENV[@]}"; do
        clear+=(-u "$name")
    done
    env "${clear[@]}" \
        AWS_REGION="$EXPECTED_AWS_REGION" \
        AWS_DEFAULT_REGION="$EXPECTED_AWS_REGION" \
        "$@"
}

# A failure anywhere before the commit point must leave this host out of the
# cluster. Without this the agent would keep running after a failed
# registration, readiness or smoke gate, and ECS would place work on a host that
# never finished building itself.
#
# Cleanup is best effort and must not change the exit code: the reason the
# bootstrap failed is more useful than a failure to tidy up after it.
#
# This does not by itself cause the instance to be replaced. An unregistered
# host simply receives no work. Making the Auto Scaling group notice and replace
# it needs a lifecycle hook or a health check, which is Phase 6C-3.
cleanup() {
    local exit_code=$?
    trap - EXIT

    if (( exit_code != 0 )) && [[ "$bootstrap_committed" != "true" ]]; then
        rm -f "$SERVING_READY_MARKER" 2>/dev/null || true
        if [[ "$ecs_agent_started" == "true" ]]; then
            printf '[spot-bootstrap] %s\n' \
                "Bootstrap failed after the ECS agent started; taking the host back out of the cluster." >&2
            run_systemctl disable --now ecs >/dev/null 2>&1 || true
        fi
    fi

    exit "$exit_code"
}

trap cleanup EXIT

validate_platform() {
    (( EUID == 0 )) || fail "This script must run as root."
    [[ -r /etc/os-release ]] || fail "Cannot identify the operating system."
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "${ID:-}" == "amzn" && "${VERSION_ID:-}" == 2023* ]] ||
        fail "Amazon Linux 2023 is required."

    local command_name
    for command_name in aws curl dnf grep install mktemp rm sha256sum ss systemctl timeout; do
        require_command "$command_name"
    done
}

validate_inputs() {
    (( $# == 0 )) || fail "This script does not accept arguments."

    [[ -n "${ECS_CLUSTER_NAME:-}" ]] ||
        fail "Required environment variable is missing: ECS_CLUSTER_NAME"
    [[ "$ECS_CLUSTER_NAME" =~ ^[A-Za-z0-9_-]{1,255}$ ]] ||
        fail "ECS_CLUSTER_NAME is not a valid cluster name."

    [[ -n "${ORIGIN_TLS_BUCKET:-}" ]] ||
        fail "Required environment variable is missing: ORIGIN_TLS_BUCKET"
    [[ "$ORIGIN_TLS_BUCKET" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] ||
        fail "ORIGIN_TLS_BUCKET is not a valid bucket name."

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
    for name in sync-origin-tls.sh renew-origin-cert.sh configure-origin.sh \
        origin-smoke-check-ecs.sh ec-portfolio-certbot-renew.service \
        ec-portfolio-certbot-renew.timer; do
        [[ -f "$script_directory/$name" ]] ||
            fail "The runtime bundle is missing $name. This script does not download artifacts."
    done

    for name in sync-origin-tls.sh renew-origin-cert.sh configure-origin.sh origin-smoke-check-ecs.sh; do
        [[ -x "$script_directory/$name" ]] ||
            fail "Bundled script is not executable: $name"
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

    run_systemctl daemon-reload || fail "systemd daemon-reload failed or timed out."
}

# Deliberately separate from installing the units, and deliberately last. The
# timer is Persistent=true, so nothing is lost by starting it at the end, and a
# host that never became ready should not be running renewals against a
# certificate it is not serving.
enable_renewal_timer() {
    log "Enabling the renewal timer."
    run_systemctl enable --now ec-portfolio-certbot-renew.timer ||
        fail "The renewal timer could not be enabled."
}

# Written only once every gate above has passed. Until this file exists the
# agent has no cluster to join, which is what keeps a half-built host out of
# the cluster.
write_ecs_config() {
    log "Writing the ECS agent configuration."
    install -d -o root -g root -m 0755 "$ECS_CONFIG_DIRECTORY" ||
        fail "Unable to create $ECS_CONFIG_DIRECTORY."

    local staged
    staged="$(mktemp)" || fail "Unable to stage the ECS agent configuration."
    {
        printf 'ECS_CLUSTER=%s\n' "$ECS_CLUSTER_NAME"
        printf 'ECS_ENABLE_SPOT_INSTANCE_DRAINING=true\n'
    } >"$staged"
    install -o root -g root -m 0644 "$staged" "$ECS_CONFIG_FILE" ||
        fail "Unable to install $ECS_CONFIG_FILE."
    rm -f "$staged"
}

start_ecs_agent() {
    log "Enabling the ECS agent."
    run_systemctl enable --now ecs || fail "The ECS agent could not be started."
    ecs_agent_started="true"
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
    rm -f "$SERVING_READY_MARKER"
}

# The last action on the success path, and the only place this file is created.
# It lives under /run so a reboot clears it: a host that came back up has not
# re-proven itself and must not be treated as ready.
mark_serving_ready() {
    install -o root -g root -m 0644 /dev/null "$SERVING_READY_MARKER" ||
        fail "Unable to record the serving-ready marker."
    bootstrap_committed="true"
    log "Serving-ready. The Elastic IP is NOT associated by this script."
}

# The ordering that matters, separated from the platform and privilege checks in
# main() so the suite can drive it without being root. Production behaviour is
# unchanged: main() still refuses to run unprivileged or off Amazon Linux 2023.
run_bootstrap_steps() {
    reset_serving_ready_marker
    disable_ecs_agent
    resolve_bundle
    verify_bundle_checksums
    verify_letsencrypt_absent
    restore_origin_tls_state
    install_certbot_packages
    verify_global_certbot_config
    install_renewal_runtime
    write_ecs_config
    start_ecs_agent
    wait_for_cluster_registration
    wait_for_api_readiness
    configure_origin
    enable_renewal_timer
    mark_serving_ready
}

main() {
    validate_platform
    validate_inputs "$@"
    run_bootstrap_steps
}

# Sourcing exposes the contract functions to the test suite without running a
# bootstrap. The same guard is used by deploy-api.sh and renew-origin-cert.sh.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
