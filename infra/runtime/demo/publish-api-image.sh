#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

readonly EXPECTED_REGION="ap-northeast-1"
readonly EXPECTED_REPOSITORY="ec-portfolio-demo-api"
readonly DIGEST_PATTERN='^sha256:[0-9a-f]{64}$'
readonly EXPECTED_IMAGE_USER="10001:10001"
readonly EXPECTED_IMAGE_ENTRYPOINT='["java","-jar","/app/app.jar"]'
readonly EXPECTED_IMAGE_PORTS='{"8080/tcp":{}}'
readonly RDS_CA_BUNDLE_PATH="/etc/ssl/certs/aws-rds-ap-northeast-1-bundle.pem"
readonly SECRET_CONFIGURATION_PATTERN='DB_PASSWORD|REDIS_PASSWORD|APP_AUTH_JWT_SECRET'
readonly FLYWAY_PROPERTIES_PATH="apps/api/src/main/resources/application.properties"
readonly FLYWAY_RESOURCES_PATH="apps/api/src/main/resources"
readonly FLYWAY_BUILD_FILE="apps/api/build.gradle.kts"
readonly FLYWAY_ENABLED_LINE="spring.flyway.enabled=true"
readonly FLYWAY_LOCATIONS_LINE="spring.flyway.locations=classpath:db/migration"
readonly FLYWAY_CONFIGURATION_PATTERN='spring[.]flyway[.]|org[.]flywaydb|flyway-core|flyway-mysql'

# Where the host runtime artifacts live in the repository. deploy-runtime.sh
# owns their names; release-scope reads them from it instead of restating them.
readonly RUNTIME_SOURCE_PATH="infra/runtime/demo"
readonly DEPLOY_RUNTIME_SCRIPT="$SCRIPT_DIRECTORY/deploy-runtime.sh"

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
    local tag="${1:-$IMAGE_TAG}"
    local error_file="$runtime_directory/describe.error"
    local status=0

    image_digest=""
    image_digest="$(
        AWS_PAGER="" aws ecr describe-images \
            --region "$AWS_REGION" \
            --repository-name "$ECR_REPOSITORY_NAME" \
            --image-ids "imageTag=$tag" \
            --query 'imageDetails[0].imageDigest' \
            --output text 2>"$error_file"
    )" || status=$?

    if (( status == 0 )); then
        [[ "$image_digest" =~ $DIGEST_PATTERN ]] ||
            fail "Unexpected describe-images digest for tag $tag."
        return 0
    fi

    image_digest=""
    if grep -q 'ImageNotFoundException' "$error_file"; then
        return 1
    fi

    fail "Unable to inspect the API repository for tag $tag."
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

# write_state_parameter <name> <value> [failure message]
write_state_parameter() {
    local parameter_name="$1"
    local parameter_value="$2"
    local failure_message="${3:-Unable to record deployment state in $parameter_name.}"

    AWS_PAGER="" aws ssm put-parameter \
        --region "$AWS_REGION" \
        --name "$parameter_name" \
        --value "$parameter_value" \
        --type String \
        --overwrite >/dev/null ||
        fail "$failure_message"
}

