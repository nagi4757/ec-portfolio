#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly WRAPPER_SCRIPT="$SCRIPT_DIRECTORY/deploy-api-from-ssm.sh"

readonly DESIRED_SHA="5482d650d8cdc22dadc8b3ac96c056d2c8713afb"
readonly PREVIOUS_SHA="799fddbfa5ed7f663182347f6291163fc4f57983"
readonly ACCOUNT_ID="000000000000"
readonly EXPECTED_REFERENCE="$ACCOUNT_ID.dkr.ecr.ap-northeast-1.amazonaws.com/ec-portfolio-demo-api:$DESIRED_SHA"
readonly EXPECTED_CORS="http://127.0.0.1:5174,http://127.0.0.1:5173,https://d39sletn97e89c.cloudfront.net,https://d1ap338mlg8v7d.cloudfront.net"
readonly LAST_KNOWN_GOOD_PARAMETER="/ec-portfolio/demo/deploy/last-known-good-image-sha"

work_directory=""

cleanup() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-deploy-ssm-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup EXIT

fail() {
    printf '[deploy-from-ssm-test] FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    printf '%s' "$1" | grep -Fq -- "$2" || fail "$3 (expected to find: $2)"
}

assert_absent() {
    printf '%s' "$1" | grep -Fq -- "$2" && fail "$3 (unexpectedly found: $2)"
    return 0
}

assert_count() {
    local haystack="$1"
    local needle="$2"
    local expected="$3"
    local description="$4"
    local actual

    actual="$(printf '%s\n' "$haystack" | grep -Fc -- "$needle" || true)"
    [[ "$actual" -eq "$expected" ]] ||
        fail "$description (expected $expected occurrences of '$needle', found $actual)"
}

install_mocks() {
    local mock_directory="$work_directory/bin"

    mkdir -p "$mock_directory"

    cat >"$mock_directory/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "aws $*" >>"$MOCK_CALL_LOG"

parameter_name=""
previous=""
for argument in "$@"; do
    [[ "$previous" != "--name" ]] || parameter_name="$argument"
    previous="$argument"
done

if [[ -n "${MOCK_MISSING_PARAMETER-}" && "$parameter_name" == "${MOCK_MISSING_PARAMETER}" ]]; then
    printf 'An error occurred (ParameterNotFound)\n' >&2
    exit 254
fi

case "${1-} ${2-}" in
    "sts get-caller-identity")
        printf '%s\n' "${MOCK_ACCOUNT:-000000000000}"
        ;;
    "ssm get-parameter")
        case "$parameter_name" in
            */deploy/desired-image-sha) printf '%s\n' "${MOCK_DESIRED-}" ;;
            */deploy/last-known-good-image-sha) printf '%s\n' "${MOCK_LKG-}" ;;
            */runtime/db-host) printf '%s\n' "${MOCK_DB_HOST-}" ;;
            */runtime/db-port) printf '%s\n' "${MOCK_DB_PORT-}" ;;
            */runtime/db-name) printf '%s\n' "${MOCK_DB_NAME-}" ;;
            */runtime/db-username) printf '%s\n' "${MOCK_DB_USERNAME-}" ;;
            */runtime/cors-allowed-origins) printf '%s\n' "${MOCK_CORS-}" ;;
            *)
                printf 'unexpected parameter: %s\n' "$parameter_name" >&2
                exit 64
                ;;
        esac
        ;;
    "ssm put-parameter")
        exit "${MOCK_PUT_PARAMETER_STATUS:-0}"
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

case "${1-}" in
    container)
        [[ "${MOCK_CONTAINER_EXISTS:-true}" == "true" ]] || exit 1
        ;;
    inspect)
        case "${3-}" in
            *Config.Image*) printf '%s\n' "${MOCK_CONTAINER_IMAGE-}" ;;
            *State.Running*) printf '%s\n' "${MOCK_CONTAINER_RUNNING:-true}" ;;
            *)
                printf 'unexpected inspect format: %s\n' "${3-}" >&2
                exit 64
                ;;
        esac
        ;;
    *)
        printf 'unexpected docker invocation: %s\n' "$*" >&2
        exit 64
        ;;
esac
MOCK

    cat >"$mock_directory/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "curl $*" >>"$MOCK_CALL_LOG"
