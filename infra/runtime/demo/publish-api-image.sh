#!/usr/bin/env bash

set -euo pipefail

readonly EXPECTED_REGION="ap-northeast-1"
readonly EXPECTED_REPOSITORY="ec-portfolio-demo-api"
readonly DIGEST_PATTERN='^sha256:[0-9a-f]{64}$'
readonly EXPECTED_IMAGE_USER="10001:10001"
readonly EXPECTED_IMAGE_ENTRYPOINT='["java","-jar","/app/app.jar"]'
readonly EXPECTED_IMAGE_PORTS='{"8080/tcp":{}}'
readonly RDS_CA_BUNDLE_PATH="/etc/ssl/certs/aws-rds-ap-northeast-1-bundle.pem"
readonly SECRET_CONFIGURATION_PATTERN='DB_PASSWORD|REDIS_PASSWORD|APP_AUTH_JWT_SECRET'

runtime_directory=""
ecr_registry=""
image_reference=""
image_digest=""
ecr_login_succeeded="false"

log() {
    printf '[api-publish] %s\n' "$*"
}

fail() {
    printf '[api-publish] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local exit_code=$?
    trap - EXIT

    if [[ "$ecr_login_succeeded" == "true" && -n "$ecr_registry" ]]; then
        docker logout "$ecr_registry" >/dev/null 2>&1 || true
    fi
    if [[ -n "$runtime_directory" && "$runtime_directory" == /tmp/ec-portfolio-api-publish.* ]]; then
        rm -rf -- "$runtime_directory"
    fi

    exit "$exit_code"
}

trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command is not available: $1"
}

require_environment() {
    local variable_name="$1"
    [[ -n "${!variable_name-}" ]] || fail "Required environment variable is missing: $variable_name"
}

validate_parameter_name() {
    local variable_name="$1"
    local parameter_name="${!variable_name}"

    [[ "$parameter_name" =~ ^/ec-portfolio/demo/deploy/[a-z-]+$ ]] ||
        fail "$variable_name is not a Demo deployment-state parameter: $parameter_name"
}

validate_common_inputs() {
    local variable_name

    for variable_name in AWS_REGION AWS_ACCOUNT_ID ECR_REPOSITORY_NAME IMAGE_TAG; do
        require_environment "$variable_name"
    done

    [[ "$AWS_REGION" == "$EXPECTED_REGION" ]] || fail "AWS_REGION must be $EXPECTED_REGION."
    [[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]] || fail "AWS_ACCOUNT_ID must be twelve digits."
    [[ "$ECR_REPOSITORY_NAME" == "$EXPECTED_REPOSITORY" ]] ||
        fail "ECR_REPOSITORY_NAME must be $EXPECTED_REPOSITORY."
    [[ "$IMAGE_TAG" =~ ^[0-9a-f]{40}$ ]] ||
        fail "IMAGE_TAG must be a full lowercase Git SHA."

    ecr_registry="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
    image_reference="${ecr_registry}/${ECR_REPOSITORY_NAME}:${IMAGE_TAG}"
}

# Sets the global image_digest and returns 0 when the immutable tag exists, or
# returns 1 when the repository reports it missing. Any other failure stops the
# script, so it must not run inside a command substitution subshell.
inspect_published_image() {
    local error_file="$runtime_directory/describe.error"
    local status=0

    image_digest=""
    image_digest="$(
        AWS_PAGER="" aws ecr describe-images \
            --region "$AWS_REGION" \
            --repository-name "$ECR_REPOSITORY_NAME" \
            --image-ids "imageTag=$IMAGE_TAG" \
            --query 'imageDetails[0].imageDigest' \
            --output text 2>"$error_file"
    )" || status=$?

    if (( status == 0 )); then
        [[ "$image_digest" =~ $DIGEST_PATTERN ]] ||
            fail "Unexpected describe-images digest for tag $IMAGE_TAG."
        return 0
    fi

    image_digest=""
    if grep -q 'ImageNotFoundException' "$error_file"; then
        return 1
    fi

    fail "Unable to inspect the API repository for tag $IMAGE_TAG."
}

login_to_ecr() {
    log "Authenticating the build runner to ECR."
    AWS_PAGER="" aws ecr get-login-password --region "$AWS_REGION" |
        docker login --username AWS --password-stdin "$ecr_registry" >/dev/null ||
        fail "ECR login failed."
    ecr_login_succeeded="true"
}