migration_guard() {
    local last_known_good
    local changed_migrations
    local configuration_diff
    local changed_configuration
    local configured_locations
    local release_properties
    local block_reasons=""

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

    # 1. Migration files themselves.
    changed_migrations="$(
        git diff --name-only "$last_known_good" "$IMAGE_TAG" -- "$MIGRATION_PATH"
    )" || fail "Unable to compare migrations between $last_known_good and $IMAGE_TAG."
    [[ -z "$changed_migrations" ]] ||
        block_reasons+="Flyway migration files changed."$'\n'

    # 2. Flyway configuration or dependency lines anywhere in the API resources
    #    and build file, so the gate cannot be bypassed by repointing Flyway.
    configuration_diff="$(
        git diff -U0 "$last_known_good" "$IMAGE_TAG" \
            -- "$FLYWAY_RESOURCES_PATH" "$FLYWAY_BUILD_FILE"
    )" || fail "Unable to compare Flyway configuration between $last_known_good and $IMAGE_TAG."
    changed_configuration="$(
        printf '%s\n' "$configuration_diff" |
            grep -E "^[+-][^+-].*($FLYWAY_CONFIGURATION_PATTERN)" || true
    )"
    [[ -z "$changed_configuration" ]] ||
        block_reasons+="Flyway configuration or dependency changed."$'\n'

    # 3. Invariants that must still hold in the release commit.
    release_properties="$(git show "$IMAGE_TAG:$FLYWAY_PROPERTIES_PATH")" ||
        fail "The release commit does not contain $FLYWAY_PROPERTIES_PATH."
    printf '%s\n' "$release_properties" | grep -qxF "$FLYWAY_ENABLED_LINE" ||
        block_reasons+="$FLYWAY_ENABLED_LINE is no longer declared."$'\n'
    printf '%s\n' "$release_properties" | grep -qxF "$FLYWAY_LOCATIONS_LINE" ||
        block_reasons+="$FLYWAY_LOCATIONS_LINE is no longer declared."$'\n'

    # 4. Flyway must stay configured in exactly one file.
    configured_locations="$(
        git grep -l -E 'spring[.]flyway[.]' "$IMAGE_TAG" -- "$FLYWAY_RESOURCES_PATH" || true
    )"
    configured_locations="$(
        printf '%s' "$configured_locations" | sed "s|^$IMAGE_TAG:||" |
            LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//'
    )"
    [[ "$configured_locations" == "$FLYWAY_PROPERTIES_PATH" ]] ||
        block_reasons+="Flyway is configured outside $FLYWAY_PROPERTIES_PATH."$'\n'

    if [[ -z "$block_reasons" ]]; then
        log "No Flyway migration, configuration, or dependency change between $last_known_good and $IMAGE_TAG."
        return 0
    fi

    write_state_parameter "$PENDING_MIGRATION_IMAGE_SHA_PARAMETER" "$IMAGE_TAG"

    printf '[api-publish] ERROR: %s\n' \
        "Flyway migration change detected between $last_known_good and $IMAGE_TAG." >&2
    printf '%s' "$block_reasons" | sed 's/^/[api-publish]   reason: /' >&2
    if [[ -n "$changed_migrations" ]]; then
        printf '%s\n' "$changed_migrations" | sed 's/^/[api-publish]   changed: /' >&2
    fi
    if [[ -n "$changed_configuration" ]]; then
        printf '%s\n' "$changed_configuration" | sed 's/^/[api-publish]   config: /' >&2
    fi
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