[[ "${MOCK_READINESS:-up}" == "up" ]] || exit 22
printf '{"status":"UP","groups":["readiness"]}\n'
MOCK

    # flock is Linux only, so the lock contract is exercised through a mock that
    # reports whether the non-blocking acquisition succeeded.
    cat >"$mock_directory/flock" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "flock $*" >>"$MOCK_CALL_LOG"
exit "${MOCK_FLOCK_STATUS:-0}"
MOCK

    cat >"$mock_directory/deploy-api-stub.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "deploy-api $*" >>"$MOCK_CALL_LOG"
{
    printf 'IMAGE_REF=%s\n' "${IMAGE_REF-}"
    printf 'DB_HOST=%s\n' "${DB_HOST-}"
    printf 'DB_PORT=%s\n' "${DB_PORT-}"
    printf 'DB_NAME=%s\n' "${DB_NAME-}"
    printf 'DB_USERNAME=%s\n' "${DB_USERNAME-}"
    printf 'APP_CORS_ALLOWED_ORIGINS=%s\n' "${APP_CORS_ALLOWED_ORIGINS-}"
    printf 'DB_PASSWORD_PRESENT=%s\n' "${DB_PASSWORD+yes}"
    printf 'APP_AUTH_JWT_SECRET_PRESENT=%s\n' "${APP_AUTH_JWT_SECRET+yes}"
} >"$DEPLOY_ENV_LOG"
exit "${MOCK_DEPLOY_STATUS:-0}"
MOCK

    chmod 755 "$mock_directory"/aws "$mock_directory"/docker "$mock_directory"/curl \
        "$mock_directory"/flock "$mock_directory"/deploy-api-stub.sh
    PATH="$mock_directory:$PATH"
    export PATH
}

run_wrapper() {
    MOCK_CALL_LOG="$work_directory/calls.log"
    DEPLOY_ENV_LOG="$work_directory/deploy-env.log"
    : >"$MOCK_CALL_LOG"
    : >"$DEPLOY_ENV_LOG"
    export MOCK_CALL_LOG DEPLOY_ENV_LOG

    env \
        DEPLOY_API_SCRIPT="$work_directory/bin/deploy-api-stub.sh" \
        DEPLOY_LOCK_FILE="$work_directory/deploy.lock" \
        MOCK_DESIRED="$DESIRED_SHA" \
        MOCK_ACCOUNT="$ACCOUNT_ID" \
        MOCK_DB_HOST="demo-db.ap-northeast-1.rds.amazonaws.com" \
        MOCK_DB_PORT="3306" \
        MOCK_DB_NAME="ecportfolio" \
        MOCK_DB_USERNAME="ecadmin" \
        MOCK_CORS="$EXPECTED_CORS" \
        MOCK_LKG="$PREVIOUS_SHA" \
        MOCK_CONTAINER_IMAGE="$ACCOUNT_ID.dkr.ecr.ap-northeast-1.amazonaws.com/ec-portfolio-demo-api:$PREVIOUS_SHA" \
        "$@" \
        bash "$WRAPPER_SCRIPT"
}

work_directory="$(mktemp -d /tmp/ec-portfolio-deploy-ssm-test.XXXXXX)"
install_mocks

# --- a new release is deployed and recorded ---------------------------------
output="$(run_wrapper 2>&1)" || fail "A new desired release must deploy."
assert_contains "$output" "Deploying $DESIRED_SHA" "The wrapper must deploy the desired release."
assert_contains "$output" "Recording $DESIRED_SHA" "The wrapper must record the last known good image."

deploy_env="$(cat "$work_directory/deploy-env.log")"
assert_contains "$deploy_env" "IMAGE_REF=$EXPECTED_REFERENCE" "The ECR reference must be exact."
assert_contains "$deploy_env" "DB_HOST=demo-db.ap-northeast-1.rds.amazonaws.com" "DB_HOST must be passed."
assert_contains "$deploy_env" "DB_PORT=3306" "DB_PORT must be passed."
assert_contains "$deploy_env" "DB_NAME=ecportfolio" "DB_NAME must be passed."
assert_contains "$deploy_env" "DB_USERNAME=ecadmin" "DB_USERNAME must be passed."
assert_contains "$deploy_env" "APP_CORS_ALLOWED_ORIGINS=$EXPECTED_CORS" \
    "The four origin Phase 5C allowlist must be passed verbatim."
