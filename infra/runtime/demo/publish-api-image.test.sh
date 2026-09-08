#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PUBLISH_SCRIPT="$SCRIPT_DIRECTORY/publish-api-image.sh"
readonly MIGRATION_PATH="apps/api/src/main/resources/db/migration"
readonly DESIRED_PARAMETER="/ec-portfolio/demo/deploy/desired-image-sha"
readonly LAST_KNOWN_GOOD_PARAMETER="/ec-portfolio/demo/deploy/last-known-good-image-sha"
readonly PENDING_PARAMETER="/ec-portfolio/demo/deploy/pending-migration-image-sha"

work_directory=""

cleanup() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-api-publish-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup EXIT

fail() {
    printf '[api-publish-test] FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local description="$3"

    printf '%s' "$haystack" | grep -Fq -- "$needle" ||
        fail "$description (expected to find: $needle)"
}

assert_absent() {
    local haystack="$1"
    local needle="$2"
    local description="$3"

    printf '%s' "$haystack" | grep -Fq -- "$needle" &&
        fail "$description (unexpectedly found: $needle)"
    return 0
}

assert_order() {
    local calls_file="$1"
    local first="$2"
    local second="$3"
    local description="$4"
    local first_line
    local second_line

    first_line="$(grep -n -F -- "$first" "$calls_file" | head -1 | cut -d: -f1)"
    second_line="$(grep -n -F -- "$second" "$calls_file" | head -1 | cut -d: -f1)"
    [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]] ||
        fail "$description"
}

install_mocks() {
    local mock_directory="$work_directory/bin"

    mkdir -p "$mock_directory"

    cat >"$mock_directory/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "aws $*" >>"$MOCK_CALL_LOG"

service="${1-}"
operation="${2-}"

case "$service $operation" in
    "ecr describe-images")
        if [[ "${MOCK_IMAGE_PRESENT-false}" == "true" ]]; then
            printf 'sha256:%064d\n' 1
            exit 0
        fi
        if [[ "${MOCK_DESCRIBE_ERROR-notfound}" == "notfound" ]]; then
            printf 'An error occurred (ImageNotFoundException) when calling DescribeImages\n' >&2
        else
            printf 'An error occurred (AccessDeniedException) when calling DescribeImages\n' >&2
        fi
        exit 254
        ;;
    "ecr get-login-password")
        printf 'mock-token\n'
        ;;
    "ssm get-parameter")
        if [[ "${MOCK_PARAMETER_VALUE-}" == "__missing__" ]]; then
            printf 'An error occurred (ParameterNotFound)\n' >&2
            exit 254
        fi
        printf '%s\n' "${MOCK_PARAMETER_VALUE-}"
        ;;
    "ssm put-parameter")
        ;;
    *)
        printf 'unexpected aws invocation: %s\n' "$*" >&2
        exit 64
        ;;
esac
MOCK

    cat >"$mock_directory/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "docker $*" >>"$MOCK_CALL_LOG"

default_user='10001:10001'
default_entrypoint='["java","-jar","/app/app.jar"]'
default_ports='{"8080/tcp":{}}'
default_env='JAVA_HOME=/opt/java/openjdk'
default_history='/bin/sh -c #(nop) COPY file:app.jar in /app/'

case "${1-}" in
    push)
        if [[ "${MOCK_PUSH_RACE-false}" == "true" ]]; then
            printf 'tag invalid: ImageTagAlreadyExistsException\n' >&2
            exit 1
        fi
        ;;
    image)
        case "${4-}" in
            *Config.User*) printf '%s\n' "${MOCK_IMAGE_USER:-$default_user}" ;;
            *Entrypoint*) printf '%s\n' "${MOCK_IMAGE_ENTRYPOINT:-$default_entrypoint}" ;;
            *ExposedPorts*) printf '%s\n' "${MOCK_IMAGE_PORTS:-$default_ports}" ;;
            *Config.Env*) printf '%s\n' "${MOCK_IMAGE_ENV:-$default_env}" ;;
            *)
                printf 'unexpected inspect format: %s\n' "${4-}" >&2
                exit 64
                ;;
        esac
        ;;
    history)
        printf '%s\n' "${MOCK_IMAGE_HISTORY:-$default_history}"
        ;;
    run)
        exit "${MOCK_IMAGE_RUN_STATUS:-0}"
        ;;
    build | login | logout) ;;
    *)
        printf 'unexpected docker invocation: %s\n' "$*" >&2
        exit 64
        ;;