build_and_push_image() {
    local error_file="$runtime_directory/push.error"

    require_environment BUILD_CONTEXT
    [[ -f "$BUILD_CONTEXT/Dockerfile" ]] || fail "BUILD_CONTEXT has no Dockerfile: $BUILD_CONTEXT"

    log "Building the production API image for $IMAGE_TAG."
    docker build --tag "$image_reference" "$BUILD_CONTEXT" >/dev/null ||
        fail "Production image build failed."

    verify_built_image

    login_to_ecr

    log "Pushing the immutable API image."
    if docker push "$image_reference" >/dev/null 2>"$error_file"; then
        return 0
    fi

    if ! grep -Eq 'ImageTagAlreadyExistsException|cannot be overwritten' "$error_file"; then
        fail "Immutable image push failed for tag $IMAGE_TAG."
    fi

    log "Push rejected because the immutable tag already exists; re-inspecting the repository."
    inspect_published_image ||
        fail "Push was rejected as an existing tag, but the tag is not present."
    log "Reusing the existing image for $IMAGE_TAG."
}

# Re-asserts the production image contract on the exact artifact that is about
# to be pushed. The CI docker job verifies its own local build, so this repeats
# the same core assertions against the tagged image the registry will receive.
verify_built_image() {
    local inspected

    log "Verifying the built image against the production contract."

    inspected="$(docker image inspect --format '{{.Config.User}}' "$image_reference")"
    [[ "$inspected" == "$EXPECTED_IMAGE_USER" ]] ||
        fail "Image must run as the non-root user $EXPECTED_IMAGE_USER."

    inspected="$(docker image inspect --format '{{json .Config.Entrypoint}}' "$image_reference")"
    [[ "$inspected" == "$EXPECTED_IMAGE_ENTRYPOINT" ]] ||
        fail "Image entrypoint does not match the production contract."

    inspected="$(docker image inspect --format '{{json .Config.ExposedPorts}}' "$image_reference")"
    [[ "$inspected" == "$EXPECTED_IMAGE_PORTS" ]] ||
        fail "Image must expose exactly 8080/tcp."

    if docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$image_reference" |
        grep -Eq "$SECRET_CONFIGURATION_PATTERN"; then
        fail "Image environment must not carry runtime secret configuration."
    fi

    if docker history --no-trunc --format '{{.CreatedBy}}' "$image_reference" |
        grep -Eq "$SECRET_CONFIGURATION_PATTERN"; then
        fail "Image history must not carry runtime secret configuration."
    fi

    docker run --rm --entrypoint sh "$image_reference" -c '
        set -eu
        ca_file="$1"
        test -f /app/app.jar
        test "$(find /app -mindepth 1 -maxdepth 1 | wc -l)" -eq 1
        test -s "$ca_file"
        test -r "$ca_file"
        test "$(stat -c %a "$ca_file")" = "444"
        test "$(stat -c %u:%g "$ca_file")" = "0:0"
        grep -q "^-----BEGIN CERTIFICATE-----$" "$ca_file"
        ! grep -Eq "^-----BEGIN .*PRIVATE KEY-----$" "$ca_file"
    ' verify-image-contents "$RDS_CA_BUNDLE_PATH" >/dev/null ||
        fail "Image contents do not match the production contract."

    log "Image contract verified for $IMAGE_TAG."
}

ensure_image() {
    if inspect_published_image; then
        log "Image already published for $IMAGE_TAG; skipping build and push."
        log "Digest: $image_digest"
        return 0
    fi

    log "No image is published for $IMAGE_TAG yet."
    build_and_push_image
}

read_state_parameter() {
    local parameter_name="$1"

    AWS_PAGER="" aws ssm get-parameter \
        --region "$AWS_REGION" \
        --name "$parameter_name" \
        --query 'Parameter.Value' \
        --output text
}

write_state_parameter() {
    local parameter_name="$1"
    local parameter_value="$2"

    AWS_PAGER="" aws ssm put-parameter \
        --region "$AWS_REGION" \
        --name "$parameter_name" \
        --value "$parameter_value" \
        --type String \
        --overwrite >/dev/null ||
        fail "Unable to record deployment state in $parameter_name."
}