assert_contains "$deploy_env" "DB_PASSWORD_PRESENT=" "The wrapper must not set DB_PASSWORD."
assert_contains "$deploy_env" "APP_AUTH_JWT_SECRET_PRESENT=" "The wrapper must not set APP_AUTH_JWT_SECRET."

calls="$(cat "$work_directory/calls.log")"
assert_contains "$calls" "put-parameter --region ap-northeast-1 --name $LAST_KNOWN_GOOD_PARAMETER --value $DESIRED_SHA --type String --overwrite" \
    "The last known good image SHA must be recorded exactly once."
assert_absent "$calls" "--with-decryption" "The wrapper must never decrypt a SecureString."
assert_absent "$calls" "master-password" "The wrapper must never read the database password."
assert_absent "$calls" "auth-jwt-secret" "The wrapper must never read the JWT secret."

# --- an already converged and recorded host is a no-op ----------------------
output="$(run_wrapper MOCK_CONTAINER_IMAGE="$EXPECTED_REFERENCE" MOCK_READINESS=up \
    MOCK_LKG="$DESIRED_SHA" 2>&1)" ||
    fail "A converged healthy host must succeed."
assert_contains "$output" "Nothing to deploy" "A converged host must report a no-op."
calls="$(cat "$work_directory/calls.log")"
assert_absent "$calls" "deploy-api" "A no-op must not run the deployment script."
assert_absent "$calls" "put-parameter" "A no-op must not rewrite deployment state."

# --- a converged host with a stale rollback reference heals itself -----------
output="$(run_wrapper MOCK_CONTAINER_IMAGE="$EXPECTED_REFERENCE" MOCK_READINESS=up \
    MOCK_LKG="$PREVIOUS_SHA" 2>&1)" ||
    fail "A converged host with a stale rollback reference must reconcile and succeed."
assert_contains "$output" "last known good image is still $PREVIOUS_SHA" \
    "The wrapper must report the stale rollback reference."
assert_contains "$output" "reconciled to $DESIRED_SHA" "The wrapper must report the reconciliation."
assert_absent "$output" "Nothing to deploy" "A reconciling run is not a plain no-op."
calls="$(cat "$work_directory/calls.log")"
assert_absent "$calls" "deploy-api" "Reconciliation must never redeploy."
assert_count "$calls" "put-parameter" 1 "Reconciliation must write the rollback reference exactly once."
assert_contains "$calls" "put-parameter --region ap-northeast-1 --name $LAST_KNOWN_GOOD_PARAMETER --value $DESIRED_SHA --type String --overwrite" \
    "Reconciliation must record the desired release."

# --- a failed reconciliation write fails closed without redeploying ----------
output="$(run_wrapper MOCK_CONTAINER_IMAGE="$EXPECTED_REFERENCE" MOCK_READINESS=up \
    MOCK_LKG="$PREVIOUS_SHA" MOCK_PUT_PARAMETER_STATUS=1 2>&1)" &&
    fail "A failed reconciliation write must fail the run."
assert_contains "$output" "could not be recorded" "The wrapper must report the failed write."
calls="$(cat "$work_directory/calls.log")"
assert_absent "$calls" "deploy-api" "A failed reconciliation must not redeploy."

# --- an unreadable rollback reference on the converged path fails closed -----
output="$(run_wrapper MOCK_CONTAINER_IMAGE="$EXPECTED_REFERENCE" MOCK_READINESS=up \
    MOCK_MISSING_PARAMETER="$LAST_KNOWN_GOOD_PARAMETER" 2>&1)" &&
    fail "An unreadable rollback reference must fail closed."
assert_contains "$output" "Unable to read" "The wrapper must report the unreadable parameter."
calls="$(cat "$work_directory/calls.log")"
assert_absent "$calls" "deploy-api" "An unreadable rollback reference must not redeploy."

# --- the desired release is present but unhealthy: fail closed ---------------
output="$(run_wrapper MOCK_CONTAINER_IMAGE="$EXPECTED_REFERENCE" MOCK_READINESS=down 2>&1)" &&
    fail "An unhealthy converged host must fail closed."
