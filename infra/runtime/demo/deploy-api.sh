#!/usr/bin/env bash

set -euo pipefail

readonly NETWORK_NAME="ec-portfolio-demo"
readonly API_CONTAINER="ec-portfolio-demo-api"
readonly API_CANDIDATE_CONTAINER="ec-portfolio-demo-api-candidate"
readonly API_ROLLBACK_CONTAINER="ec-portfolio-demo-api-rollback"
readonly VALKEY_CONTAINER="ec-portfolio-demo-valkey"
readonly VALKEY_IMAGE="valkey/valkey:8.1.9-alpine"
readonly DB_PASSWORD_PARAMETER="/ec-portfolio/demo/db/master-password"
readonly JWT_SECRET_PARAMETER="/ec-portfolio/demo/app/auth-jwt-secret"
readonly READINESS_URL="http://127.0.0.1:8080/actuator/health/readiness"
readonly READINESS_ATTEMPTS=36
readonly READINESS_INTERVAL_SECONDS=5
readonly VALKEY_HEALTH_ATTEMPTS=30
readonly VALKEY_HEALTH_INTERVAL_SECONDS=2

runtime_directory=""
runtime_environment_file=""
db_password_value=""
jwt_secret_value=""
ecr_registry=""
ecr_region=""
replacement_started="false"
rollback_pending="false"

log() {
    printf '[deploy] %s\n' "$*"
}

fail() {
    printf '[deploy] ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command is not available: $1"
}

container_exists() {
    docker container inspect "$1" >/dev/null 2>&1
}

container_role() {
    docker container inspect --format '{{ index .Config.Labels "ec-portfolio.role" }}' "$1" 2>/dev/null || true
}

cleanup() {
    local exit_code=$?
    trap - EXIT

    if (( exit_code != 0 )) && [[ "$replacement_started" == "true" ]]; then
        log "Deployment failed after replacement started; removing the failed API container."
        docker rm -f "$API_CONTAINER" >/dev/null 2>&1 || true

        if [[ "$rollback_pending" == "true" ]] && container_exists "$API_ROLLBACK_CONTAINER"; then
            log "Restoring the previous API container."
            docker rename "$API_ROLLBACK_CONTAINER" "$API_CONTAINER" >/dev/null 2>&1 || true
            docker start "$API_CONTAINER" >/dev/null 2>&1 || true
        fi
    fi

    if command -v docker >/dev/null 2>&1 && container_exists "$API_CANDIDATE_CONTAINER"; then
        docker rm -f "$API_CANDIDATE_CONTAINER" >/dev/null 2>&1 || true
    fi

    if [[ -n "$runtime_directory" && "$runtime_directory" == /run/ec-portfolio-demo-deploy.* ]]; then
        rm -rf -- "$runtime_directory"
    fi

    unset db_password_value jwt_secret_value
    exit "$exit_code"
}

trap cleanup EXIT

require_environment() {
    local variable_name="$1"
    local variable_value="${!variable_name-}"
    [[ -n "$variable_value" ]] || fail "Required environment variable is missing: $variable_name"
}

validate_env_file_value() {
    local variable_name="$1"
    local variable_value="$2"

    case "$variable_value" in
        *$'\n'* | *$'\r'*)
            fail "$variable_name must not contain line breaks."
            ;;
    esac
}