esac
MOCK

    chmod 755 "$mock_directory/aws" "$mock_directory/docker"
    PATH="$mock_directory:$PATH"
    export PATH
}

create_repository() {
    local repository="$work_directory/repo"

    mkdir -p "$repository/$MIGRATION_PATH" "$repository/apps/api"
    printf 'FROM scratch\n' >"$repository/apps/api/Dockerfile"
    printf 'SELECT 1;\n' >"$repository/$MIGRATION_PATH/V1__init.sql"
    printf 'base\n' >"$repository/README.md"

    git -C "$repository" init --quiet
    git -C "$repository" -c user.name=test -c user.email=test@example.invalid \
        add -A
    git -C "$repository" -c user.name=test -c user.email=test@example.invalid \
        commit --quiet -m "base"

    printf '%s' "$repository"
}

commit_change() {
    local repository="$1"
    local relative_path="$2"
    local message="$3"

    mkdir -p "$repository/$(dirname -- "$relative_path")"
    printf 'changed\n' >"$repository/$relative_path"
    git -C "$repository" -c user.name=test -c user.email=test@example.invalid add -A
    git -C "$repository" -c user.name=test -c user.email=test@example.invalid \
        commit --quiet -m "$message"
}

run_publish() {
    local repository="$1"
    local mode="$2"
    shift 2

    MOCK_CALL_LOG="$work_directory/calls.log"
    : >"$MOCK_CALL_LOG"
    export MOCK_CALL_LOG

    env -C "$repository" \
        AWS_REGION=ap-northeast-1 \
        AWS_ACCOUNT_ID=000000000000 \
        ECR_REPOSITORY_NAME=ec-portfolio-demo-api \
        BUILD_CONTEXT=apps/api \
        MIGRATION_PATH="$MIGRATION_PATH" \
        DESIRED_IMAGE_SHA_PARAMETER="$DESIRED_PARAMETER" \
        LAST_KNOWN_GOOD_IMAGE_SHA_PARAMETER="$LAST_KNOWN_GOOD_PARAMETER" \
        PENDING_MIGRATION_IMAGE_SHA_PARAMETER="$PENDING_PARAMETER" \
        "$@" \
        bash "$PUBLISH_SCRIPT" "$mode"
}

work_directory="$(mktemp -d /tmp/ec-portfolio-api-publish-test.XXXXXX)"
install_mocks

repository="$(create_repository)"
base_sha="$(git -C "$repository" rev-parse HEAD)"

# --- ensure-image: an already published tag is reused without building -------
commit_change "$repository" "apps/api/src/main/kotlin/App.kt" "code only"
code_sha="$(git -C "$repository" rev-parse HEAD)"

output="$(run_publish "$repository" ensure-image IMAGE_TAG="$code_sha" MOCK_IMAGE_PRESENT=true 2>&1)" ||
    fail "ensure-image must succeed when the tag already exists."
assert_contains "$output" "skipping build and push" "Existing tags must be reused."
calls="$(cat "$work_directory/calls.log")"
assert_absent "$calls" "docker build" "An existing tag must not be rebuilt."
assert_absent "$calls" "docker push" "An existing tag must not be pushed again."
assert_absent "$calls" "get-login-password" "An existing tag must not trigger an ECR login."

# --- ensure-image: a missing tag is built and pushed exactly once ------------
run_publish "$repository" ensure-image IMAGE_TAG="$code_sha" MOCK_IMAGE_PRESENT=false >/dev/null 2>&1 ||
    fail "ensure-image must publish a missing tag."
calls="$(cat "$work_directory/calls.log")"
assert_contains "$calls" "docker build --tag 000000000000.dkr.ecr.ap-northeast-1.amazonaws.com/ec-portfolio-demo-api:$code_sha" \
    "The image must be tagged with the exact Git SHA reference."
assert_contains "$calls" "docker push 000000000000.dkr.ecr.ap-northeast-1.amazonaws.com/ec-portfolio-demo-api:$code_sha" \
    "The immutable tag must be pushed."
assert_contains "$calls" "docker logout" "The runner must log out of ECR."
assert_contains "$calls" "docker image inspect --format {{.Config.User}}" \
    "The pushed artifact must be checked for the non-root runtime user."