assert_contains "$output" "is not ready" "The wrapper must report the readiness failure."
calls="$(cat "$work_directory/calls.log")"
assert_absent "$calls" "deploy-api" "A readiness failure must not trigger a redeployment."
assert_absent "$calls" "put-parameter" "A readiness failure must not rewrite deployment state."
assert_absent "$calls" "last-known-good" "A readiness failure must not even reconcile the rollback reference."

output="$(run_wrapper MOCK_CONTAINER_IMAGE="$EXPECTED_REFERENCE" MOCK_CONTAINER_RUNNING=false 2>&1)" &&
    fail "A stopped container on the desired release must fail closed."
assert_contains "$output" "is not running" "The wrapper must report the stopped container."
calls="$(cat "$work_directory/calls.log")"
assert_absent "$calls" "deploy-api" "A stopped container must not trigger a redeployment."
assert_absent "$calls" "put-parameter" "A stopped container must not rewrite deployment state."

# --- a first deployment with no container present ---------------------------
output="$(run_wrapper MOCK_CONTAINER_EXISTS=false 2>&1)" ||
    fail "A missing container must not block the first deployment."
assert_contains "$output" "Deploying $DESIRED_SHA" "The first deployment must proceed."

# --- deployment failure must never advance the last known good image --------
output="$(run_wrapper MOCK_DEPLOY_STATUS=7 2>&1)" &&
    fail "A failed deployment must not succeed."
assert_contains "$output" "failed with exit code 7" "The wrapper must surface the deployment exit code."
assert_contains "$output" "last known good image SHA is left unchanged" \
    "The wrapper must state that the rollback reference is untouched."
calls="$(cat "$work_directory/calls.log")"
assert_absent "$calls" "put-parameter" "A failed deployment must not record a last known good image."

status=0
run_wrapper MOCK_DEPLOY_STATUS=7 >/dev/null 2>&1 || status=$?
[[ "$status" -eq 7 ]] || fail "The wrapper must preserve the deployment exit code (got $status)."

# --- desired image SHA validation -------------------------------------------
for invalid_sha in "latest" "5482D650D8CDC22DADC8B3AC96C056D2C8713AFB" "5482d65" ""; do
    run_wrapper MOCK_DESIRED="$invalid_sha" >/dev/null 2>&1 &&
        fail "The desired image SHA must be rejected: '$invalid_sha'"
    calls="$(cat "$work_directory/calls.log")"
    assert_absent "$calls" "deploy-api" "An invalid desired SHA must not deploy."
done

output="$(run_wrapper MOCK_MISSING_PARAMETER="/ec-portfolio/demo/deploy/desired-image-sha" 2>&1)" &&
    fail "An unreadable desired image SHA must fail closed."
assert_contains "$output" "Unable to read" "The wrapper must report the unreadable parameter."

output="$(run_wrapper MOCK_ACCOUNT="12345" 2>&1)" &&
    fail "A malformed account id must fail closed."
assert_contains "$output" "AWS account id" "The wrapper must reject a malformed account id."

# --- runtime parameter validation -------------------------------------------
runtime_rejects() {
    local description="$1"
    local expected="$2"
    shift 2
    local rejected_output

    rejected_output="$(run_wrapper "$@" 2>&1)" && fail "$description must fail closed."
    assert_contains "$rejected_output" "$expected" "$description must be reported."
    calls="$(cat "$work_directory/calls.log")"
    assert_absent "$calls" "deploy-api" "$description must not deploy."
    assert_absent "$calls" "put-parameter" "$description must not rewrite deployment state."
}

runtime_rejects "A non numeric database port" "database port" MOCK_DB_PORT="three-three-zero-six"
runtime_rejects "An out of range database port" "between 1 and 65535" MOCK_DB_PORT="70000"
runtime_rejects "A malformed database host" "database host" MOCK_DB_HOST="demo db;rm -rf /"
runtime_rejects "A malformed database name" "database name" MOCK_DB_NAME="ec portfolio"
runtime_rejects "A malformed database username" "database username" MOCK_DB_USERNAME="ec-admin!"
runtime_rejects "An empty CORS allowlist" "returned no value" MOCK_CORS=""
runtime_rejects "A CORS entry without a scheme" "CORS allowlist" \
    MOCK_CORS="http://127.0.0.1:5174,d39sletn97e89c.cloudfront.net"
runtime_rejects "A missing runtime parameter" "Unable to read" \
    MOCK_MISSING_PARAMETER="/ec-portfolio/demo/runtime/db-name"

