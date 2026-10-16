#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PUBLISH_SCRIPT="$SCRIPT_DIRECTORY/publish-api-image.sh"
readonly MIGRATION_PATH="apps/api/src/main/resources/db/migration"
readonly DESIRED_PARAMETER="/ec-portfolio/demo/deploy/desired-image-sha"
readonly LAST_KNOWN_GOOD_PARAMETER="/ec-portfolio/demo/deploy/last-known-good-image-sha"
readonly PENDING_PARAMETER="/ec-portfolio/demo/deploy/pending-migration-image-sha"
readonly FLYWAY_PROPERTIES_PATH="apps/api/src/main/resources/application.properties"
readonly FLYWAY_BUILD_FILE="apps/api/build.gradle.kts"

readonly BASE_PROPERTIES='spring.application.name=ec-api

# Flyway
spring.flyway.enabled=true
spring.flyway.locations=classpath:db/migration
'
readonly BASE_GRADLE='plugins {
    id("org.springframework.boot") version "3.5.7"
    id("org.flywaydb.flyway") version "11.7.2"
}

dependencies {
    implementation("org.springframework.boot:spring-boot-starter-web")
    implementation("org.flywaydb:flyway-core:11.7.2")
    implementation("org.flywaydb:flyway-mysql:11.7.2")
}
'

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
        requested_tag=""
        for arg in "$@"; do
            case "$arg" in imageTag=*) requested_tag="${arg#imageTag=}" ;; esac
        done
        if [[ -n "${MOCK_MISSING_TAG-}" && "$requested_tag" == "${MOCK_MISSING_TAG}" ]]; then
            printf 'An error occurred (ImageNotFoundException) when calling DescribeImages\n' >&2
            exit 254
        fi
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
        parameter_value="${MOCK_PARAMETER_VALUE-}"
        previous=""
        for arg in "$@"; do
            if [[ "$previous" == "--name" ]]; then
                state_file="$MOCK_CALL_LOG.state.$(basename "$arg")"
                if [[ -f "$state_file" ]]; then
                    [[ "${MOCK_READBACK_FAIL-false}" != "true" ]] || { printf 'An error occurred (ThrottlingException)\n' >&2; exit 254; }
                    cat "$state_file"
                    exit 0
                fi
                case "$arg" in
                    */desired-image-sha) parameter_value="${MOCK_DESIRED_VALUE-$parameter_value}" ;;
                    */last-known-good-image-sha) parameter_value="${MOCK_LAST_KNOWN_GOOD_VALUE-$parameter_value}" ;;
                    */pending-migration-image-sha) parameter_value="${MOCK_PENDING_VALUE-$parameter_value}" ;;
                esac
            fi
            previous="$arg"
        done
        if [[ "$parameter_value" == "__missing__" ]]; then
            printf 'An error occurred (ParameterNotFound)\n' >&2
            exit 254
        fi
        printf '%s\n' "$parameter_value"
        ;;
    "ssm put-parameter")
        put_name=""
        put_value=""
        previous=""
        for arg in "$@"; do
            [[ "$previous" != "--name" ]] || put_name="$arg"
            [[ "$previous" != "--value" ]] || put_value="$arg"
            previous="$arg"
        done
        if [[ "${MOCK_PUT_FAIL-false}" == "true" || "${MOCK_PUT_FAIL_FOR-}" == "$(basename "$put_name")" ]]; then
            printf 'An error occurred (InternalServerError)\n' >&2
            exit 254
        fi
        # Accepted but not visible to a later read, as a lost or overtaken write.
        [[ "${MOCK_PUT_NOT_PERSISTED-false}" == "true" ]] ||
            printf '%s\n' "$put_value" >"$MOCK_CALL_LOG.state.$(basename "$put_name")"
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
    login)
        # Real docker reads the password from stdin. Draining it here keeps the
        # mock from closing the pipe early and making get-login-password fail
        # with EPIPE under pipefail.
        cat >/dev/null 2>&1 || true
        ;;
    build | logout) ;;
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
    mkdir -p "$repository/infra/runtime/demo" "$repository/infra/terraform/access"
    for runtime_file in deploy-api-from-ssm.sh deploy-api.sh install-api-convergence.sh \
        ec-portfolio-api-converge.service origin-smoke-check.sh; do
        printf 'base %s\n' "$runtime_file" >"$repository/infra/runtime/demo/$runtime_file"
    done
    printf 'base access\n' >"$repository/infra/terraform/access/README.md"
    printf '%s' "$BASE_PROPERTIES" >"$repository/$FLYWAY_PROPERTIES_PATH"
    printf '%s' "$BASE_GRADLE" >"$repository/$FLYWAY_BUILD_FILE"

    git -C "$repository" init --quiet
    git -C "$repository" -c user.name=test -c user.email=test@example.invalid \
        add -A
    git -C "$repository" -c user.name=test -c user.email=test@example.invalid \
        commit --quiet -m "base"

    printf '%s' "$repository"
}