migration_guard() {
    local last_known_good
    local changed_migrations

    require_environment MIGRATION_PATH
    require_environment LAST_KNOWN_GOOD_IMAGE_SHA_PARAMETER
    require_environment PENDING_MIGRATION_IMAGE_SHA_PARAMETER
    validate_parameter_name LAST_KNOWN_GOOD_IMAGE_SHA_PARAMETER
    validate_parameter_name PENDING_MIGRATION_IMAGE_SHA_PARAMETER
    [[ -d "$MIGRATION_PATH" ]] || fail "Migration directory is missing: $MIGRATION_PATH"

    last_known_good="$(read_state_parameter "$LAST_KNOWN_GOOD_IMAGE_SHA_PARAMETER")" ||
        fail "Unable to read the last known good image SHA."
    [[ "$last_known_good" =~ ^[0-9a-f]{40}$ ]] ||
        fail "The last known good image SHA is not a full lowercase Git SHA."

    git rev-parse --verify --quiet "${last_known_good}^{commit}" >/dev/null ||
        fail "The last known good commit $last_known_good is not present. Fetch the full history."
    git rev-parse --verify --quiet "${IMAGE_TAG}^{commit}" >/dev/null ||
        fail "The release commit $IMAGE_TAG is not present."

    changed_migrations="$(
        git diff --name-only "$last_known_good" "$IMAGE_TAG" -- "$MIGRATION_PATH"
    )" || fail "Unable to compare migrations between $last_known_good and $IMAGE_TAG."

    if [[ -z "$changed_migrations" ]]; then
        log "No Flyway migration change between $last_known_good and $IMAGE_TAG."
        return 0
    fi

    write_state_parameter "$PENDING_MIGRATION_IMAGE_SHA_PARAMETER" "$IMAGE_TAG"

    printf '[api-publish] ERROR: %s\n' \
        "Flyway migration change detected between $last_known_good and $IMAGE_TAG." >&2
    printf '%s\n' "$changed_migrations" | sed 's/^/[api-publish]   changed: /' >&2
    printf '[api-publish] ERROR: %s\n' \
        "Automatic backend deployment is blocked. A manual migration release is required:" >&2
    printf '[api-publish] ERROR: %s\n' \
        "  1. Review the migration for backward compatibility." >&2
    printf '[api-publish] ERROR: %s\n' \
        "  2. Take an RDS snapshot and deploy the reviewed image manually." >&2
    printf '[api-publish] ERROR: %s\n' \
        "  3. Update the desired and last known good image parameters after verification." >&2
    printf '[api-publish] ERROR: %s\n' \
        "The image for $IMAGE_TAG is preserved in ECR and the desired image SHA is unchanged." >&2
    exit 1
}

record_desired() {
    require_environment DESIRED_IMAGE_SHA_PARAMETER
    require_environment PENDING_MIGRATION_IMAGE_SHA_PARAMETER
    validate_parameter_name DESIRED_IMAGE_SHA_PARAMETER
    validate_parameter_name PENDING_MIGRATION_IMAGE_SHA_PARAMETER

    log "Recording $IMAGE_TAG as the desired API image."
    write_state_parameter "$DESIRED_IMAGE_SHA_PARAMETER" "$IMAGE_TAG"
    write_state_parameter "$PENDING_MIGRATION_IMAGE_SHA_PARAMETER" "none"
}

main() {
    local mode="${1-}"
    local command_name

    (( $# == 1 )) || fail "Usage: publish-api-image.sh ensure-image|migration-guard|record-desired"
    case "$mode" in
        ensure-image | migration-guard | record-desired) ;;
        *) fail "Usage: publish-api-image.sh ensure-image|migration-guard|record-desired" ;;
    esac

    for command_name in aws grep mktemp rm sed; do
        require_command "$command_name"
    done
    [[ "$mode" != "ensure-image" ]] || require_command docker
    [[ "$mode" != "migration-guard" ]] || require_command git

    validate_common_inputs

    umask 077
    runtime_directory="$(mktemp -d /tmp/ec-portfolio-api-publish.XXXXXX)"

    case "$mode" in
        ensure-image) ensure_image ;;
        migration-guard) migration_guard ;;
        record-desired) record_desired ;;
    esac

    log "Completed $mode for $IMAGE_TAG."
}

main "$@"