# --- the host deployment lock is taken before any state change ---------------
output="$(run_wrapper 2>&1)" || fail "A deployment must succeed when the lock is free."
calls="$(cat "$work_directory/calls.log")"
assert_contains "$calls" "flock --nonblock" "The lock must be acquired without waiting."
lock_line="$(printf '%s\n' "$calls" | grep -n -F "flock --nonblock" | head -n 1 | cut -d: -f1)"
deploy_line="$(printf '%s\n' "$calls" | grep -n -F "deploy-api" | head -n 1 | cut -d: -f1)"
[[ -n "$lock_line" && -n "$deploy_line" && "$lock_line" -lt "$deploy_line" ]] ||
    fail "The lock must be acquired before the deployment script runs."

# --- a busy lock fails closed and changes nothing ----------------------------
output="$(run_wrapper MOCK_FLOCK_STATUS=1 2>&1)" &&
    fail "A deployment must fail closed when the host lock is already held."
assert_contains "$output" "Another deployment is already running on this host" \
    "The busy lock must be reported."
assert_contains "$output" "Refusing to run concurrently" "The refusal must be explicit."
calls="$(cat "$work_directory/calls.log")"
assert_absent "$calls" "deploy-api" "A busy lock must not deploy."
assert_absent "$calls" "put-parameter" "A busy lock must not rewrite deployment state."
assert_absent "$calls" "get-parameter" "A busy lock must not even read deployment state."

# A converged host still writes the rollback reference, so it must lock too.
output="$(run_wrapper MOCK_CONTAINER_IMAGE="$EXPECTED_REFERENCE" MOCK_READINESS=up \
    MOCK_LKG="$PREVIOUS_SHA" MOCK_FLOCK_STATUS=1 2>&1)" &&
    fail "The reconcile only path must also respect the host lock."
assert_contains "$output" "Another deployment is already running on this host" \
    "The reconcile path must report the busy lock."
calls="$(cat "$work_directory/calls.log")"
assert_absent "$calls" "put-parameter" "A busy lock must not reconcile the rollback reference."

# --- static contract: no forbidden runtime behaviour ------------------------
for forbidden in "--with-decryption" "master-password" "auth-jwt-secret" ":latest" \
    "send-command" "start-instances" "ec2 " "DB_PASSWORD=" "APP_AUTH_JWT_SECRET="; do
    grep -Fq -- "$forbidden" "$WRAPPER_SCRIPT" &&
        fail "The wrapper must not reference: $forbidden"
done

# --- contract: the EC2 IAM policy must match what the wrapper actually uses --
# A parameter the wrapper reads but the instance role cannot read is an
# AccessDenied that only shows up on the host, mid-deployment. Resolve both
# sides down to literal parameter paths and compare them as sets.
readonly TERRAFORM_DIRECTORY="$SCRIPT_DIRECTORY/../../terraform/demo"
readonly IAM_FILE="$TERRAFORM_DIRECTORY/iam.tf"

# Maps a terraform aws_ssm_parameter resource name to its literal path.
terraform_parameter_path() {
    local resource_name="$1"
    local name_expression

    name_expression="$(
        awk -v resource="$resource_name" '
            $0 ~ "^resource \"aws_ssm_parameter\" \"" resource "\" \\{" { inside = 1; next }
            inside && /^}/ { exit }
            inside && /^[[:space:]]*name[[:space:]]*=/ { print; exit }
        ' "$TERRAFORM_DIRECTORY"/*.tf
    )"
    [[ -n "$name_expression" ]] || fail "No aws_ssm_parameter resource named: $resource_name"

    printf '%s' "$name_expression" |
        sed -e 's/^[[:space:]]*name[[:space:]]*=[[:space:]]*"//' -e 's/"[[:space:]]*$//' \
            -e 's|${local.deploy_state_prefix}|/ec-portfolio/demo/deploy|' \
            -e 's|${local.runtime_parameter_prefix}|/ec-portfolio/demo/runtime|'
}

# Resolves a wrapper variable such as DESIRED_IMAGE_SHA_PARAMETER to its value.
wrapper_parameter_path() {
    local variable_name="$1"
    local value

    value="$(sed -n "s/^readonly ${variable_name}=\"\\(.*\\)\"$/\\1/p" "$WRAPPER_SCRIPT")"
    [[ -n "$value" ]] || fail "No readonly parameter path named: $variable_name"
    printf '%s' "$value"
}