# Creates a one-commit variant directly on top of the base commit so each Flyway
# scenario is independent of the others.
commit_variant() {
    local repository="$1"
    local base="$2"
    local relative_path="$3"
    local content="$4"
    local message="$5"

    git -C "$repository" checkout -f --quiet --detach "$base"
    mkdir -p "$repository/$(dirname -- "$relative_path")"
    printf '%s' "$content" >"$repository/$relative_path"
    git -C "$repository" -c user.name=test -c user.email=test@example.invalid add -A
    git -C "$repository" -c user.name=test -c user.email=test@example.invalid \
        commit --quiet -m "$message"
    git -C "$repository" rev-parse HEAD
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
    rm -f "$MOCK_CALL_LOG".state.*
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
assert_contains "$output" "No Flyway migration, configuration, or dependency change" \
    "The guard must report a clean comparison."
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

# --- read-desired: what record-desired is about to replace, for a restore -----
previous_output_file="$work_directory/previous-output"
: >"$previous_output_file"
run_publish "$repository" read-desired IMAGE_TAG="$code_sha" GITHUB_OUTPUT="$previous_output_file" \
    MOCK_DESIRED_VALUE="$base_sha" MOCK_PENDING_VALUE="none" >/dev/null 2>&1 ||
    fail "read-desired must succeed on readable deployment state."
[[ "$(cat "$previous_output_file")" == "previous_desired=$base_sha"$'\n'"previous_pending=none" ]] ||
    fail "read-desired must output exactly the previous desired and pending values."
assert_absent "$(cat "$work_directory/calls.log")" "put-parameter" "read-desired must never write deployment state."
: >"$previous_output_file"
run_publish "$repository" read-desired IMAGE_TAG="$code_sha" GITHUB_OUTPUT="$previous_output_file" \
    MOCK_DESIRED_VALUE="$base_sha" MOCK_PENDING_VALUE="$migration_sha" >/dev/null 2>&1 ||
    fail "read-desired must accept a pending migration image SHA."
assert_contains "$(cat "$previous_output_file")" "previous_pending=$migration_sha" "A pending migration image SHA must be kept for the restore."
for unreadable in \
    "Unable to read the desired image SHA|MOCK_DESIRED_VALUE=__missing__ MOCK_PENDING_VALUE=none" \
    "desired image SHA this release would replace is not a full lowercase Git SHA|MOCK_DESIRED_VALUE=not-a-sha MOCK_PENDING_VALUE=none" \
    "Unable to read the pending migration image SHA|MOCK_DESIRED_VALUE=$base_sha MOCK_PENDING_VALUE=__missing__" \
    "neither a full lowercase Git SHA nor none|MOCK_DESIRED_VALUE=$base_sha MOCK_PENDING_VALUE=pending"; do
    : >"$previous_output_file"
    # shellcheck disable=SC2086
    output="$(run_publish "$repository" read-desired IMAGE_TAG="$code_sha" GITHUB_OUTPUT="$previous_output_file" ${unreadable#*|} 2>&1)" &&
        fail "read-desired must fail closed on [${unreadable#*|}]."
    assert_contains "$output" "${unreadable%%|*}" "read-desired must report why [${unreadable#*|}] is refused."
    [[ ! -s "$previous_output_file" ]] || fail "read-desired must output nothing on [${unreadable#*|}]."
done
# Set explicitly empty: a GitHub runner exports GITHUB_OUTPUT to this suite too.
run_publish "$repository" read-desired IMAGE_TAG="$code_sha" GITHUB_OUTPUT= MOCK_DESIRED_VALUE="$base_sha" MOCK_PENDING_VALUE=none >/dev/null 2>&1 &&
    fail "read-desired must refuse to run without GITHUB_OUTPUT."

# --- restore-desired: put back what a failed release replaced -----------------
run_restore() {
    run_publish "$repository" restore-desired IMAGE_TAG="$code_sha" "$@"
}
output="$(run_restore PREVIOUS_DESIRED_IMAGE_SHA="$base_sha" PREVIOUS_PENDING_MIGRATION_IMAGE_SHA="$migration_sha" \
    MOCK_DESIRED_VALUE="$code_sha" 2>&1)" || fail "restore-desired must restore a desired image SHA that is still this release's."
calls="$(cat "$work_directory/calls.log")"
assert_contains "$calls" "put-parameter --region ap-northeast-1 --name $DESIRED_PARAMETER --value $base_sha --type String --overwrite" \
    "The previous desired image SHA must be restored."
assert_contains "$calls" "put-parameter --region ap-northeast-1 --name $PENDING_PARAMETER --value $migration_sha --type String --overwrite" \
    "The previous pending migration image SHA must be restored."
assert_count_puts() { [[ "$(grep -c "put-parameter" "$work_directory/calls.log" || true)" == "$1" ]] || fail "$2"; }
assert_count_puts 2 "restore-desired must write exactly the two values it restores."
assert_absent "$calls" "$LAST_KNOWN_GOOD_PARAMETER --value" "restore-desired must never write the last known good image SHA."
assert_contains "$output" "Restored and read back: the desired image SHA is $base_sha again" "The restore must be reported once read back."
assert_contains "$output" "Restored and read back: the pending migration image SHA is $migration_sha again" \
    "The pending marker must be reported once read back."
[[ "$(grep -c "get-parameter --region ap-northeast-1 --name $DESIRED_PARAMETER" "$work_directory/calls.log")" == 2 ]] ||
    fail "The restored desired image SHA must be read back, not assumed."

output="$(run_restore PREVIOUS_DESIRED_IMAGE_SHA="$base_sha" PREVIOUS_PENDING_MIGRATION_IMAGE_SHA=none \
    MOCK_DESIRED_VALUE="$migration_sha" 2>&1)" || fail "restore-desired must succeed when there is nothing to restore."
assert_count_puts 0 "A desired image SHA that is not this release's must be left alone."
assert_contains "$output" "nothing to restore" "Leaving another value alone must be reported."

# Nothing that is not read back is ever reported as restored, and every failure
# names the failed release, the value to put back and what the operator does.
restore_not_confirmed() {
    local description="$1"
    local reason="$2"
    shift 2
    output="$(run_restore PREVIOUS_DESIRED_IMAGE_SHA="$base_sha" PREVIOUS_PENDING_MIGRATION_IMAGE_SHA=none "$@" 2>&1)" &&
        fail "$description must fail the restore."
    assert_contains "$output" "RESTORE NOT CONFIRMED ($reason)" "$description must say why the restore is not confirmed."
    assert_contains "$output" "may still be $code_sha" "$description must name the failed release still recorded."
    assert_contains "$output" "before it, it was $base_sha" "$description must name the value to put back."
    assert_contains "$output" "Operator: read $DESIRED_PARAMETER now and, if it is not $base_sha, set it back to $base_sha before the host boots again" \
        "$description must say what the operator does."
    assert_absent "$output" "Restored and read back" "$description must never be reported as restored."
}
restore_not_confirmed "An unreadable desired image SHA" "$DESIRED_PARAMETER could not be read" MOCK_DESIRED_VALUE=__missing__
assert_count_puts 0 "An unreadable desired image SHA must not be overwritten blindly."
restore_not_confirmed "A failed write" "the write to $DESIRED_PARAMETER failed" MOCK_DESIRED_VALUE="$code_sha" MOCK_PUT_FAIL=true
restore_not_confirmed "A write that does not show on read-back" "$DESIRED_PARAMETER reads $code_sha after the write" \
    MOCK_DESIRED_VALUE="$code_sha" MOCK_PUT_NOT_PERSISTED=true
restore_not_confirmed "A read-back that fails" "$DESIRED_PARAMETER could not be read back after the write" \
    MOCK_DESIRED_VALUE="$code_sha" MOCK_READBACK_FAIL=true
output="$(run_restore PREVIOUS_DESIRED_IMAGE_SHA="$base_sha" PREVIOUS_PENDING_MIGRATION_IMAGE_SHA=none \
    MOCK_DESIRED_VALUE="$code_sha" MOCK_PUT_FAIL_FOR=pending-migration-image-sha 2>&1)" &&
    fail "A pending marker that cannot be restored must fail the restore."
assert_contains "$output" "Restored and read back: the desired image SHA is $base_sha again" \
    "A restored desired image SHA must still be reported as restored."
assert_contains "$output" "could not be set back to none" "The pending marker failure must be reported."
for malformed in "PREVIOUS_DESIRED_IMAGE_SHA= PREVIOUS_PENDING_MIGRATION_IMAGE_SHA=none" \
    "PREVIOUS_DESIRED_IMAGE_SHA=$base_sha PREVIOUS_PENDING_MIGRATION_IMAGE_SHA=" \
    "PREVIOUS_DESIRED_IMAGE_SHA=HEAD PREVIOUS_PENDING_MIGRATION_IMAGE_SHA=none" \
    "PREVIOUS_DESIRED_IMAGE_SHA=$base_sha PREVIOUS_PENDING_MIGRATION_IMAGE_SHA=pending"; do
    # shellcheck disable=SC2086
    run_restore $malformed MOCK_DESIRED_VALUE="$code_sha" >/dev/null 2>&1 && fail "restore-desired must refuse [$malformed]."
    assert_count_puts 0 "restore-desired must write nothing for [$malformed]."
    assert_absent "$(cat "$work_directory/calls.log")" "get-parameter" "[$malformed] must be refused before any AWS call."
done

# --- assert-rollback-image: the recorded rollback target must still exist ----
output="$(run_publish "$repository" assert-rollback-image IMAGE_TAG="$code_sha" \
    MOCK_IMAGE_PRESENT=true MOCK_PARAMETER_VALUE="$base_sha" 2>&1)" ||
    fail "A published rollback image must satisfy the guard."
assert_contains "$output" "Rollback image is available" "The guard must confirm the rollback image."
calls="$(cat "$work_directory/calls.log")"
assert_contains "$calls" "imageTag=$base_sha" "The guard must inspect the last known good tag."

output="$(run_publish "$repository" assert-rollback-image IMAGE_TAG="$code_sha" \
    MOCK_IMAGE_PRESENT=true MOCK_MISSING_TAG="$base_sha" MOCK_PARAMETER_VALUE="$base_sha" 2>&1)" &&
    fail "An expired rollback image must block the release."
assert_contains "$output" "no longer published" "The guard must name the missing rollback image."
assert_contains "$output" "desired image SHA is left unchanged" \
    "The guard must state that the desired SHA is untouched."
calls="$(cat "$work_directory/calls.log")"
assert_absent "$calls" "put-parameter" "A blocked rollback guard must not write deployment state."

output="$(run_publish "$repository" assert-rollback-image IMAGE_TAG="$code_sha" \
    MOCK_IMAGE_PRESENT=true MOCK_PARAMETER_VALUE="not-a-sha" 2>&1)" &&
    fail "A malformed last known good SHA must fail closed."
assert_contains "$output" "not a full lowercase Git SHA" "The guard must reject a malformed SHA."

# --- migration-guard: Flyway configuration bypasses are blocked --------------
flyway_blocked() {
    local description="$1"
    local variant_sha="$2"
    local expected_reason="$3"
    local blocked_output
    local blocked_calls

    blocked_output="$(run_publish "$repository" migration-guard IMAGE_TAG="$variant_sha" \
        MOCK_PARAMETER_VALUE="$base_sha" 2>&1)" &&
        fail "$description must block automatic deployment."
    assert_contains "$blocked_output" "$expected_reason" "$description must report its reason."
    blocked_calls="$(cat "$work_directory/calls.log")"
    assert_contains "$blocked_calls" "--name $PENDING_PARAMETER --value $variant_sha" \
        "$description must record the pending migration image."
    assert_absent "$blocked_calls" "--name $DESIRED_PARAMETER" \
        "$description must never update the desired image SHA."
}

flyway_disabled_sha="$(commit_variant "$repository" "$base_sha" "$FLYWAY_PROPERTIES_PATH" \
    "${BASE_PROPERTIES/spring.flyway.enabled=true/spring.flyway.enabled=false}" "disable flyway")"
flyway_blocked "Disabling Flyway" "$flyway_disabled_sha" "spring.flyway.enabled=true is no longer declared"

flyway_moved_sha="$(commit_variant "$repository" "$base_sha" "$FLYWAY_PROPERTIES_PATH" \
    "${BASE_PROPERTIES/classpath:db\/migration/classpath:db\/elsewhere}" "repoint flyway locations")"
flyway_blocked "Repointing Flyway locations" "$flyway_moved_sha" \
    "spring.flyway.locations=classpath:db/migration is no longer declared"

flyway_profile_sha="$(commit_variant "$repository" "$base_sha" \
    "apps/api/src/main/resources/application-demo.properties" \
    "spring.flyway.baseline-on-migrate=true"$'\n' "override flyway in a profile")"
flyway_blocked "A profile level Flyway override" "$flyway_profile_sha" \
    "Flyway is configured outside"

flyway_dependency_sha="$(commit_variant "$repository" "$base_sha" "$FLYWAY_BUILD_FILE" \
    "${BASE_GRADLE//flyway-core:11.7.2/flyway-core:11.8.0}" "bump flyway dependency")"
flyway_blocked "A Flyway dependency change" "$flyway_dependency_sha" \
    "Flyway configuration or dependency changed"

# --- migration-guard: unrelated changes must not be false positives ----------
unrelated_property_sha="$(commit_variant "$repository" "$base_sha" "$FLYWAY_PROPERTIES_PATH" \
    "${BASE_PROPERTIES}server.port=8080"$'\n' "unrelated property")"
output="$(run_publish "$repository" migration-guard IMAGE_TAG="$unrelated_property_sha" \
    MOCK_PARAMETER_VALUE="$base_sha" 2>&1)" ||
    fail "An unrelated property change must not block the release."
assert_contains "$output" "No Flyway migration, configuration, or dependency change" \
    "An unrelated property change must report a clean comparison."

unrelated_dependency_sha="$(commit_variant "$repository" "$base_sha" "$FLYWAY_BUILD_FILE" \
    "${BASE_GRADLE/spring-boot-starter-web/spring-boot-starter-webflux}" "unrelated dependency")"
output="$(run_publish "$repository" migration-guard IMAGE_TAG="$unrelated_dependency_sha" \
    MOCK_PARAMETER_VALUE="$base_sha" 2>&1)" ||
    fail "An unrelated dependency change must not block the release."
calls="$(cat "$work_directory/calls.log")"
assert_absent "$calls" "put-parameter" "A clean guard must not write deployment state."

git -C "$repository" checkout -f --quiet --detach "$code_sha"

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

# --- release-scope: what a main push releases, decided before anything else ---
# The scope is read from two deployment-state parameters (the desired image and
# the last known good image) and from git, and written to GITHUB_OUTPUT. It never
# writes deployment state itself.
readonly REAL_GIT="$(command -v git)"

run_scope() {
    local repository_path="$1"
    shift
    scope_output_file="$work_directory/github-output"
    : >"$scope_output_file"
    run_publish "$repository_path" release-scope GITHUB_OUTPUT="$scope_output_file" "$@"
}

scope_value() {
    sed -n "s/^$1=//p" "$scope_output_file"
}

assert_scope() {
    local description="$1"
    local expected="$2"
    local actual
    actual="api_changed=$(scope_value api_changed) api_converge=$(scope_value api_converge) runtime_pending=$(scope_value runtime_pending)"
    [[ "$actual" == "$expected" ]] || fail "$description: got [$actual] want [$expected]"
    [[ "$(grep -c . "$scope_output_file")" == 3 ]] || fail "$description: GITHUB_OUTPUT must hold exactly three decisions."
    assert_absent "$(cat "$work_directory/calls.log")" "put-parameter" "$description: release-scope must never write deployment state."
    assert_absent "$(cat "$work_directory/calls.log")" "ecr " "$description: release-scope must never touch ECR."
    assert_absent "$(cat "$work_directory/calls.log")" "docker " "$description: release-scope must never build or push."
}

# Each scenario starts from the base commit, where the host runs the desired
# image (desired == last known good == base) unless a case says otherwise.
scenario() {
    git -C "$repository" checkout -f --quiet --detach "$base_sha"
}

scenario
access_sha="$(commit_variant "$repository" "$base_sha" "infra/terraform/access/README.md" "access change"$'\n' "access only")"
run_scope "$repository" IMAGE_TAG="$access_sha" MOCK_DESIRED_VALUE="$base_sha" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha" >/dev/null 2>&1 ||
    fail "An access-only push must be decided, not fail."
assert_scope "An access-only push" "api_changed=false api_converge=false runtime_pending=false"
assert_count_calls() { [[ "$(grep -c "ssm get-parameter" "$work_directory/calls.log")" == "$1" ]] || fail "$2"; }
assert_count_calls 2 "release-scope must read exactly the two deployment-state parameters."

scenario
origin_sha="$(commit_variant "$repository" "$base_sha" "infra/runtime/demo/origin-smoke-check.sh" "origin change"$'\n' "origin script")"
run_scope "$repository" IMAGE_TAG="$origin_sha" MOCK_DESIRED_VALUE="$base_sha" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha" >/dev/null 2>&1 ||
    fail "A change to a script CI does not install must be decided."
assert_scope "A change to an operator-installed origin script" "api_changed=false api_converge=false runtime_pending=false"

scenario
api_sha="$(commit_variant "$repository" "$base_sha" "apps/api/src/main/java/Api.java" "class Api {}"$'\n' "api change")"
run_scope "$repository" IMAGE_TAG="$api_sha" MOCK_DESIRED_VALUE="$base_sha" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha" >/dev/null 2>&1 ||
    fail "An API change must be decided."
assert_scope "An API change" "api_changed=true api_converge=true runtime_pending=false"

scenario
runtime_sha="$(commit_variant "$repository" "$base_sha" "infra/runtime/demo/deploy-api.sh" "runtime change"$'\n' "runtime change")"
run_scope "$repository" IMAGE_TAG="$runtime_sha" MOCK_DESIRED_VALUE="$base_sha" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha" >/dev/null 2>&1 ||
    fail "A runtime-only change must be decided."
assert_scope "A runtime-only change" "api_changed=false api_converge=false runtime_pending=true"

for unit_or_installer in "infra/runtime/demo/ec-portfolio-api-converge.service" "infra/runtime/demo/install-api-convergence.sh" \
    "infra/runtime/demo/deploy-api-from-ssm.sh"; do
    scenario
    variant_sha="$(commit_variant "$repository" "$base_sha" "$unit_or_installer" "changed"$'\n' "runtime artifact")"
    run_scope "$repository" IMAGE_TAG="$variant_sha" MOCK_DESIRED_VALUE="$base_sha" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha" >/dev/null 2>&1 ||
        fail "A change to $unit_or_installer must be decided."
    assert_scope "A change to $unit_or_installer" "api_changed=false api_converge=false runtime_pending=true"
done

scenario
git -C "$repository" checkout -f --quiet --detach "$api_sha"
mkdir -p "$repository/infra/runtime/demo"
printf 'runtime and api\n' >"$repository/infra/runtime/demo/deploy-api.sh"
git -C "$repository" -c user.name=test -c user.email=test@example.invalid add -A
git -C "$repository" -c user.name=test -c user.email=test@example.invalid commit --quiet -m "api and runtime"
both_sha="$(git -C "$repository" rev-parse HEAD)"
run_scope "$repository" IMAGE_TAG="$both_sha" MOCK_DESIRED_VALUE="$base_sha" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha" >/dev/null 2>&1 ||
    fail "An API and runtime change must be decided."
assert_scope "An API and runtime change" "api_changed=true api_converge=true runtime_pending=true"

# The runtime baseline is the last known good image, not the previous push: a
# runtime change whose installation was rejected or deferred stays pending on
# the next, unrelated push.
git -C "$repository" checkout -f --quiet --detach "$runtime_sha"
printf 'access after runtime\n' >"$repository/infra/terraform/access/README.md"
git -C "$repository" -c user.name=test -c user.email=test@example.invalid add -A
git -C "$repository" -c user.name=test -c user.email=test@example.invalid commit --quiet -m "access after runtime"
after_runtime_sha="$(git -C "$repository" rev-parse HEAD)"
run_scope "$repository" IMAGE_TAG="$after_runtime_sha" MOCK_DESIRED_VALUE="$base_sha" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha" >/dev/null 2>&1 ||
    fail "A push after a pending runtime change must be decided."
assert_scope "An access push after a pending runtime change" "api_changed=false api_converge=false runtime_pending=true"

# The host has not verified the desired image yet (an earlier release was not
# deployed): an access-only push publishes nothing but still converges the host.
git -C "$repository" checkout -f --quiet --detach "$api_sha"
printf 'access after api\n' >"$repository/infra/terraform/access/README.md"
git -C "$repository" -c user.name=test -c user.email=test@example.invalid add -A
git -C "$repository" -c user.name=test -c user.email=test@example.invalid commit --quiet -m "access after api"
after_api_sha="$(git -C "$repository" rev-parse HEAD)"
run_scope "$repository" IMAGE_TAG="$after_api_sha" MOCK_DESIRED_VALUE="$api_sha" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha" >/dev/null 2>&1 ||
    fail "A push while the host lags the desired image must be decided."
assert_scope "An access push while the host lags the desired image" "api_changed=false api_converge=true runtime_pending=false"

# The host lags a release that also changed the runtime (desired advanced, last
# known good did not): the runtime stays pending even though the desired image
# already contains it. The last known good is the baseline, so it is reported
# until the host verifies an image that contains it; another install only
# compares the host's copies.
git -C "$repository" checkout -f --quiet --detach "$both_sha"
printf 'access after both\n' >"$repository/infra/terraform/access/README.md"
git -C "$repository" -c user.name=test -c user.email=test@example.invalid add -A
git -C "$repository" -c user.name=test -c user.email=test@example.invalid commit --quiet -m "access after both"
after_both_sha="$(git -C "$repository" rev-parse HEAD)"
run_scope "$repository" IMAGE_TAG="$after_both_sha" MOCK_DESIRED_VALUE="$both_sha" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha" >/dev/null 2>&1 ||
    fail "A push while the host lags a runtime release must be decided."
assert_scope "An access push while the host lags a release that changed the runtime" "api_changed=false api_converge=true runtime_pending=true"

# The host started an image that predates a deferred runtime change: the release
# went to an offline host before the runtime change landed, and boot convergence
# later advanced the last known good to it. The runtime change came after that
# image, so it is still pending on the next, unrelated push.
deferred_api_sha="$(commit_variant "$repository" "$base_sha" "apps/api/src/main/java/Deferred.java" "class Deferred {}"$'\n' "deferred api")"
runtime_after_api_sha="$(commit_variant "$repository" "$deferred_api_sha" "infra/runtime/demo/deploy-api.sh" "runtime after api"$'\n' "runtime after api")"
run_scope "$repository" IMAGE_TAG="$runtime_after_api_sha" MOCK_DESIRED_VALUE="$deferred_api_sha" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha" >/dev/null 2>&1 ||
    fail "A runtime push while an API release is deferred must be decided."
assert_scope "A runtime push while an API release is deferred" "api_changed=false api_converge=true runtime_pending=true"
access_after_boot_sha="$(commit_variant "$repository" "$runtime_after_api_sha" "infra/terraform/access/README.md" "access after boot"$'\n' "access after boot")"
run_scope "$repository" IMAGE_TAG="$access_after_boot_sha" MOCK_DESIRED_VALUE="$deferred_api_sha" MOCK_LAST_KNOWN_GOOD_VALUE="$deferred_api_sha" >/dev/null 2>&1 ||
    fail "An access push after boot convergence must be decided."
assert_scope "An access push after boot convergence started an older image" "api_changed=false api_converge=false runtime_pending=true"

# The other order: a runtime change is still pending when an API change follows.
# Both are reported, which is what makes deploy-api install the runtime before it
# records the new desired image.
runtime_first_sha="$(commit_variant "$repository" "$base_sha" "infra/runtime/demo/deploy-api.sh" "runtime first"$'\n' "runtime first")"
api_after_runtime_sha="$(commit_variant "$repository" "$runtime_first_sha" "apps/api/src/main/java/After.java" "class After {}"$'\n' "api after runtime")"
run_scope "$repository" IMAGE_TAG="$api_after_runtime_sha" MOCK_DESIRED_VALUE="$base_sha" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha" >/dev/null 2>&1 ||
    fail "An API push after a pending runtime change must be decided."
assert_scope "An API push after a pending runtime change" "api_changed=true api_converge=true runtime_pending=true"

# Once the host has verified an image that contains every runtime change, nothing
# is pending any more.
access_after_release_sha="$(commit_variant "$repository" "$api_after_runtime_sha" "infra/terraform/access/README.md" "access after release"$'\n' "access after release")"
run_scope "$repository" IMAGE_TAG="$access_after_release_sha" MOCK_DESIRED_VALUE="$api_after_runtime_sha" MOCK_LAST_KNOWN_GOOD_VALUE="$api_after_runtime_sha" >/dev/null 2>&1 ||
    fail "An access push after a full release must be decided."
assert_scope "An access push after a full release" "api_changed=false api_converge=false runtime_pending=false"

# A runtime change that was reverted since the last known good still counts: a
# runtime-only release may have installed it in between, and no image marks
# that, so only an install can tell whether the host holds the reverted copy.
runtime_change_sha="$(commit_variant "$repository" "$base_sha" "infra/runtime/demo/deploy-api.sh" "runtime to revert"$'\n' "runtime to revert")"
runtime_revert_sha="$(commit_variant "$repository" "$runtime_change_sha" "infra/runtime/demo/deploy-api.sh" "base deploy-api.sh"$'\n' "revert runtime")"
access_after_revert_sha="$(commit_variant "$repository" "$runtime_revert_sha" "infra/terraform/access/README.md" "access after revert"$'\n' "access after revert")"
git -C "$repository" diff --quiet "$base_sha" "$access_after_revert_sha" -- infra/runtime/demo ||
    fail "The revert scenario must leave no net runtime difference."
run_scope "$repository" IMAGE_TAG="$access_after_revert_sha" MOCK_DESIRED_VALUE="$base_sha" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha" >/dev/null 2>&1 ||
    fail "An access push after a reverted runtime change must be decided."
assert_scope "An access push after a reverted runtime change" "api_changed=false api_converge=false runtime_pending=true"
api_after_revert_sha="$(commit_variant "$repository" "$runtime_revert_sha" "apps/api/src/main/java/Revert.java" "class Revert {}"$'\n' "api after revert")"
run_scope "$repository" IMAGE_TAG="$api_after_revert_sha" MOCK_DESIRED_VALUE="$base_sha" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha" >/dev/null 2>&1 ||
    fail "An API push after a reverted runtime change must be decided."
assert_scope "An API push after a reverted runtime change" "api_changed=true api_converge=true runtime_pending=true"

# A Flyway migration is an API change, so the migration guard keeps running.
scenario
run_scope "$repository" IMAGE_TAG="$migration_sha" MOCK_DESIRED_VALUE="$base_sha" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha" >/dev/null 2>&1 ||
    fail "A migration change must be decided."
assert_scope "A Flyway migration change" "api_changed=true api_converge=true runtime_pending=false"

# Fail-closed: no decision is written and nothing is published or recorded.
scope_fails() {
    local description="$1"
    local expected_message="$2"
    shift 2
    local scope_output
    scope_output="$(run_scope "$repository" "$@" 2>&1)" && fail "$description must fail closed."
    assert_contains "$scope_output" "$expected_message" "$description must report its reason."
    [[ ! -s "$scope_output_file" ]] || fail "$description must not write any decision to GITHUB_OUTPUT."
    assert_absent "$(cat "$work_directory/calls.log")" "put-parameter" "$description must not write deployment state."
}
scenario
scope_fails "An unreadable desired image SHA" "Unable to read the desired image SHA" \
    IMAGE_TAG="$access_sha" MOCK_DESIRED_VALUE="__missing__" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha"
scope_fails "An unreadable last known good SHA" "Unable to read the last known good image SHA" \
    IMAGE_TAG="$access_sha" MOCK_DESIRED_VALUE="$base_sha" MOCK_LAST_KNOWN_GOOD_VALUE="__missing__"
scope_fails "A malformed desired image SHA" "desired image SHA is not a full lowercase Git SHA" \
    IMAGE_TAG="$access_sha" MOCK_DESIRED_VALUE="not-a-sha" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha"
scope_fails "An uppercase desired image SHA" "desired image SHA is not a full lowercase Git SHA" \
    IMAGE_TAG="$access_sha" MOCK_DESIRED_VALUE="$(printf '%s' "$base_sha" | tr 'a-f' 'A-F')" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha"
scope_fails "An empty desired image SHA" "desired image SHA is not a full lowercase Git SHA" \
    IMAGE_TAG="$access_sha" MOCK_DESIRED_VALUE="" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha"
scope_fails "A desired image commit missing from the checkout" "is not present" \
    IMAGE_TAG="$access_sha" MOCK_DESIRED_VALUE="0123456789abcdef0123456789abcdef01234567" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha"
scope_fails "A last known good commit missing from the checkout" "is not present" \
    IMAGE_TAG="$access_sha" MOCK_DESIRED_VALUE="$base_sha" MOCK_LAST_KNOWN_GOOD_VALUE="0123456789abcdef0123456789abcdef01234567"
scope_fails "A release commit missing from the checkout" "The release commit" \
    IMAGE_TAG="0123456789abcdef0123456789abcdef01234567" MOCK_DESIRED_VALUE="$base_sha" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha"
scope_fails "A desired parameter outside the deployment-state prefix" "is not a Demo deployment-state parameter" \
    IMAGE_TAG="$access_sha" DESIRED_IMAGE_SHA_PARAMETER=/ec-portfolio/demo/app/auth-jwt-secret MOCK_DESIRED_VALUE="$base_sha" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha"

output="$(run_publish "$repository" release-scope IMAGE_TAG="$access_sha" MOCK_DESIRED_VALUE="$base_sha" \
    MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha" GITHUB_OUTPUT= 2>&1)" && fail "A missing GITHUB_OUTPUT must fail closed."
assert_contains "$output" "GITHUB_OUTPUT" "A missing GITHUB_OUTPUT must be reported."
output="$(run_publish "$repository" release-scope IMAGE_TAG="$access_sha" MOCK_DESIRED_VALUE="$base_sha" \
    MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha" GITHUB_OUTPUT="$work_directory/no-such-directory/output" 2>&1)" &&
    fail "An unwritable GITHUB_OUTPUT must fail closed."