assert_contains "$calls" "docker image inspect --format {{json .Config.Entrypoint}}" \
    "The pushed artifact must be checked for the expected entrypoint."
assert_contains "$calls" "docker image inspect --format {{json .Config.ExposedPorts}}" \
    "The pushed artifact must be checked for the exposed port."
assert_contains "$calls" "docker history --no-trunc" \
    "The pushed artifact must be checked for secrets in its build history."
assert_contains "$calls" "docker run --rm --entrypoint sh" \
    "The pushed artifact must be checked for its /app and CA bundle contents."
assert_order "$work_directory/calls.log" "docker build" "docker image inspect" \
    "The image contract must be verified after the build."
assert_order "$work_directory/calls.log" "docker run --rm --entrypoint sh" "aws ecr get-login-password" \
    "The image contract must be verified before any ECR credential is used."
assert_order "$work_directory/calls.log" "docker run --rm --entrypoint sh" "docker push" \
    "The image contract must be verified before the push."

# --- ensure-image: a contract violation blocks the push --------------------
verify_violation() {
    local description="$1"
    local expected_message="$2"
    shift 2
    local violation_output

    violation_output="$(run_publish "$repository" ensure-image IMAGE_TAG="$code_sha" \
        MOCK_IMAGE_PRESENT=false "$@" 2>&1)" &&
        fail "$description must block publication."
    assert_contains "$violation_output" "$expected_message" "$description must be reported."
    violation_calls="$(cat "$work_directory/calls.log")"
    assert_absent "$violation_calls" "docker push" "$description must not push."
    assert_absent "$violation_calls" "get-login-password" "$description must not use an ECR credential."
}

verify_violation "A root runtime user" "non-root user" MOCK_IMAGE_USER="0:0"
verify_violation "An unexpected entrypoint" "entrypoint does not match" \
    MOCK_IMAGE_ENTRYPOINT='["sh","-c","java -jar /app/app.jar"]'
verify_violation "An extra exposed port" "expose exactly 8080/tcp" \
    MOCK_IMAGE_PORTS='{"8080/tcp":{},"9090/tcp":{}}'
verify_violation "A secret in the image environment" "environment must not carry runtime secret" \
    MOCK_IMAGE_ENV="APP_AUTH_JWT_SECRET=leaked"
verify_violation "A secret in the image history" "history must not carry runtime secret" \
    MOCK_IMAGE_HISTORY="RUN DB_PASSWORD=leaked ./build"
verify_violation "Unexpected image contents" "contents do not match" MOCK_IMAGE_RUN_STATUS=1

# --- ensure-image: a concurrent push that loses the immutable race is reused -
output="$(run_publish "$repository" ensure-image IMAGE_TAG="$code_sha" \
    MOCK_IMAGE_PRESENT=false MOCK_PUSH_RACE=true 2>&1)" &&
    fail "A push race must not succeed while describe-images still reports the tag missing."
assert_contains "$output" "not present" "A lost race with no resulting tag must fail closed."

# --- ensure-image: an unexpected describe error fails closed ----------------
output="$(run_publish "$repository" ensure-image IMAGE_TAG="$code_sha" \
    MOCK_IMAGE_PRESENT=false MOCK_DESCRIBE_ERROR=denied 2>&1)" &&
    fail "An unexpected describe-images error must fail closed."
assert_contains "$output" "Unable to inspect" "Describe failures must not be treated as a missing tag."
calls="$(cat "$work_directory/calls.log")"
assert_absent "$calls" "docker build" "A failed inspection must not start a build."

# --- migration-guard: a code-only release passes without writing state -------
output="$(run_publish "$repository" migration-guard IMAGE_TAG="$code_sha" \
    MOCK_PARAMETER_VALUE="$base_sha" 2>&1)" ||
    fail "A code-only release must pass the migration guard."
assert_contains "$output" "No Flyway migration change" "The guard must report a clean comparison."
calls="$(cat "$work_directory/calls.log")"
assert_absent "$calls" "put-parameter" "A clean guard must not write deployment state."

# --- migration-guard: a migration release is blocked fail-closed -------------
commit_change "$repository" "$MIGRATION_PATH/V2__add_table.sql" "migration"
migration_sha="$(git -C "$repository" rev-parse HEAD)"

output="$(run_publish "$repository" migration-guard IMAGE_TAG="$migration_sha" \
    MOCK_PARAMETER_VALUE="$base_sha" 2>&1)" &&
    fail "A migration release must block automatic deployment."