# Refuses to advance the desired image while the recorded rollback target has
# already been expired from ECR by the repository lifecycle policy.
assert_rollback_image() {
    local last_known_good

    require_environment LAST_KNOWN_GOOD_IMAGE_SHA_PARAMETER
    validate_parameter_name LAST_KNOWN_GOOD_IMAGE_SHA_PARAMETER

    last_known_good="$(read_state_parameter "$LAST_KNOWN_GOOD_IMAGE_SHA_PARAMETER")" ||
        fail "Unable to read the last known good image SHA."
    [[ "$last_known_good" =~ ^[0-9a-f]{40}$ ]] ||
        fail "The last known good image SHA is not a full lowercase Git SHA."

    log "Confirming that the rollback image $last_known_good is still published."
    if inspect_published_image "$last_known_good"; then
        log "Rollback image is available. Digest: $image_digest"
        return 0
    fi

    fail "The last known good image $last_known_good is no longer published in ECR, so a rollback would be impossible. The desired image SHA is left unchanged. Restore that image or promote a verified replacement before deploying again."
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

# Writes the desired image SHA and the pending migration image SHA that
# record-desired is about to replace to GITHUB_OUTPUT, as previous_desired and
# previous_pending, so a release that then fails can put them back with
# restore-desired. A value that cannot be read could not be restored, so the
# release stops here, before anything is recorded.
read_desired() {
    local previous_desired previous_pending

    require_environment DESIRED_IMAGE_SHA_PARAMETER
    require_environment PENDING_MIGRATION_IMAGE_SHA_PARAMETER
    require_environment GITHUB_OUTPUT
    validate_parameter_name DESIRED_IMAGE_SHA_PARAMETER
    validate_parameter_name PENDING_MIGRATION_IMAGE_SHA_PARAMETER
    [[ -f "$GITHUB_OUTPUT" && -w "$GITHUB_OUTPUT" ]] || fail "GITHUB_OUTPUT is not a writable file."

    previous_desired="$(read_state_parameter "$DESIRED_IMAGE_SHA_PARAMETER")" ||
        fail "Unable to read the desired image SHA this release would replace."
    [[ "$previous_desired" =~ ^[0-9a-f]{40}$ ]] ||
        fail "The desired image SHA this release would replace is not a full lowercase Git SHA."
    previous_pending="$(read_state_parameter "$PENDING_MIGRATION_IMAGE_SHA_PARAMETER")" ||
        fail "Unable to read the pending migration image SHA this release would replace."
    [[ "$previous_pending" =~ ^([0-9a-f]{40}|none)$ ]] ||
        fail "The pending migration image SHA this release would replace is neither a full lowercase Git SHA nor none."

    log "This release replaces the desired image $previous_desired (pending migration image: $previous_pending)."
    printf 'previous_desired=%s\nprevious_pending=%s\n' "$previous_desired" "$previous_pending" >>"$GITHUB_OUTPUT"
}

# restore_failure_message <reason>: what an operator needs when a restore cannot
# be confirmed. It never says the value was restored.
restore_failure_message() {
    printf '%s' "RESTORE NOT CONFIRMED ($1). $DESIRED_IMAGE_SHA_PARAMETER may still be $IMAGE_TAG, a release this workflow did not complete; before it, it was $PREVIOUS_DESIRED_IMAGE_SHA. Operator: read $DESIRED_IMAGE_SHA_PARAMETER now and, if it is not $PREVIOUS_DESIRED_IMAGE_SHA, set it back to $PREVIOUS_DESIRED_IMAGE_SHA before the host boots again or the next main push runs."
}

# Puts back what record-desired replaced once the release has failed or been
# cancelled, so the host's next boot converges to the image it had before, not to
# a release its workflow did not complete. Only a desired image SHA that still
# names this release is restored: any other value was never recorded by this run
# or has been changed since, and is left alone. A value counts as restored only
# once it is read back: this is best-effort, and a run that never reaches this
# step (a force-cancelled run, a lost runner) restores nothing at all.
restore_desired() {
    local current_desired current_pending

    require_environment DESIRED_IMAGE_SHA_PARAMETER
    require_environment PENDING_MIGRATION_IMAGE_SHA_PARAMETER
    validate_parameter_name DESIRED_IMAGE_SHA_PARAMETER
    validate_parameter_name PENDING_MIGRATION_IMAGE_SHA_PARAMETER
    [[ "${PREVIOUS_DESIRED_IMAGE_SHA-}" =~ ^[0-9a-f]{40}$ ]] ||
        fail "PREVIOUS_DESIRED_IMAGE_SHA must be a full lowercase Git SHA."
    [[ "${PREVIOUS_PENDING_MIGRATION_IMAGE_SHA-}" =~ ^([0-9a-f]{40}|none)$ ]] ||
        fail "PREVIOUS_PENDING_MIGRATION_IMAGE_SHA must be a full lowercase Git SHA or none."

    current_desired="$(read_state_parameter "$DESIRED_IMAGE_SHA_PARAMETER")" ||
        fail "$(restore_failure_message "$DESIRED_IMAGE_SHA_PARAMETER could not be read")"
    if [[ "$current_desired" != "$IMAGE_TAG" ]]; then
        log "The desired image SHA reads $current_desired, not this release's $IMAGE_TAG: nothing to restore."
        return 0
    fi

    write_state_parameter "$DESIRED_IMAGE_SHA_PARAMETER" "$PREVIOUS_DESIRED_IMAGE_SHA" \
        "$(restore_failure_message "the write to $DESIRED_IMAGE_SHA_PARAMETER failed")"
    current_desired="$(read_state_parameter "$DESIRED_IMAGE_SHA_PARAMETER")" ||
        fail "$(restore_failure_message "$DESIRED_IMAGE_SHA_PARAMETER could not be read back after the write")"
    [[ "$current_desired" == "$PREVIOUS_DESIRED_IMAGE_SHA" ]] ||
        fail "$(restore_failure_message "$DESIRED_IMAGE_SHA_PARAMETER reads $current_desired after the write")"
    log "Restored and read back: the desired image SHA is $PREVIOUS_DESIRED_IMAGE_SHA again, not the failed release $IMAGE_TAG."

    write_state_parameter "$PENDING_MIGRATION_IMAGE_SHA_PARAMETER" "$PREVIOUS_PENDING_MIGRATION_IMAGE_SHA" \
        "The desired image SHA is restored and read back, but $PENDING_MIGRATION_IMAGE_SHA_PARAMETER could not be set back to $PREVIOUS_PENDING_MIGRATION_IMAGE_SHA."
    current_pending="$(read_state_parameter "$PENDING_MIGRATION_IMAGE_SHA_PARAMETER")" ||
        fail "The desired image SHA is restored and read back, but $PENDING_MIGRATION_IMAGE_SHA_PARAMETER could not be read back."
    [[ "$current_pending" == "$PREVIOUS_PENDING_MIGRATION_IMAGE_SHA" ]] ||
        fail "The desired image SHA is restored and read back, but $PENDING_MIGRATION_IMAGE_SHA_PARAMETER reads $current_pending, not $PREVIOUS_PENDING_MIGRATION_IMAGE_SHA."
    log "Restored and read back: the pending migration image SHA is $PREVIOUS_PENDING_MIGRATION_IMAGE_SHA again."
}

# read_deployment_sha <parameter variable> <description>: a deployment-state SHA
# that is a full lowercase Git SHA of a commit present in this checkout. Anything
# else stops the script, so the caller never decides on a value it cannot trust.
read_deployment_sha() {
    local variable_name="$1"
    local description="$2"
    local value

    validate_parameter_name "$variable_name"
    value="$(read_state_parameter "${!variable_name}")" ||
        fail "Unable to read the $description."
    [[ "$value" =~ ^[0-9a-f]{40}$ ]] ||
        fail "The $description is not a full lowercase Git SHA."
    git rev-parse --verify --quiet "${value}^{commit}" >/dev/null ||
        fail "The $description $value is not present. Fetch the full history."
    printf '%s' "$value"
}

# changed_between <from> <to> <path>...: prints true when the paths differ
# between the two commits and false when they do not. A git failure is neither
# and stops the script.
changed_between() {
    local from="$1"
    local to="$2"
    local status=0
    shift 2

    git diff --quiet "$from" "$to" -- "$@" || status=$?
    case "$status" in
        0) printf 'false' ;;
        1) printf 'true' ;;
        *) fail "Unable to compare $* between $from and $to." ;;
    esac
}