assert_contains "$output" "GITHUB_OUTPUT is not a writable file" "An unwritable GITHUB_OUTPUT must be refused before any read."
assert_absent "$(cat "$work_directory/calls.log")" "get-parameter" "An unwritable GITHUB_OUTPUT must be refused before any AWS call."

# A git failure is neither "changed" nor "unchanged".
git_mock_directory="$work_directory/git-mock"
mkdir -p "$git_mock_directory"
printf '#!/usr/bin/env bash\nif [[ "${1-}" == diff ]]; then echo "fatal: simulated diff failure" >&2; exit 128; fi\nexec "%s" "$@"\n' "$REAL_GIT" >"$git_mock_directory/git"
chmod 755 "$git_mock_directory/git"
scope_fails "A git diff failure" "Unable to compare" \
    IMAGE_TAG="$access_sha" MOCK_DESIRED_VALUE="$base_sha" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha" PATH="$git_mock_directory:$PATH"
printf '#!/usr/bin/env bash\nif [[ "${1-}" == rev-list ]]; then echo "fatal: simulated rev-list failure" >&2; exit 128; fi\nexec "%s" "$@"\n' "$REAL_GIT" >"$git_mock_directory/git"
scope_fails "A git rev-list failure" "Unable to list the commits that changed" \
    IMAGE_TAG="$access_sha" MOCK_DESIRED_VALUE="$base_sha" MOCK_LAST_KNOWN_GOOD_VALUE="$base_sha" PATH="$git_mock_directory:$PATH"

git -C "$repository" checkout -f --quiet --detach "$code_sha"

# --- static contract: no destructive or mutable-tag operations ---------------
for forbidden in "batch-delete-image" "delete-repository" "put-lifecycle-policy" \
    ":latest" "--force" "docker tag" "put-image-tag-mutability"; do
    grep -Fq -- "$forbidden" "$PUBLISH_SCRIPT" &&
        fail "The publication script must not reference: $forbidden"
done

printf '[api-publish-test] PASS\n'