assert_contains "$output" "Flyway migration change detected" "The guard must name the failure."
assert_contains "$output" "manual migration release is required" "The guard must demand a manual release."
assert_contains "$output" "V2__add_table.sql" "The guard must list the changed migration."
assert_contains "$output" "desired image SHA is unchanged" "The guard must state that the desired SHA is unchanged."
calls="$(cat "$work_directory/calls.log")"
assert_contains "$calls" "put-parameter --region ap-northeast-1 --name $PENDING_PARAMETER --value $migration_sha" \
    "A blocked release must record the pending migration image."
assert_absent "$calls" "--name $DESIRED_PARAMETER" \
    "A blocked release must never update the desired image SHA."

# --- migration-guard: unusable last known good state fails closed ------------
output="$(run_publish "$repository" migration-guard IMAGE_TAG="$code_sha" \
    MOCK_PARAMETER_VALUE="not-a-sha" 2>&1)" &&
    fail "An invalid last known good SHA must fail closed."
assert_contains "$output" "not a full lowercase Git SHA" "The guard must reject a malformed SHA."

output="$(run_publish "$repository" migration-guard IMAGE_TAG="$code_sha" \
    MOCK_PARAMETER_VALUE="$(printf '0%.0s' {1..40})" 2>&1)" &&
    fail "An unknown last known good commit must fail closed."
assert_contains "$output" "is not present" "The guard must require the compared commit."

output="$(run_publish "$repository" migration-guard IMAGE_TAG="$code_sha" \
    MOCK_PARAMETER_VALUE="__missing__" 2>&1)" &&
    fail "A missing parameter must fail closed."
assert_contains "$output" "Unable to read the last known good image SHA" \
    "The guard must fail when deployment state cannot be read."

# --- record-desired: writes the desired SHA and clears the pending marker ----
run_publish "$repository" record-desired IMAGE_TAG="$code_sha" >/dev/null 2>&1 ||
    fail "record-desired must succeed after a clean guard."
calls="$(cat "$work_directory/calls.log")"
assert_contains "$calls" "put-parameter --region ap-northeast-1 --name $DESIRED_PARAMETER --value $code_sha --type String --overwrite" \
    "The desired image SHA must be recorded."
assert_contains "$calls" "put-parameter --region ap-northeast-1 --name $PENDING_PARAMETER --value none --type String --overwrite" \
    "A successful publication must clear the pending migration marker."

# --- input validation -------------------------------------------------------
for invalid_tag in "latest" "799FDDBFA5ED7F663182347F6291163FC4F57983" "799fddbf"; do
    run_publish "$repository" ensure-image IMAGE_TAG="$invalid_tag" MOCK_IMAGE_PRESENT=true >/dev/null 2>&1 &&
        fail "IMAGE_TAG must reject: $invalid_tag"
done

run_publish "$repository" ensure-image IMAGE_TAG="$code_sha" AWS_REGION=us-east-1 >/dev/null 2>&1 &&
    fail "A non-Tokyo region must be rejected."
run_publish "$repository" ensure-image IMAGE_TAG="$code_sha" AWS_ACCOUNT_ID=12345 >/dev/null 2>&1 &&
    fail "A malformed account id must be rejected."
run_publish "$repository" ensure-image IMAGE_TAG="$code_sha" ECR_REPOSITORY_NAME=other-repo >/dev/null 2>&1 &&
    fail "An unexpected repository must be rejected."
run_publish "$repository" record-desired IMAGE_TAG="$code_sha" \
    DESIRED_IMAGE_SHA_PARAMETER=/ec-portfolio/demo/app/auth-jwt-secret >/dev/null 2>&1 &&
    fail "A parameter outside the deployment-state prefix must be rejected."
run_publish "$repository" delete-image IMAGE_TAG="$code_sha" >/dev/null 2>&1 &&
    fail "An unknown mode must be rejected."

# --- static contract: no destructive or mutable-tag operations ---------------
for forbidden in "batch-delete-image" "delete-repository" "put-lifecycle-policy" \
    ":latest" "--force" "docker tag" "put-image-tag-mutability"; do
    grep -Fq -- "$forbidden" "$PUBLISH_SCRIPT" &&
        fail "The publication script must not reference: $forbidden"
done

printf '[api-publish-test] PASS\n'
