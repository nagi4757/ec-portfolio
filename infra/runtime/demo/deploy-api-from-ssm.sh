#!/usr/bin/env bash

# Resolves the Demo API deployment contract from Systems Manager Parameter Store
# and hands it to the reviewed deploy-api.sh. It never reads an application
# secret: deploy-api.sh decrypts the database password and the JWT signing
# secret itself with the EC2 instance role.

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

readonly EXPECTED_REGION="ap-northeast-1"
readonly ECR_REPOSITORY_NAME="ec-portfolio-demo-api"
readonly API_CONTAINER="ec-portfolio-demo-api"
readonly READINESS_URL="http://127.0.0.1:8080/actuator/health/readiness"
readonly READINESS_ATTEMPTS=3
readonly READINESS_INTERVAL_SECONDS=2

# SSM Run Command can deliver a second invocation while the first is still
# swapping containers, and two concurrent deploy-api.sh runs would race on the
# same container names and on the rollback reference. The lock is taken without
# waiting: a second deployment fails closed rather than queueing behind a run
# whose outcome it cannot observe.
readonly DEFAULT_DEPLOY_LOCK_FILE="/var/lock/ec-portfolio-demo-deploy.lock"
readonly DEPLOY_LOCK_FD=9

readonly DESIRED_IMAGE_SHA_PARAMETER="/ec-portfolio/demo/deploy/desired-image-sha"
readonly LAST_KNOWN_GOOD_IMAGE_SHA_PARAMETER="/ec-portfolio/demo/deploy/last-known-good-image-sha"
readonly RUNTIME_DB_HOST_PARAMETER="/ec-portfolio/demo/runtime/db-host"
readonly RUNTIME_DB_PORT_PARAMETER="/ec-portfolio/demo/runtime/db-port"
readonly RUNTIME_DB_NAME_PARAMETER="/ec-portfolio/demo/runtime/db-name"
readonly RUNTIME_DB_USERNAME_PARAMETER="/ec-portfolio/demo/runtime/db-username"
readonly RUNTIME_CORS_PARAMETER="/ec-portfolio/demo/runtime/cors-allowed-origins"

readonly SHA_PATTERN='^[0-9a-f]{40}$'
readonly ACCOUNT_PATTERN='^[0-9]{12}$'
readonly DB_HOST_PATTERN='^[A-Za-z0-9.-]{1,255}$'
readonly DB_PORT_PATTERN='^[0-9]{1,5}$'
readonly DB_IDENTIFIER_PATTERN='^[A-Za-z0-9_]{1,64}$'
readonly CORS_PATTERN='^https?://[A-Za-z0-9.:-]+(,https?://[A-Za-z0-9.:-]+)*$'

desired_image_sha=""
image_reference=""
account_id=""
db_host=""
db_port=""
db_name=""
db_username=""
cors_allowed_origins=""

log() {
    printf '[deploy-from-ssm] %s\n' "$*"
}

fail() {
    printf '[deploy-from-ssm] ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command is not available: $1"
}

# Serialises every state changing path on this host, including the reconcile
# only path: that one still writes the rollback reference, so it must not run
# beside a deployment that is about to advance it.
acquire_deployment_lock() {
    local lock_file="${DEPLOY_LOCK_FILE:-$DEFAULT_DEPLOY_LOCK_FILE}"

    # A fixed descriptor keeps this working on bash 3.2 as well. The descriptor
    # is held for the lifetime of the process, so the lock is released by the
    # kernel on exit however this script terminates.
    exec 9>"$lock_file" ||
        fail "Unable to open the deployment lock file: $lock_file"

    flock --nonblock "$DEPLOY_LOCK_FD" ||
        fail "Another deployment is already running on this host (lock: $lock_file). Refusing to run concurrently."
}

read_parameter() {
    local parameter_name="$1"

    AWS_PAGER="" aws ssm get-parameter \
        --region "$EXPECTED_REGION" \
        --name "$parameter_name" \
        --query 'Parameter.Value' \
        --output text
}

read_required_parameter() {
    local parameter_name="$1"
    local value

    value="$(read_parameter "$parameter_name")" ||
        fail "Unable to read $parameter_name."
    [[ -n "$value" && "$value" != "None" ]] ||
        fail "$parameter_name returned no value."
    printf '%s' "$value"
}

validate_value() {
    local description="$1"
    local pattern="$2"
    local value="$3"

    [[ "$value" =~ $pattern ]] ||
        fail "$description does not match the expected format."
}

resolve_desired_image() {
    desired_image_sha="$(read_required_parameter "$DESIRED_IMAGE_SHA_PARAMETER")"
    validate_value "The desired image SHA" "$SHA_PATTERN" "$desired_image_sha"

    account_id="$(
        AWS_PAGER="" aws sts get-caller-identity \
            --region "$EXPECTED_REGION" \
            --query 'Account' \
            --output text
    )" || fail "Unable to resolve the AWS account for the ECR reference."
    validate_value "The resolved AWS account id" "$ACCOUNT_PATTERN" "$account_id"

    # The tag is a validated 40 character Git SHA, so a mutable tag such as the
    # rolling one this project forbids can never be built here.
    image_reference="${account_id}.dkr.ecr.${EXPECTED_REGION}.amazonaws.com/${ECR_REPOSITORY_NAME}:${desired_image_sha}"
    log "Desired image reference resolved for $desired_image_sha."
}

container_exists() {
    docker container inspect "$API_CONTAINER" >/dev/null 2>&1
}