# touched_since <from> <to> <path>...: prints true when the paths differ between
# the two commits or any commit after <from> up to <to> changed them, false
# otherwise. A change that was later reverted still counts: the host may have
# installed it in between. A git failure stops the script.
touched_since() {
    local from="$1"
    local to="$2"
    local net_change touching_commit
    shift 2

    net_change="$(changed_between "$from" "$to" "$@")" || exit 1
    touching_commit="$(git rev-list -n 1 "$from..$to" -- "$@")" ||
        fail "Unable to list the commits that changed $* between $from and $to."
    if [[ "$net_change" == "true" || -n "$touching_commit" ]]; then
        printf 'true'
    else
        printf 'false'
    fi
}

# The host runtime artifacts deploy-runtime.sh installs, one file name per line.
# Sourcing runs in its own process so that script's readonly globals and helpers
# cannot collide with the ones defined here.
runtime_artifact_files_of_deploy_script() {
    [[ -f "$DEPLOY_RUNTIME_SCRIPT" ]] || fail "The runtime deployment script is missing: $DEPLOY_RUNTIME_SCRIPT"
    bash -c 'source "$1"; runtime_artifact_files' _ "$DEPLOY_RUNTIME_SCRIPT"
}

# Decides, before anything is published or recorded, what this main push has to
# release. Three outputs go to GITHUB_OUTPUT:
#
#   api_changed      the API build context differs between the desired image
#                    and this commit: publish and guard a new image, which
#                    deploy-api then records. false for a push that does not
#                    touch the API (an access, infrastructure or documentation
#                    change), which therefore publishes nothing and leaves the
#                    desired image SHA alone.
#   api_converge     api_changed, or the host has not yet verified the desired
#                    image (the last known good differs): converge the host.
#   runtime_pending  a host runtime artifact was changed after the last known
#                    good image: the host may run other artifacts than this
#                    commit's and needs an install, which compares the host's
#                    copies first. The baseline is what the host last verified,
#                    not this push, so a change whose installation was skipped,
#                    rejected or deferred stays pending until it lands.
#
# The last known good image is a sound runtime baseline because the host never
# starts an image on an older runtime than that image's own: deploy-api records a
# desired image whose runtime changed only after install-runtime has installed
# that runtime, and the host advances the last known good only to the desired
# image. A release made outside this workflow, such as the manual migration
# release, has to keep that rule itself. The host can run a newer runtime,
# though: a runtime-only release
# installs one without publishing an image, so the last known good stays behind
# it. That is why any commit that touched the artifacts counts, not only a net
# difference, or reverting such a change would leave the reverted copy on the
# host unnoticed.
#
# Every read is fail-closed: an unreadable or malformed state parameter, a
# commit missing from the checkout or a git failure stops the job before any
# step that could publish or record anything.
release_scope() {
    local desired last_known_good api_changed api_converge runtime_pending
    local variable_name listing name
    local runtime_paths=()

    require_command git
    for variable_name in BUILD_CONTEXT DESIRED_IMAGE_SHA_PARAMETER LAST_KNOWN_GOOD_IMAGE_SHA_PARAMETER GITHUB_OUTPUT; do
        require_environment "$variable_name"
    done
    [[ -d "$BUILD_CONTEXT" ]] || fail "BUILD_CONTEXT is not a directory: $BUILD_CONTEXT"
    [[ -f "$GITHUB_OUTPUT" && -w "$GITHUB_OUTPUT" ]] || fail "GITHUB_OUTPUT is not a writable file."
    git rev-parse --verify --quiet "${IMAGE_TAG}^{commit}" >/dev/null ||
        fail "The release commit $IMAGE_TAG is not present."

    listing="$(runtime_artifact_files_of_deploy_script)" ||
        fail "Unable to read the host runtime artifacts from $DEPLOY_RUNTIME_SCRIPT."
    while IFS= read -r name; do
        [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || fail "Unexpected host runtime artifact name: $name"
        runtime_paths+=("$RUNTIME_SOURCE_PATH/$name")
    done <<<"$listing"
    ((${#runtime_paths[@]} > 0)) || fail "No host runtime artifact could be resolved."

    desired="$(read_deployment_sha DESIRED_IMAGE_SHA_PARAMETER "desired image SHA")"
    last_known_good="$(read_deployment_sha LAST_KNOWN_GOOD_IMAGE_SHA_PARAMETER "last known good image SHA")"

    api_changed="$(changed_between "$desired" "$IMAGE_TAG" "$BUILD_CONTEXT")"
    runtime_pending="$(touched_since "$last_known_good" "$IMAGE_TAG" "${runtime_paths[@]}")"
    api_converge="$api_changed"
    [[ "$desired" == "$last_known_good" ]] || api_converge="true"

    log "Desired image $desired, last known good $last_known_good, release commit $IMAGE_TAG."
    log "api_changed=$api_changed api_converge=$api_converge runtime_pending=$runtime_pending"
    [[ "$api_changed" == "true" ]] ||
        log "The API build context is unchanged since the desired image: nothing is published and the desired image SHA is left as it is."
    {
        printf 'api_changed=%s\n' "$api_changed"
        printf 'api_converge=%s\n' "$api_converge"
        printf 'runtime_pending=%s\n' "$runtime_pending"
    } >>"$GITHUB_OUTPUT"
}

main() {
    local mode="${1-}"
    local command_name

    (( $# == 1 )) ||
        fail "Usage: publish-api-image.sh release-scope|ensure-image|migration-guard|assert-rollback-image|read-desired|record-desired|restore-desired"
    case "$mode" in
        release-scope | ensure-image | migration-guard | assert-rollback-image | read-desired | record-desired | restore-desired) ;;
        *)
            fail "Usage: publish-api-image.sh release-scope|ensure-image|migration-guard|assert-rollback-image|read-desired|record-desired|restore-desired"
            ;;
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
        release-scope) release_scope ;;
        ensure-image) ensure_image ;;
        migration-guard) migration_guard ;;
        assert-rollback-image) assert_rollback_image ;;
        read-desired) read_desired ;;
        record-desired) record_desired ;;
        restore-desired) restore_desired ;;
    esac

    log "Completed $mode for $IMAGE_TAG."
}

main "$@"
