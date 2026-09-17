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

verify_bundle_checksums() {
    local manifest="${SPOT_BUNDLE_SHA256_FILE:-$script_directory/bundle.sha256}"

    [[ -f "$manifest" ]] ||
        fail "The runtime bundle checksum manifest is missing: $manifest"

    log "Verifying the runtime bundle against $manifest."
    ( cd -- "$script_directory" && sha256sum --check --status -- "$manifest" ) ||
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

    # Instance role only. Any inherited static credential is cleared so the
    # helper cannot fall back to one.
    env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN \
        -u AWS_SECURITY_TOKEN -u AWS_PROFILE -u AWS_DEFAULT_PROFILE \
        -u AWS_CREDENTIAL_FILE -u AWS_SHARED_CREDENTIALS_FILE -u AWS_CONFIG_FILE \
        ORIGIN_TLS_BUCKET="$ORIGIN_TLS_BUCKET" "$SYNC_TARGET" restore ||
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

    bash -c 'source "$1"; verify_global_certbot_config_contract' _ "$RENEW_TARGET" ||
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
}

wait_for_cluster_registration() {
    local attempt
    log "Waiting for ECS cluster registration."
    for ((attempt = 1; attempt <= REGISTRATION_ATTEMPTS; attempt++)); do
        if curl --disable --silent --fail --max-time 3 http://localhost:51678/v1/metadata 2>/dev/null |
            grep -Fq '"Cluster"'; then
            log "The ECS agent is registered."
            return 0
        fi
        sleep "$REGISTRATION_INTERVAL_SECONDS"
    done
    fail "The ECS agent did not register with the cluster within the configured budget."
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
    # env rather than a command prefix: ORIGIN_SERVER_NAME is readonly here, and
    # a prefix assignment to a readonly name is an error in bash.
    env ORIGIN_SERVER_NAME="$ORIGIN_SERVER_NAME" \
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