container_is_running() {
    [[ "$(docker inspect --format '{{.State.Running}}' "$API_CONTAINER" 2>/dev/null || true)" == "true" ]]
}

running_image_tag() {
    local running_reference

    running_reference="$(docker inspect --format '{{.Config.Image}}' "$API_CONTAINER" 2>/dev/null || true)"
    printf '%s' "${running_reference##*:}"
}

readiness_is_up() {
    local attempt
    local response

    for ((attempt = 1; attempt <= READINESS_ATTEMPTS; attempt++)); do
        if response="$(curl --fail --silent --show-error --max-time 3 "$READINESS_URL" 2>/dev/null)" &&
            printf '%s' "$response" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"UP"'; then
            return 0
        fi
        sleep "$READINESS_INTERVAL_SECONDS"
    done

    return 1
}

# Returns 0 when the host already runs the desired release and is healthy, so
# the deployment can be skipped. An unhealthy host on the desired release is a
# fail-closed condition rather than an automatic redeployment.
converged_already() {
    local current_tag

    container_exists || return 1

    current_tag="$(running_image_tag)"
    [[ "$current_tag" == "$desired_image_sha" ]] || return 1

    if ! container_is_running; then
        fail "The API container already uses $desired_image_sha but is not running. Investigate before redeploying."
    fi
    if ! readiness_is_up; then
        fail "The API container already uses $desired_image_sha but is not ready. Investigate before redeploying."
    fi

    return 0
}

load_runtime_configuration() {
    log "Reading the non-secret runtime configuration."

    db_host="$(read_required_parameter "$RUNTIME_DB_HOST_PARAMETER")"
    db_port="$(read_required_parameter "$RUNTIME_DB_PORT_PARAMETER")"
    db_name="$(read_required_parameter "$RUNTIME_DB_NAME_PARAMETER")"
    db_username="$(read_required_parameter "$RUNTIME_DB_USERNAME_PARAMETER")"
    cors_allowed_origins="$(read_required_parameter "$RUNTIME_CORS_PARAMETER")"

    validate_value "The database host" "$DB_HOST_PATTERN" "$db_host"
    validate_value "The database port" "$DB_PORT_PATTERN" "$db_port"
    validate_value "The database name" "$DB_IDENTIFIER_PATTERN" "$db_name"
    validate_value "The database username" "$DB_IDENTIFIER_PATTERN" "$db_username"
    validate_value "The CORS allowlist" "$CORS_PATTERN" "$cors_allowed_origins"

    (( 10#$db_port >= 1 && 10#$db_port <= 65535 )) ||
        fail "The database port must be between 1 and 65535."
}

run_deployment() {
    local deploy_script="${DEPLOY_API_SCRIPT:-$SCRIPT_DIRECTORY/deploy-api.sh}"
    local status=0

    [[ -x "$deploy_script" ]] ||
        fail "The reviewed deployment script is missing or not executable: $deploy_script"

    log "Deploying $desired_image_sha through $deploy_script."
    IMAGE_REF="$image_reference" \
        DB_HOST="$db_host" \
        DB_PORT="$db_port" \
        DB_NAME="$db_name" \
        DB_USERNAME="$db_username" \
        APP_CORS_ALLOWED_ORIGINS="$cors_allowed_origins" \
        "$deploy_script" || status=$?

    if (( status != 0 )); then
        printf '[deploy-from-ssm] ERROR: %s\n' \
            "deploy-api.sh failed with exit code $status." >&2
        printf '[deploy-from-ssm] ERROR: %s\n' \
            "The last known good image SHA is left unchanged." >&2
        exit "$status"
    fi
}

record_last_known_good() {
    log "Recording $desired_image_sha as the last known good image."
    AWS_PAGER="" aws ssm put-parameter \
        --region "$EXPECTED_REGION" \
        --name "$LAST_KNOWN_GOOD_IMAGE_SHA_PARAMETER" \
        --value "$desired_image_sha" \
        --type String \
        --overwrite >/dev/null ||
        fail "The deployment succeeded but the last known good image SHA could not be recorded."
}

# A deployment can succeed on the host and still fail to record its result if
# the final PutParameter call does not land. That would leave the host running
# the desired release while the rollback reference still points at the previous
# one, permanently. When the host is already converged and healthy, reconcile
# the recorded value instead of assuming it is correct.
reconcile_last_known_good() {
    local recorded

    recorded="$(read_required_parameter "$LAST_KNOWN_GOOD_IMAGE_SHA_PARAMETER")"
    validate_value "The recorded last known good image SHA" "$SHA_PATTERN" "$recorded"

    if [[ "$recorded" == "$desired_image_sha" ]]; then
        log "The host already runs $desired_image_sha and is ready. Nothing to deploy."
        return 0
    fi

    log "The host already runs $desired_image_sha and passes readiness, but the last known good image is still $recorded."
    record_last_known_good
    log "Deployment state reconciled to $desired_image_sha without redeploying."
}

main() {
    local command_name

    (( $# == 0 )) || fail "Usage: deploy-api-from-ssm.sh"

    for command_name in aws curl docker flock grep; do
        require_command "$command_name"
    done

    acquire_deployment_lock

    resolve_desired_image

    if converged_already; then
        reconcile_last_known_good
        return 0
    fi

    load_runtime_configuration
    run_deployment
    record_last_known_good
    log "Deployment of $desired_image_sha completed and recorded."
}

main "$@"