validate_inputs() {
    local variable_name
    local db_port_number
    local image_pattern

    (( $# == 0 )) || fail "Secrets and deployment values must be provided through the documented environment variables."
    (( EUID == 0 )) || fail "Run as root with sudo --preserve-env for the required non-secret inputs."

    for variable_name in IMAGE_REF DB_HOST DB_PORT DB_NAME DB_USERNAME APP_CORS_ALLOWED_ORIGINS; do
        require_environment "$variable_name"
        validate_env_file_value "$variable_name" "${!variable_name}"
    done

    [[ "$DB_PORT" =~ ^[0-9]{1,5}$ ]] || fail "DB_PORT must be a numeric TCP port."
    db_port_number=$((10#$DB_PORT))
    (( db_port_number >= 1 && db_port_number <= 65535 )) || fail "DB_PORT must be between 1 and 65535."

    image_pattern='^([0-9]{12}[.]dkr[.]ecr[.]([a-z0-9-]+)[.]amazonaws[.]com)/ec-portfolio-demo-api:([0-9a-f]{40})$'
    [[ "$IMAGE_REF" != *:latest ]] || fail "IMAGE_REF must never use the latest tag."
    if [[ ! "$IMAGE_REF" =~ $image_pattern ]]; then
        fail "IMAGE_REF must be the full Demo ECR reference tagged with a 40-character lowercase Git SHA."
    fi

    ecr_registry="${BASH_REMATCH[1]}"
    ecr_region="${BASH_REMATCH[2]}"
}

validate_prerequisites() {
    local command_name
    local network_contract

    for command_name in aws curl docker grep mktemp rm; do
        require_command "$command_name"
    done

    docker info >/dev/null 2>&1 || fail "Docker daemon is not available."
    docker network inspect "$NETWORK_NAME" >/dev/null 2>&1 ||
        fail "Docker network $NETWORK_NAME is missing. Run bootstrap-host.sh first."
    network_contract="$(docker network inspect --format '{{.Driver}}|{{.Scope}}|{{.Internal}}' "$NETWORK_NAME")"
    [[ "$network_contract" == "bridge|local|false" ]] ||
        fail "Docker network $NETWORK_NAME does not match the required local bridge contract."

    if container_exists "$API_ROLLBACK_CONTAINER"; then
        fail "A rollback container already exists. Inspect it before another deployment."
    fi

    if container_exists "$API_CANDIDATE_CONTAINER" &&
        [[ "$(container_role "$API_CANDIDATE_CONTAINER")" != "api-candidate" ]]; then
        fail "The candidate container name is owned by an unmanaged container."
    fi

    if container_exists "$API_CONTAINER" && [[ "$(container_role "$API_CONTAINER")" != "api" ]]; then
        fail "The API container name is owned by an unmanaged container."
    fi
}

login_and_pull_api_image() {
    log "Authenticating the host Docker client to ECR."
    if ! AWS_PAGER="" aws ecr get-login-password --region "$ecr_region" |
        docker login --username AWS --password-stdin "$ecr_registry" >/dev/null; then
        fail "ECR login failed."
    fi

    log "Pulling the immutable API image."
    docker pull "$IMAGE_REF" >/dev/null
}

valkey_container_matches_contract() {
    local image_name
    local network_mode
    local published_ports
    local restart_policy
    local role

    image_name="$(docker inspect --format '{{.Config.Image}}' "$VALKEY_CONTAINER")"
    network_mode="$(docker inspect --format '{{.HostConfig.NetworkMode}}' "$VALKEY_CONTAINER")"
    published_ports="$(docker port "$VALKEY_CONTAINER" 2>/dev/null || true)"
    restart_policy="$(docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' "$VALKEY_CONTAINER")"
    role="$(container_role "$VALKEY_CONTAINER")"

    [[ "$image_name" == "$VALKEY_IMAGE" &&
        "$network_mode" == "$NETWORK_NAME" &&
        -z "$published_ports" &&
        "$restart_policy" == "unless-stopped" &&
        "$role" == "valkey" ]]
}

start_valkey_container() {
    docker run --detach \
        --name "$VALKEY_CONTAINER" \
        --network "$NETWORK_NAME" \
        --network-alias valkey \
        --restart unless-stopped \
        --security-opt no-new-privileges:true \
        --label ec-portfolio.runtime=demo \
        --label ec-portfolio.role=valkey \
        --health-cmd 'valkey-cli ping' \
        --health-interval 10s \
        --health-timeout 3s \
        --health-retries 5 \
        --health-start-period 5s \
        "$VALKEY_IMAGE" \
        valkey-server --save '' --appendonly no >/dev/null
}

wait_for_valkey() {
    local attempt
    local health_status

    for ((attempt = 1; attempt <= VALKEY_HEALTH_ATTEMPTS; attempt++)); do
        health_status="$(
            docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
                "$VALKEY_CONTAINER" 2>/dev/null || true
        )"
        if [[ "$health_status" == "healthy" ]]; then
            log "Valkey is healthy on the private Docker network."
            return 0
        fi
        sleep "$VALKEY_HEALTH_INTERVAL_SECONDS"
    done

    fail "Valkey did not become healthy within the bounded timeout."
}

ensure_valkey() {
    log "Pulling the pinned official Valkey image."
    docker pull "$VALKEY_IMAGE" >/dev/null

    if container_exists "$VALKEY_CONTAINER"; then
        if valkey_container_matches_contract; then
            if [[ "$(docker inspect --format '{{.State.Running}}' "$VALKEY_CONTAINER")" != "true" ]]; then
                log "Starting the existing managed Valkey container."
                docker start "$VALKEY_CONTAINER" >/dev/null
            fi
        else
            log "Replacing the Valkey container to restore the runtime contract."
            docker rm -f "$VALKEY_CONTAINER" >/dev/null
            start_valkey_container
        fi
    else
        log "Starting the managed Valkey container."
        start_valkey_container
    fi

    wait_for_valkey
}

read_secure_parameter() {
    local parameter_name="$1"

    AWS_PAGER="" aws ssm get-parameter \
        --region "$ecr_region" \
        --name "$parameter_name" \
        --with-decryption \
        --query 'Parameter.Value' \
        --output text
}

load_secrets() {
    log "Reading the approved SecureString parameters with the EC2 instance role."
    db_password_value="$(read_secure_parameter "$DB_PASSWORD_PARAMETER")"
    jwt_secret_value="$(read_secure_parameter "$JWT_SECRET_PARAMETER")"

    [[ -n "$db_password_value" && "$db_password_value" != "None" ]] ||
        fail "The database password parameter returned no value."
    [[ -n "$jwt_secret_value" && "$jwt_secret_value" != "None" ]] ||
        fail "The JWT secret parameter returned no value."

    validate_env_file_value DB_PASSWORD "$db_password_value"
    validate_env_file_value APP_AUTH_JWT_SECRET "$jwt_secret_value"
}

write_runtime_environment() {
    umask 077
    runtime_directory="$(mktemp -d /run/ec-portfolio-demo-deploy.XXXXXX)"
    runtime_environment_file="$runtime_directory/api-runtime.env"

    printf '%s\n' \
        'SPRING_PROFILES_ACTIVE=demo' \
        "DB_HOST=$DB_HOST" \
        "DB_PORT=$DB_PORT" \
        "DB_NAME=$DB_NAME" \
        "DB_USERNAME=$DB_USERNAME" \
        "DB_PASSWORD=$db_password_value" \
        'REDIS_HOST=valkey' \
        'REDIS_PORT=6379' \
        "APP_AUTH_JWT_SECRET=$jwt_secret_value" \
        "APP_CORS_ALLOWED_ORIGINS=$APP_CORS_ALLOWED_ORIGINS" \
        'APP_OPENAPI_ENABLED=false' >"$runtime_environment_file"
}

readiness_response_is_up() {
    grep -Eq '"status"[[:space:]]*:[[:space:]]*"UP"'
}

wait_for_candidate_readiness() {
    local attempt
    local response

    for ((attempt = 1; attempt <= READINESS_ATTEMPTS; attempt++)); do
        if response="$(
            docker exec "$API_CANDIDATE_CONTAINER" \
                curl --fail --silent --show-error --max-time 3 \
                http://127.0.0.1:8080/actuator/health/readiness 2>/dev/null
        )" && printf '%s' "$response" | readiness_response_is_up; then
            log "Candidate API readiness is UP."
            return 0
        fi
        sleep "$READINESS_INTERVAL_SECONDS"
    done

    return 1
}

wait_for_host_readiness() {
    local attempt
    local response

    for ((attempt = 1; attempt <= READINESS_ATTEMPTS; attempt++)); do
        if response="$(curl --fail --silent --show-error --max-time 3 "$READINESS_URL" 2>/dev/null)" &&
            printf '%s' "$response" | readiness_response_is_up; then
            log "Final API readiness is UP on 127.0.0.1:8080."
            return 0
        fi
        sleep "$READINESS_INTERVAL_SECONDS"
    done

    return 1
}

run_api_candidate() {
    if container_exists "$API_CANDIDATE_CONTAINER"; then
        docker rm -f "$API_CANDIDATE_CONTAINER" >/dev/null
    fi

    log "Starting an internal candidate API container without a host port."
    docker run --detach \
        --name "$API_CANDIDATE_CONTAINER" \
        --network "$NETWORK_NAME" \
        --restart no \
        --security-opt no-new-privileges:true \
        --env-file "$runtime_environment_file" \
        --label ec-portfolio.runtime=demo \
        --label ec-portfolio.role=api-candidate \
        "$IMAGE_REF" >/dev/null

    if ! wait_for_candidate_readiness; then
        fail "Candidate API did not become ready within the bounded timeout."
    fi

    docker rm -f "$API_CANDIDATE_CONTAINER" >/dev/null
}

replace_api_container() {
    if container_exists "$API_CONTAINER"; then
        log "Stopping the current API container after candidate verification."
        docker stop --time 30 "$API_CONTAINER" >/dev/null
        docker rename "$API_CONTAINER" "$API_ROLLBACK_CONTAINER"
        rollback_pending="true"
    fi
    replacement_started="true"

    log "Starting the final API container on loopback only."
    docker run --detach \
        --name "$API_CONTAINER" \
        --network "$NETWORK_NAME" \
        --publish 127.0.0.1:8080:8080 \
        --restart unless-stopped \
        --security-opt no-new-privileges:true \
        --env-file "$runtime_environment_file" \
        --label ec-portfolio.runtime=demo \
        --label ec-portfolio.role=api \
        "$IMAGE_REF" >/dev/null

    if ! wait_for_host_readiness; then
        fail "Final API did not become ready within the bounded timeout."
    fi

    if [[ "$rollback_pending" == "true" ]]; then
        docker rm "$API_ROLLBACK_CONTAINER" >/dev/null
        rollback_pending="false"
    fi
    replacement_started="false"
}

main() {
    validate_inputs "$@"
    validate_prerequisites
    login_and_pull_api_image
    ensure_valkey
    load_secrets
    write_runtime_environment
    run_api_candidate
    replace_api_container
    log "Demo API deployment completed successfully."
}

main "$@"