# Every parameter the wrapper reads, resolved from its read_required_parameter calls.
wrapper_read_paths="$(
    grep -oE 'read_required_parameter "\$[A-Z_]+"' "$WRAPPER_SCRIPT" |
        sed -e 's/read_required_parameter "\$//' -e 's/"$//' | sort -u |
        while read -r variable_name; do
            wrapper_parameter_path "$variable_name"
            printf '\n'
        done | sort -u
)"

# Every parameter the wrapper writes, resolved from its put-parameter call.
wrapper_write_paths="$(
    grep -oE '\-\-name "\$[A-Z_]+"' "$WRAPPER_SCRIPT" |
        sed -e 's/--name "\$//' -e 's/"$//' | sort -u |
        while read -r variable_name; do
            wrapper_parameter_path "$variable_name"
            printf '\n'
        done | sort -u
)"

# The resource lists of the two statements in aws_iam_role_policy.ec2_deployment_state.
iam_statement_paths() {
    local statement_sid="$1"

    awk -v sid="$statement_sid" '
        /resource "aws_iam_role_policy" "ec2_deployment_state"/ { inside_policy = 1 }
        inside_policy && $0 ~ "Sid[[:space:]]*=[[:space:]]*\"" sid "\"" { inside_statement = 1; next }
        inside_statement && /^      \},/ { exit }
        inside_statement && /aws_ssm_parameter\./ { print }
    ' "$IAM_FILE" |
        grep -oE 'aws_ssm_parameter\.[a-z_]+' | sed 's/aws_ssm_parameter\.//' | sort -u |
        while read -r resource_name; do
            terraform_parameter_path "$resource_name"
            printf '\n'
        done | sort -u
}

iam_read_paths="$(iam_statement_paths "ReadDeploymentState")"
iam_write_paths="$(iam_statement_paths "RecordLastKnownGoodImage")"

[[ -n "$wrapper_read_paths" ]] || fail "Could not resolve the parameters the wrapper reads."
[[ -n "$iam_read_paths" ]] || fail "Could not resolve the ReadDeploymentState resources."

if [[ "$wrapper_read_paths" != "$iam_read_paths" ]]; then
    printf 'wrapper reads:\n%s\n\nIAM ReadDeploymentState allows:\n%s\n' \
        "$wrapper_read_paths" "$iam_read_paths" >&2
    fail "The parameters the wrapper reads and the EC2 IAM read grants must match exactly."
fi

if [[ "$wrapper_write_paths" != "$iam_write_paths" ]]; then
    printf 'wrapper writes:\n%s\n\nIAM RecordLastKnownGoodImage allows:\n%s\n' \
        "$wrapper_write_paths" "$iam_write_paths" >&2
    fail "The parameters the wrapper writes and the EC2 IAM write grants must match exactly."
fi

# The rollback reference is read on the converged path and written after a
# deployment, so it must appear on both sides. This is the B1 regression.
assert_contains "$wrapper_read_paths" "$LAST_KNOWN_GOOD_PARAMETER" \
    "The wrapper must read the last known good image."
assert_contains "$iam_read_paths" "$LAST_KNOWN_GOOD_PARAMETER" \
    "The EC2 role must be allowed to read the last known good image."
assert_contains "$iam_write_paths" "$LAST_KNOWN_GOOD_PARAMETER" \
    "The EC2 role must be allowed to write the last known good image."

# The GitHub deploy role must never gain access to the rollback reference.
readonly BACKEND_DEPLOY_FILE="$TERRAFORM_DIRECTORY/github_actions_backend_deploy.tf"
runtime_policy_document="$(
    awk '/data "aws_iam_policy_document" "github_backend_deploy_runtime"/ { inside = 1 }
         inside { print }
         inside && /^}/ { exit }' "$BACKEND_DEPLOY_FILE"
)"
for forbidden in "last_known_good" "last-known-good" "GetParameter" "PutParameter" \
    "StartInstances" "ListCommands" "CancelCommand" "GetDocument" "DescribeDocument"; do
    assert_absent "$runtime_policy_document" "$forbidden" \
        "The GitHub runtime deploy policy must not grant: $forbidden"
done

printf '[deploy-from-ssm-test] PASS\n'
