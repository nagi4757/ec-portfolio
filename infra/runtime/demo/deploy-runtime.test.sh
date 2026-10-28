#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly DEPLOY_SCRIPT="$SCRIPT_DIRECTORY/deploy-runtime.sh"

readonly VALID_INSTANCE_ID="i-0123456789abcdef0"

work_directory=""

lock_holder_pid=""

cleanup() {
    local exit_code=$?
    trap - EXIT
    [[ -z "$lock_holder_pid" ]] || kill "$lock_holder_pid" 2>/dev/null || true
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-deploy-runtime-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup EXIT

fail() {
    printf '[deploy-runtime-test] FAIL: %s\n' "$*" >&2
    exit 1
}

# The haystack is handed to grep as a here-string, not through a pipe: once grep
# -q has its match it stops reading, and under pipefail a writer still feeding a
# haystack larger than the pipe buffer would die of SIGPIPE and flip the result.
assert_contains() {
    grep -Fq -- "$2" <<<"$1" || fail "$3 (expected to find: $2)"
}

assert_absent() {
    grep -Fq -- "$2" <<<"$1" && fail "$3 (unexpectedly found: $2)"
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

case "${1-} ${2-}" in
    "ssm describe-instance-information")
        printf '%s\n' "${MOCK_PING_STATUS:-Online}"
        ;;
    "ssm send-command")
        if [[ "${MOCK_SEND_COMMAND_FAIL:-false}" == "true" ]]; then
            printf 'send-command failed\n' >&2
            exit 254
        fi
        printf '%s\n' "${MOCK_COMMAND_ID:-cmd-0000000000000000}"
        ;;
    "ssm get-command-invocation")
        sequence_file="$MOCK_SEQUENCE_FILE"
        index=0
        [[ -f "$sequence_file.idx" ]] && index="$(cat "$sequence_file.idx")"
        status="$(sed -n "$((index + 1))p" "$sequence_file")"
        [[ -n "$status" ]] || status="$(tail -n 1 "$sequence_file")"
        echo "$((index + 1))" >"$sequence_file.idx"
        printf '{"Status":"%s","StandardOutputContent":"deployed %s","StandardErrorContent":"failure detail"}\n' \
            "$status" "${MOCK_DESIRED_SHA:-abc}"
        ;;
    *)
        printf 'unexpected aws invocation: %s\n' "$*" >&2
        exit 64
        ;;
esac
MOCK

    chmod 755 "$mock_directory/aws"
    PATH="$mock_directory:$PATH"
    export PATH
}

run_deploy() {
    MOCK_CALL_LOG="$work_directory/calls.log"
    MOCK_SEQUENCE_FILE="$work_directory/sequence.txt"
    : >"$MOCK_CALL_LOG"
    rm -f "$MOCK_SEQUENCE_FILE.idx"
    export MOCK_CALL_LOG MOCK_SEQUENCE_FILE

    env \
        EC2_INSTANCE_ID="$VALID_INSTANCE_ID" \
        DEPLOY_POLL_ATTEMPTS=3 \
        DEPLOY_POLL_INTERVAL_SECONDS=0 \
        "$@" \
        bash "$DEPLOY_SCRIPT" deploy
}

work_directory="$(mktemp -d /tmp/ec-portfolio-deploy-runtime-test.XXXXXX)"
install_mocks

# Every payload carries the release that installs it; the CI workflow on main
# sets all of these. GITHUB_RUN_ID is set far above every run number used here,
# so a payload that ordered releases by it would fail the ordering cases.
readonly TEST_RUN_NUMBER="420"
readonly TEST_SHA="0123456789abcdef0123456789abcdef01234567"
readonly TEST_WORKFLOW_REF="nagi4757/ec-portfolio/.github/workflows/ci.yml@refs/heads/main"
export GITHUB_RUN_NUMBER="$TEST_RUN_NUMBER" GITHUB_SHA="$TEST_SHA" GITHUB_WORKFLOW_REF="$TEST_WORKFLOW_REF"
export GITHUB_RUN_ID="99999999999"

# --- an offline host is a soft no-op, never installs or sends a command -----
printf '%s\n' "Success" >"$work_directory/sequence.txt"
output="$(run_deploy MOCK_PING_STATUS=ConnectionLost 2>&1)" ||
    fail "An offline host must not fail the job."
assert_contains "$output" "is not Online" "The offline host must be reported."
assert_contains "$output" "Phase 5F-3" "The offline host must defer to boot convergence."
calls="$(cat "$work_directory/calls.log")"
assert_absent "$calls" "send-command" "An offline host must never receive SendCommand."
assert_count "$calls" "ssm send-command" 0 "An offline host must issue exactly zero SendCommand calls."

# --- a host with no managed-instance record is also a soft no-op ------------
printf '%s\n' "Success" >"$work_directory/sequence.txt"
output="$(run_deploy MOCK_PING_STATUS=None 2>&1)" ||
    fail "A host with no managed-instance record must not fail the job."
assert_contains "$output" "is not Online" "A missing managed-instance record must be reported."
calls="$(cat "$work_directory/calls.log")"
assert_absent "$calls" "send-command" "A missing managed-instance record must never receive SendCommand."
assert_count "$calls" "ssm send-command" 0 \
    "A missing managed-instance record must issue exactly zero SendCommand calls."

# --- an online host that deploys successfully -------------------------------
printf '%s\n' "Success" >"$work_directory/sequence.txt"
output="$(run_deploy MOCK_PING_STATUS=Online 2>&1)" ||
    fail "A successful deployment must succeed."
assert_contains "$output" "Deployment command succeeded." "Success must be reported."
calls="$(cat "$work_directory/calls.log")"

# --- the SendCommand contract is exact --------------------------------------
assert_count "$calls" "ssm send-command" 1 "An online host must receive exactly one SendCommand."
send_command_call="$(printf '%s\n' "$calls" | grep -F "ssm send-command" | head -n 1)"
assert_contains "$send_command_call" "--document-name AWS-RunShellScript" \
    "SendCommand must target the AWS owned AWS-RunShellScript document."
assert_contains "$send_command_call" "--instance-ids $VALID_INSTANCE_ID" \
    "SendCommand must target exactly the configured instance."
assert_contains "$send_command_call" "--region ap-northeast-1" \
    "SendCommand must be issued in the expected region."
assert_absent "$send_command_call" "--targets" \
    "SendCommand must not fan out to a tag based target set."

describe_call="$(printf '%s\n' "$calls" | grep -F "ssm describe-instance-information" | head -n 1)"
assert_contains "$describe_call" "--region ap-northeast-1" \
    "The managed instance lookup must use the expected region."
assert_contains "$describe_call" "Key=InstanceIds,Values=$VALID_INSTANCE_ID" \
    "The managed instance lookup must be scoped to the configured instance."

invocation_call="$(printf '%s\n' "$calls" | grep -F "ssm get-command-invocation" | head -n 1)"
assert_contains "$invocation_call" "--region ap-northeast-1" \
    "The invocation lookup must use the expected region."
assert_contains "$invocation_call" "--instance-id $VALID_INSTANCE_ID" \
    "The invocation lookup must be scoped to the configured instance."

# The role has no ssm:ListCommands or ssm:CancelCommand grant, so the
# orchestrator must never call them.
assert_absent "$calls" "ssm list-commands" "The orchestrator must not call ListCommands."
assert_absent "$calls" "ssm cancel-command" "The orchestrator must not call CancelCommand."

# --- an online host whose command reaches InProgress before Success ---------
printf '%s\nInProgress\nSuccess\n' "Pending" >"$work_directory/sequence.txt"
output="$(run_deploy MOCK_PING_STATUS=Online 2>&1)" ||
    fail "A deployment that converges after polling must still succeed."
assert_contains "$output" "Deployment command succeeded." "Eventual success must be reported."

# --- a failed remote command fails closed ------------------------------------
printf '%s\n' "Failed" >"$work_directory/sequence.txt"
output="$(run_deploy MOCK_PING_STATUS=Online 2>&1)" &&
    fail "A failed remote command must fail the job."
assert_contains "$output" "finished with status Failed" "The failure status must be reported."
assert_contains "$output" "failure detail" "The remote stderr must be surfaced."

# --- a command stuck in progress forever times out and fails closed ---------
printf '%s\n' "InProgress" >"$work_directory/sequence.txt"
output="$(run_deploy MOCK_PING_STATUS=Online 2>&1)" &&
    fail "A command that never reaches a terminal status must time out and fail."
assert_contains "$output" "Timed out waiting" "The timeout must be reported."

# --- SendCommand itself failing (e.g. permission error) fails closed --------
printf '%s\n' "Success" >"$work_directory/sequence.txt"
output="$(run_deploy MOCK_PING_STATUS=Online MOCK_SEND_COMMAND_FAIL=true 2>&1)" &&
    fail "A SendCommand API failure must fail the job."
assert_contains "$output" "Unable to send the deployment command" "The SendCommand failure must be reported."

# --- instance id validation ---------------------------------------------------
output="$(env EC2_INSTANCE_ID="not-an-instance" bash "$DEPLOY_SCRIPT" deploy 2>&1)" &&
    fail "A malformed EC2_INSTANCE_ID must be rejected."
assert_contains "$output" "does not match the expected instance id format" \
    "The malformed instance id must be reported."

# --- static contract: no forbidden runtime behaviour ------------------------
script_contents="$(cat "$DEPLOY_SCRIPT")"
for forbidden in "raw.githubusercontent" "curl " "start-instances" "run-instances" \
    "start-db-instance" ":latest" "GetDocument" "DescribeDocument"; do
    grep -Fq -- "$forbidden" <<<"$script_contents" &&
        fail "deploy-runtime.sh must not reference: $forbidden"
done
for artifact_variable in WRAPPER_FILE DEPLOY_FILE INSTALLER_FILE UNIT_FILE; do
    assert_contains "$script_contents" "\$$artifact_variable checksum mismatch" \
        "The remote payload must verify every artifact before use."
done
assert_absent "$script_contents" "CONVERGED_READINESS_ATTEMPTS=36" \
    "CI must not override the wrapper's default readiness attempts."
assert_absent "$script_contents" "CONVERGED_READINESS_INTERVAL_SECONDS=5" \
    "CI must not override the wrapper's default readiness interval."

# --- the deployment timeout contract -----------------------------------------
# Four budgets have to stay ordered:
#
#   configured waits  <  CI poll budget  <  OIDC credential  <  job timeout
#
# If the poll budget is too short, CI reports a timeout for a deployment that
# then goes on to succeed, and the recorded state stops matching the host. If
# the job timeout is not the largest, the job is cut off before the credential
# expires and the deployment ends with no verdict at all.
#
# The first figure is the sum of the waits deploy-api.sh explicitly configures,
# read from that script rather than restated here. It is not an upper bound on a
# deployment: docker pull, the ECR login, the AWS API calls and the SSM agent
# pickup have no script-level timeout. The gap between it and the poll budget is
# operational headroom for that unbounded work, which is why the headroom is
# asserted as a minimum rather than left to chance.
readonly DEPLOY_API_SCRIPT_FILE="$SCRIPT_DIRECTORY/deploy-api.sh"
readonly WORKFLOW_FILE="$SCRIPT_DIRECTORY/../../../.github/workflows/ci.yml"
readonly BACKEND_ROLE_FILE="$SCRIPT_DIRECTORY/../../terraform/demo/github_actions_backend_deploy.tf"

# Policy value owned by this test: how much room the unbounded work must have
# above the configured waits, and the credential above the poll budget.
readonly MIN_OPERATIONAL_HEADROOM_SECONDS=180

read_constant() {
    local file="$1"
    local name="$2"
    local value

    value="$(sed -n "s/^readonly ${name}=\\([0-9]\\{1,\\}\\)$/\\1/p" "$file")"
    [[ -n "$value" ]] || fail "Could not read the $name constant from $file"
    printf '%s' "$value"
}

# Reads a numeric key from the deploy-api job block of the workflow.
read_deploy_job_value() {
    local key="$1"
    local value

    value="$(
        awk -v key="$key" '
            /^  deploy-api:/ { inside = 1; next }
            inside && /^  [a-z]/ { exit }
            inside && $0 ~ "^[[:space:]]+" key ":[[:space:]]*[0-9]+[[:space:]]*$" {
                sub(/^.*:[[:space:]]*/, "")
                sub(/[[:space:]]*$/, "")
                print
                exit
            }
        ' "$WORKFLOW_FILE"
    )"
    [[ -n "$value" ]] || fail "Could not read $key from the deploy-api job in $WORKFLOW_FILE"
    printf '%s' "$value"
}

# Reads max_session_duration from the backend deploy role, so the credential the
# workflow asks for cannot silently exceed what the role is allowed to issue.
read_role_max_session_duration() {
    local value

    value="$(
        awk '
            /resource "aws_iam_role" "github_backend_deploy"/ { inside = 1 }
            inside && /^[[:space:]]*max_session_duration[[:space:]]*=/ {
                sub(/^.*=[[:space:]]*/, "")
                sub(/[[:space:]]*$/, "")
                print
                exit
            }
            inside && /^}/ { exit }
        ' "$BACKEND_ROLE_FILE"
    )"
    [[ "$value" =~ ^[0-9]+$ ]] ||
        fail "Could not read max_session_duration from $BACKEND_ROLE_FILE"
    printf '%s' "$value"
}

poll_budget=$(($(read_constant "$DEPLOY_SCRIPT" "DEFAULT_POLL_ATTEMPTS") *
    $(read_constant "$DEPLOY_SCRIPT" "DEFAULT_POLL_INTERVAL_SECONDS")))

# Every wait deploy-api.sh configures. Each readiness attempt costs its curl
# timeout as well as its interval, and the outgoing container gets a stop grace
# on every deployment after the first.
configured_wait_budget=$((
    $(read_constant "$DEPLOY_API_SCRIPT_FILE" "VALKEY_HEALTH_ATTEMPTS") *
    $(read_constant "$DEPLOY_API_SCRIPT_FILE" "VALKEY_HEALTH_INTERVAL_SECONDS") +
    2 * $(read_constant "$DEPLOY_API_SCRIPT_FILE" "READINESS_ATTEMPTS") *
    ($(read_constant "$DEPLOY_API_SCRIPT_FILE" "READINESS_INTERVAL_SECONDS") +
        $(read_constant "$DEPLOY_API_SCRIPT_FILE" "READINESS_CURL_MAX_TIME_SECONDS")) +
    $(read_constant "$DEPLOY_API_SCRIPT_FILE" "API_STOP_GRACE_SECONDS")
))

oidc_credential_seconds="$(read_deploy_job_value "role-duration-seconds")"
job_timeout_seconds=$(($(read_deploy_job_value "timeout-minutes") * 60))
role_max_session_seconds="$(read_role_max_session_duration)"

((poll_budget > configured_wait_budget)) ||
    fail "The CI poll budget (${poll_budget}s) must exceed the configured deploy-api.sh waits (${configured_wait_budget}s)."
(((poll_budget - configured_wait_budget) >= MIN_OPERATIONAL_HEADROOM_SECONDS)) ||
    fail "The CI poll budget (${poll_budget}s) must leave at least ${MIN_OPERATIONAL_HEADROOM_SECONDS}s above the configured waits (${configured_wait_budget}s) for docker pull and the AWS calls."
((poll_budget < oidc_credential_seconds)) ||
    fail "The CI poll budget (${poll_budget}s) must stay inside the OIDC credential duration (${oidc_credential_seconds}s)."
(((oidc_credential_seconds - poll_budget) >= MIN_OPERATIONAL_HEADROOM_SECONDS)) ||
    fail "The OIDC credential duration (${oidc_credential_seconds}s) must leave at least ${MIN_OPERATIONAL_HEADROOM_SECONDS}s above the poll budget (${poll_budget}s)."
((job_timeout_seconds > oidc_credential_seconds)) ||
    fail "The deploy job timeout (${job_timeout_seconds}s) must exceed the OIDC credential duration (${oidc_credential_seconds}s)."
((oidc_credential_seconds <= role_max_session_seconds)) ||
    fail "The requested OIDC credential duration (${oidc_credential_seconds}s) exceeds max_session_duration on the backend deploy role (${role_max_session_seconds}s)."

# The ordering assertions above cannot catch a formula that leaves a wait out:
# under-counting shrinks the budget, which only makes the ordering easier to
# satisfy. That is exactly how the previous 420s figure went unnoticed. Assert
# instead that every timing constant deploy-api.sh defines is referenced here,
# so a newly added or forgotten wait breaks this test rather than hiding in it.
deploy_api_timing_constants="$(
    grep -oE '^readonly [A-Z_]+(_ATTEMPTS|_SECONDS)=[0-9]+$' "$DEPLOY_API_SCRIPT_FILE" |
        sed -e 's/^readonly //' -e 's/=.*$//' | sort -u
)"
[[ -n "$deploy_api_timing_constants" ]] ||
    fail "Could not enumerate the timing constants in $DEPLOY_API_SCRIPT_FILE"

while read -r timing_constant; do
    [[ -n "$timing_constant" ]] || continue
    grep -Fq -- "\"$timing_constant\"" "${BASH_SOURCE[0]}" ||
        fail "The configured wait budget must account for $timing_constant, which deploy-api.sh defines."
done <<<"$deploy_api_timing_constants"

# --- the deploy job must run every deployment contract suite -----------------
# The wrapper suite carries the IAM/wrapper parameter contract, the flock
# fail-closed behaviour and the reconcile/readiness rules; the deploy-api suite
# carries the signal-path rollback. Running only the orchestrator suite in CI
# would leave all of that unverified before a deployment.
workflow_contents="$(cat "$WORKFLOW_FILE")"
for required_suite in "infra/runtime/demo/deploy-api.test.sh" \
    "infra/runtime/demo/deploy-api-from-ssm.test.sh" \
    "infra/runtime/demo/install-api-convergence.test.sh" \
    "infra/runtime/demo/deploy-runtime.test.sh"; do
    assert_contains "$workflow_contents" "$required_suite" \
        "The deploy-api job must run $required_suite"
done

# --- the frontend must not ship a release the API did not take ----------------
# A Flyway migration change fails the guard inside build-and-push-api, which skips
# deploy-api. While deploy-frontends depended only on the build jobs it went out
# regardless, so the storefront began calling endpoints the running backend did not
# have. The bdc3828 release did exactly that. The job's own needs block is read
# rather than grepping the whole file, so a mention of deploy-api anywhere else
# cannot satisfy this.
read_job_needs() {
    awk -v job="  ${1}:" '
        $0 == job { inside = 1; next }
        inside && /^  [a-z]/ { exit }
        inside && /^    needs:/ { collecting = 1; next }
        collecting && /^      - / { sub(/^      - /, ""); print; next }
        collecting && !/^      - / { exit }
    ' "$WORKFLOW_FILE"
}

frontend_deploy_needs="$(read_job_needs deploy-frontends)"
[[ -n "$frontend_deploy_needs" ]] ||
    fail "Could not read the needs of deploy-frontends in $WORKFLOW_FILE"
assert_contains "$frontend_deploy_needs" "deploy-api" \
    "deploy-frontends must depend on deploy-api so a blocked API release cannot ship its frontend alone."

# deploy-api must itself stay downstream of the guard, or the dependency above
# proves nothing.
assert_contains "$(read_job_needs deploy-api)" "build-and-push-api" \
    "deploy-api must depend on build-and-push-api, which is where the migration guard runs."

# --- the checksum gate is verified by running the generated remote payload ---
# A static grep proves the text is present, not that the gate actually stops a
# tampered payload. Render the real command list and execute it against a local
# sandbox. The installer itself has a separate behavioral suite; here a fake
# installer isolates the four-artifact orchestration contract.
readonly WRAPPER_FILE="deploy-api-from-ssm.sh"
readonly DEPLOY_FILE="deploy-api.sh"
readonly INSTALLER_FILE="install-api-convergence.sh"
readonly UNIT_FILE="ec-portfolio-api-converge.service"

# Sourcing happens in its own process so the orchestrator's readonly globals and
# its log/fail helpers cannot collide with the ones this test defines.
render_command_json() {
    bash -c 'source "$1"; build_install_and_run_commands' _ "$DEPLOY_SCRIPT"
}

commands_json="$(render_command_json)" ||
    fail "The orchestrator must render its remote command list."
[[ -n "$commands_json" ]] || fail "The rendered command list must not be empty."

# Every checksum comparison must precede mktemp. A mismatched artifact therefore
# cannot create even a temporary payload directory, let alone install or run it.
mktemp_index="$(printf '%s' "$commands_json" | jq -r 'to_entries[] | select(.value | contains("mktemp -d")) | .key')"
[[ "$mktemp_index" =~ ^[0-9]+$ ]] || fail "The payload must create one temporary directory."
for artifact in "$WRAPPER_FILE" "$DEPLOY_FILE" "$INSTALLER_FILE" "$UNIT_FILE"; do
    checksum_index="$(printf '%s' "$commands_json" | jq -r --arg artifact "$artifact" \
        'to_entries[] | select(.value | contains($artifact + " checksum mismatch")) | .key')"
    [[ "$checksum_index" =~ ^[0-9]+$ ]] ||
        fail "The payload must verify $artifact."
    ((checksum_index < mktemp_index)) ||
        fail "$artifact must be verified before any temporary host file is created."
done

render_payload() {
    local sandbox="$1"

    printf '%s' "$commands_json" | jq -r '.[]' |
        sed -e "s|/opt/ec-portfolio/runtime/demo|$sandbox/opt/ec-portfolio/runtime/demo|g" \
            -e "s|/etc/systemd/system|$sandbox/etc/systemd/system|g" \
            -e "s|/var/lock/|$sandbox/var/lock/|g"
}

# Replaces the single in-memory base64 value for one artifact while leaving its
# reviewed SHA256 untouched. The same variable is used for verification and the
# later decode, so bytes that pass the gate are exactly the bytes installed.
tamper_payload() {
    local target_file="$1"
    local payload_variable tampered_b64 line

    case "$target_file" in
    "$WRAPPER_FILE") payload_variable="wrapper_b64" ;;
    "$DEPLOY_FILE") payload_variable="deploy_b64" ;;
    "$INSTALLER_FILE") payload_variable="installer_b64" ;;
    "$UNIT_FILE") payload_variable="unit_b64" ;;
    *) fail "Unknown payload artifact: $target_file" ;;
    esac

    tampered_b64="$(printf '#!/usr/bin/env bash\nexit 0\n' | base64 | tr -d '\n')"

    while IFS= read -r line; do
        if [[ "$line" == "$payload_variable="* ]]; then
            printf "%s='%s'\n" "$payload_variable" "$tampered_b64"
        else
            printf '%s\n' "$line"
        fi
    done
}

install_payload_mocks() {
    local sandbox="$1"
    local mock real_flock

    mkdir -p "$sandbox/bin"

    # Inner `bash installer` is intercepted so this orchestrator suite can run
    # without root or systemd. The dedicated installer suite exercises the real
    # installer twice with fake systemctl.
    cat >"$sandbox/bin/bash" <<'MOCK'
#!/bin/bash
set -euo pipefail
if [[ "${1-}" == */install-api-convergence.sh ]]; then
    [[ "${MOCK_INSTALLER_FAIL:-false}" != "true" ]] || exit 1
    if [[ "${MOCK_INSTALLER_NOOP:-false}" == "true" ]]; then
        printf '%s\n' installer >>"$PAYLOAD_EVENT_LOG"
        exit 0
    fi
    source_directory="$(dirname -- "$1")"
    mkdir -p "$PAYLOAD_RUNTIME_DIRECTORY" "$PAYLOAD_SYSTEMD_DIRECTORY"
    install -m 0755 "$source_directory/deploy-api-from-ssm.sh" "$PAYLOAD_RUNTIME_DIRECTORY/deploy-api-from-ssm.sh"
    install -m 0755 "$source_directory/deploy-api.sh" "$PAYLOAD_RUNTIME_DIRECTORY/deploy-api.sh"
    install -m 0755 "$source_directory/install-api-convergence.sh" "$PAYLOAD_RUNTIME_DIRECTORY/install-api-convergence.sh"
    install -m 0644 "$source_directory/ec-portfolio-api-converge.service" "$PAYLOAD_SYSTEMD_DIRECTORY/ec-portfolio-api-converge.service"
    printf '%s\n' installer >>"$PAYLOAD_EVENT_LOG"
    exit 0
fi
exec /bin/bash "$@"
MOCK
    chmod 755 "$sandbox/bin/bash"

    # The installed wrapper is the real script, so it needs its dependencies on
    # PATH. Recording a call proves the wrapper was reached after the installer.
    for mock in aws curl docker; do
        cat >"$sandbox/bin/$mock" <<'MOCK'
#!/bin/bash
printf '%s\n' "$(basename "$0") $*" >>"$WRAPPER_MARKER"
printf 'wrapper:%s\n' "$(basename "$0")" >>"$PAYLOAD_EVENT_LOG"
exit 1
MOCK
        chmod 755 "$sandbox/bin/$mock"
    done

    # The lock is real: the payload and the installed wrapper contend for the
    # same file as they do on the host. util-linux flock is used where it exists
    # (CI); elsewhere a stand-in calls flock(2) on the inherited descriptor, which
    # locks the open file description it shares with the payload, so the lock
    # outlives the stand-in exactly as with the real tool.
    if real_flock="$(command -v flock)"; then
        ln -s "$real_flock" "$sandbox/bin/flock"
    else
        cat >"$sandbox/bin/flock" <<'MOCK'
#!/usr/bin/env python3
import fcntl
import sys

if len(sys.argv) != 3 or sys.argv[1] != "--nonblock" or not sys.argv[2].isdigit():
    sys.exit(64)
try:
    fcntl.flock(int(sys.argv[2]), fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(1)
MOCK
        chmod 755 "$sandbox/bin/flock"
    fi
    mkdir -p "$sandbox/var/lock"
}

sandbox_lock_file() {
    printf '%s' "$1/var/lock/ec-portfolio-demo-deploy.lock"
}

# hold_lock <sandbox>: holds the host deployment lock from another process, as a
# running deployment or install does, until release_lock.
hold_lock() {
    local ready="$work_directory/lock-ready"

    rm -f "$ready"
    python3 -c 'import fcntl, sys, time
lock = open(sys.argv[1], "w")
fcntl.flock(lock, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(300)' "$(sandbox_lock_file "$1")" "$ready" &
    lock_holder_pid=$!
    for _ in $(seq 1 200); do
        [[ -e "$ready" ]] && return 0
        sleep 0.05
    done
    fail "The test could not take the deployment lock."
}

release_lock() {
    kill "$lock_holder_pid" 2>/dev/null || true
    wait "$lock_holder_pid" 2>/dev/null || true
    lock_holder_pid=""
}

release_record() {
    printf '%s' "$1/opt/ec-portfolio/runtime/demo/.runtime-release"
}

run_payload() {
    local sandbox="$1"
    local payload="$2"

    env \
        PATH="$sandbox/bin:$PATH" \
        WRAPPER_MARKER="$sandbox/wrapper-ran.log" \
        PAYLOAD_EVENT_LOG="$sandbox/payload-events.log" \
        PAYLOAD_RUNTIME_DIRECTORY="$sandbox/opt/ec-portfolio/runtime/demo" \
        PAYLOAD_SYSTEMD_DIRECTORY="$sandbox/etc/systemd/system" \
        DEPLOY_LOCK_FILE="$(sandbox_lock_file "$sandbox")" \
        MOCK_INSTALLER_FAIL="${MOCK_INSTALLER_FAIL:-false}" \
        MOCK_INSTALLER_NOOP="${MOCK_INSTALLER_NOOP:-false}" \
        /bin/bash -c "$payload"
}

payload_sandbox() {
    local sandbox
    sandbox="$(mktemp -d "$work_directory/payload.XXXXXX")"
    install_payload_mocks "$sandbox"
    : >"$sandbox/wrapper-ran.log"
    : >"$sandbox/payload-events.log"
    printf '%s' "$sandbox"
}

installed_directory() {
    printf '%s' "$1/opt/ec-portfolio/runtime/demo"
}

# An untampered payload installs all four artifacts, runs the installer first,
# and then reaches the installed wrapper without a CI readiness override.
sandbox="$(payload_sandbox)"
run_payload "$sandbox" "$(render_payload "$sandbox")" >/dev/null 2>&1 || true
installed="$(installed_directory "$sandbox")"
for installed_file in "$WRAPPER_FILE" "$DEPLOY_FILE" "$INSTALLER_FILE"; do
    [[ -f "$installed/$installed_file" ]] ||
        fail "A valid payload must install $installed_file."
    cmp -s "$installed/$installed_file" "$SCRIPT_DIRECTORY/$installed_file" ||
        fail "The installed $installed_file must be byte identical to the reviewed source."
    [[ -x "$installed/$installed_file" ]] ||
        fail "The installed $installed_file must be executable."
done
[[ -f "$sandbox/etc/systemd/system/$UNIT_FILE" ]] ||
    fail "A valid payload must install the systemd unit."
cmp -s "$sandbox/etc/systemd/system/$UNIT_FILE" "$SCRIPT_DIRECTORY/$UNIT_FILE" ||
    fail "The installed unit must be byte identical to the reviewed source."
[[ -s "$sandbox/wrapper-ran.log" ]] ||
    fail "A valid payload must reach the installed wrapper."
first_event="$(sed -n '1p' "$sandbox/payload-events.log")"
second_event="$(sed -n '2p' "$sandbox/payload-events.log")"
[[ "$first_event" == "installer" && "$second_event" == wrapper:* ]] ||
    fail "The installer must succeed before the installed wrapper runs."

# An installer failure must stop the command before the wrapper is reached.
sandbox="$(payload_sandbox)"
output="$(MOCK_INSTALLER_FAIL=true run_payload "$sandbox" "$(render_payload "$sandbox")" 2>&1)" &&
    fail "An installer failure must fail the remote command."
[[ ! -s "$sandbox/wrapper-ran.log" ]] ||
    fail "An installer failure must never reach the wrapper."

# Any single tampered artifact fails before mktemp, installation or execution.
for tampered_file in "$WRAPPER_FILE" "$DEPLOY_FILE" "$INSTALLER_FILE" "$UNIT_FILE"; do
    sandbox="$(payload_sandbox)"
    payload="$(render_payload "$sandbox" | tamper_payload "$tampered_file")"

    output="$(run_payload "$sandbox" "$payload" 2>&1)" &&
        fail "A tampered $tampered_file must fail the remote command."
    assert_contains "$output" "$tampered_file checksum mismatch" \
        "A tampered $tampered_file must be reported as a checksum mismatch."

    [[ ! -e "$(installed_directory "$sandbox")" ]] ||
        fail "A tampered $tampered_file must not create the runtime install directory."
    [[ ! -e "$sandbox/etc/systemd/system/$UNIT_FILE" ]] ||
        fail "A tampered $tampered_file must not install the unit."
    [[ ! -s "$sandbox/wrapper-ran.log" ]] ||
        fail "A tampered $tampered_file must never reach the wrapper."
    [[ ! -s "$sandbox/payload-events.log" ]] ||
        fail "A tampered $tampered_file must never reach the installer or wrapper."
done

# --- release: the main push path, scoped by build-and-push-api ---------------
run_release() {
    MOCK_CALL_LOG="$work_directory/calls.log"
    MOCK_SEQUENCE_FILE="$work_directory/sequence.txt"
    : >"$MOCK_CALL_LOG"
    rm -f "$MOCK_SEQUENCE_FILE.idx"
    export MOCK_CALL_LOG MOCK_SEQUENCE_FILE

    env \
        EC2_INSTANCE_ID="$VALID_INSTANCE_ID" \
        DEPLOY_POLL_ATTEMPTS=3 \
        DEPLOY_POLL_INTERVAL_SECONDS=0 \
        "$@" \
        bash "$DEPLOY_SCRIPT" release
}

printf '%s\n' "Success" >"$work_directory/sequence.txt"

# Nothing to release: no AWS call at all, not even the instance lookup.
output="$(run_release RELEASE_API_CONVERGE=false RELEASE_RUNTIME_PENDING=false 2>&1)" ||
    fail "A release with nothing for the host must succeed."
assert_contains "$output" "Nothing to release to the host" "An empty release must say so."
[[ ! -s "$work_directory/calls.log" ]] || fail "An empty release must make no AWS call."

# An undecided or malformed scope fails closed before any AWS call.
for scope in "RELEASE_API_CONVERGE= RELEASE_RUNTIME_PENDING=false" "RELEASE_API_CONVERGE=false RELEASE_RUNTIME_PENDING=" \
    "RELEASE_API_CONVERGE=TRUE RELEASE_RUNTIME_PENDING=false" "RELEASE_API_CONVERGE=false RELEASE_RUNTIME_PENDING=yes" \
    "RELEASE_API_CONVERGE=1 RELEASE_RUNTIME_PENDING=0"; do
    # shellcheck disable=SC2086
    output="$(run_release $scope 2>&1)" && fail "The scope [$scope] must be refused."
    assert_contains "$output" "must be true or false" "The scope [$scope] must be reported."
    [[ ! -s "$work_directory/calls.log" ]] || fail "The scope [$scope] must be refused before any AWS call."
done
output="$(env -u RELEASE_API_CONVERGE -u RELEASE_RUNTIME_PENDING EC2_INSTANCE_ID="$VALID_INSTANCE_ID" \
    MOCK_CALL_LOG="$work_directory/calls.log" bash "$DEPLOY_SCRIPT" release 2>&1)" &&
    fail "A release without any scope must be refused."
assert_contains "$output" "must be true or false" "A missing scope must be reported."

# API converge, online: the existing install-and-deploy command, which keeps
# SSM's default delivery window exactly as before.
output="$(run_release RELEASE_API_CONVERGE=true RELEASE_RUNTIME_PENDING=false MOCK_PING_STATUS=Online 2>&1)" ||
    fail "An API release to an online host must succeed."
calls="$(cat "$work_directory/calls.log")"
assert_count "$calls" "ssm send-command" 1 "An API release must send exactly one command."
assert_contains "$calls" "--comment ec-portfolio demo API deploy" "An API release must send the deploy command."
assert_absent "$calls" "--timeout-seconds" "The deploy command must keep its existing delivery behaviour."
run_deploy MOCK_PING_STATUS=Online >/dev/null 2>&1 || fail "The deploy command must still succeed."
assert_absent "$(cat "$work_directory/calls.log")" "--timeout-seconds" "deploy must keep its existing delivery behaviour."
[[ "$(printf '%s\n' "$calls" | grep -F "ssm send-command")" == \
    "$(grep -F "ssm send-command" "$work_directory/calls.log")" ]] ||
    fail "release must send exactly the command deploy sends for an API release."

# API and runtime, online: the deploy command installs the runtime too.
output="$(run_release RELEASE_API_CONVERGE=true RELEASE_RUNTIME_PENDING=true MOCK_PING_STATUS=Online 2>&1)" ||
    fail "An API and runtime release to an online host must succeed."
calls="$(cat "$work_directory/calls.log")"
assert_count "$calls" "ssm send-command" 1 "An API and runtime release must send exactly one command."
assert_contains "$calls" "--comment ec-portfolio demo API deploy" "An API and runtime release must send the deploy command."

# API only, offline: deferred to boot convergence, as before.
output="$(run_release RELEASE_API_CONVERGE=true RELEASE_RUNTIME_PENDING=false MOCK_PING_STATUS=Stopped 2>&1)" ||
    fail "An API release to an offline host must be deferred, not fail."
assert_contains "$output" "Phase 5F-3" "An offline API release must defer to boot convergence."
assert_count "$(cat "$work_directory/calls.log")" "ssm send-command" 0 "An offline host must never receive SendCommand."

# API converge with a runtime change, offline: deferred too. By the time release
# runs, a desired image that needed the newer runtime was recorded only after
# install-runtime installed it, so boot convergence starts it on that runtime.
output="$(run_release RELEASE_API_CONVERGE=true RELEASE_RUNTIME_PENDING=true MOCK_PING_STATUS=Stopped 2>&1)" ||
    fail "An API release with a runtime change to an offline host must be deferred, not fail."
assert_contains "$output" "Phase 5F-3" "The offline release must defer to boot convergence."
assert_contains "$output" "recorded only after install-runtime installed it" "The offline release must say why deferring is safe."
assert_count "$(cat "$work_directory/calls.log")" "ssm send-command" 0 "An offline host must never receive SendCommand."

# Runtime only, online: the runtime command, never the deploy command, with a
# delivery timeout so it cannot run late.
output="$(run_release RELEASE_API_CONVERGE=false RELEASE_RUNTIME_PENDING=true MOCK_PING_STATUS=Online 2>&1)" ||
    fail "A runtime-only release to an online host must succeed."
calls="$(cat "$work_directory/calls.log")"
assert_count "$calls" "ssm send-command" 1 "A runtime-only release must send exactly one command."
assert_contains "$calls" "--comment ec-portfolio demo runtime install" "A runtime-only release must send the runtime command."
assert_contains "$calls" "--timeout-seconds 30 --parameters" "A runtime command must carry the SSM delivery timeout."
assert_absent "$calls" "--comment ec-portfolio demo API deploy" "A runtime-only release must never send the deploy command."
assert_contains "$output" "Runtime installation command sent" "The runtime command must be reported."

# Runtime only, offline: stays pending, the job succeeds.
output="$(run_release RELEASE_API_CONVERGE=false RELEASE_RUNTIME_PENDING=true MOCK_PING_STATUS=ConnectionLost 2>&1)" ||
    fail "A runtime-only release to an offline host must stay pending, not fail."
assert_contains "$output" "stays pending" "An offline runtime-only release must say it stays pending."
assert_count "$(cat "$work_directory/calls.log")" "ssm send-command" 0 "An offline host must never receive SendCommand."

# Runtime only, a failed remote command fails the job.
printf '%s\n' "Failed" >"$work_directory/sequence.txt"
output="$(run_release RELEASE_API_CONVERGE=false RELEASE_RUNTIME_PENDING=true MOCK_PING_STATUS=Online 2>&1)" &&
    fail "A failed runtime command must fail the job."
assert_contains "$output" "finished with status Failed" "The runtime command failure must be reported."
printf '%s\n' "Success" >"$work_directory/sequence.txt"

output="$(run_release RELEASE_API_CONVERGE=false RELEASE_RUNTIME_PENDING=true EC2_INSTANCE_ID=not-an-instance 2>&1)" &&
    fail "A malformed EC2_INSTANCE_ID must be rejected in a release."
assert_contains "$output" "does not match the expected instance id format" "The malformed instance id must be reported."

# --- every command that sends a payload names its release first ---------------
# The release order the host checks comes from the workflow run, so a command
# without one, or with a malformed one, is refused before any AWS call.
for command_case in "deploy" "install-runtime" "release RELEASE_API_CONVERGE=true RELEASE_RUNTIME_PENDING=false" \
    "release RELEASE_API_CONVERGE=false RELEASE_RUNTIME_PENDING=true"; do
    command_name="${command_case%% *}"
    command_scope=""
    [[ "$command_case" == "$command_name" ]] || command_scope="${command_case#* }"
    for identity in "GITHUB_RUN_NUMBER=" "GITHUB_RUN_NUMBER=0" "GITHUB_RUN_NUMBER=12a" "GITHUB_RUN_NUMBER=1234567890123456789" \
        "GITHUB_SHA=" "GITHUB_SHA=HEAD" "GITHUB_SHA=$(printf '%s' "$TEST_SHA" | tr 'a-f' 'A-F')" \
        "GITHUB_WORKFLOW_REF=" "GITHUB_WORKFLOW_REF=nagi4757/ec-portfolio/.github/workflows/other.yml@refs/heads/main" \
        "GITHUB_WORKFLOW_REF=nagi4757/ec-portfolio/.github/workflows/ci.yml@refs/pull/79/merge" \
        "GITHUB_WORKFLOW_REF=nagi4757/ec-portfolio/.github/workflows/ci.yml@refs/heads/feature"; do
        : >"$work_directory/calls.log"
        # shellcheck disable=SC2086
        output="$(env MOCK_CALL_LOG="$work_directory/calls.log" EC2_INSTANCE_ID="$VALID_INSTANCE_ID" MOCK_PING_STATUS=Online \
            $command_scope "$identity" bash "$DEPLOY_SCRIPT" "$command_name" 2>&1)" &&
            fail "$command_case must refuse [$identity]."
        assert_contains "$output" "${identity%%=*} must be" "$command_case must say why [$identity] is refused."
        [[ ! -s "$work_directory/calls.log" ]] || fail "$command_case must refuse [$identity] before any AWS call."
    done
done

# --- install-runtime: the gate before a desired image that needs the runtime --
run_install_runtime() {
    MOCK_CALL_LOG="$work_directory/calls.log"
    MOCK_SEQUENCE_FILE="$work_directory/sequence.txt"
    : >"$MOCK_CALL_LOG"
    rm -f "$MOCK_SEQUENCE_FILE.idx"
    export MOCK_CALL_LOG MOCK_SEQUENCE_FILE

    env \
        EC2_INSTANCE_ID="$VALID_INSTANCE_ID" \
        DEPLOY_POLL_ATTEMPTS=3 \
        DEPLOY_POLL_INTERVAL_SECONDS=0 \
        "$@" \
        bash "$DEPLOY_SCRIPT" install-runtime
}

# An Online host takes the runtime command, never the deploy command.
printf '%s\n' "Success" >"$work_directory/sequence.txt"
output="$(run_install_runtime MOCK_PING_STATUS=Online 2>&1)" ||
    fail "install-runtime on an online host must succeed."
calls="$(cat "$work_directory/calls.log")"
assert_count "$calls" "ssm describe-instance-information" 1 "install-runtime must check the host once."
assert_count "$calls" "ssm send-command" 1 "install-runtime must send exactly one command."
assert_contains "$calls" "--comment ec-portfolio demo runtime install" "install-runtime must send the runtime command."
assert_contains "$calls" "--timeout-seconds 30 --parameters" "install-runtime must carry the SSM delivery timeout."
assert_contains "$calls" "--instance-ids $VALID_INSTANCE_ID" "install-runtime must target exactly the configured instance."
assert_absent "$calls" "--comment ec-portfolio demo API deploy" "install-runtime must never send the deploy command."
assert_absent "$calls" "put-parameter" "install-runtime must never record deployment state itself."
assert_contains "$output" "its desired image SHA may be recorded" "A verified install must be reported."

# Any host that is not Online fails before anything is sent, so the record step
# after it never runs.
for ping_status in Stopped ConnectionLost Inactive None; do
    output="$(run_install_runtime MOCK_PING_STATUS="$ping_status" 2>&1)" &&
        fail "install-runtime on a host that is $ping_status must fail."
    assert_contains "$output" "must not be recorded yet" "A host that is $ping_status must be refused with its reason."
    assert_contains "$output" "re-run this job once the host is Online" "A host that is $ping_status must be told how to recover."
    assert_count "$(cat "$work_directory/calls.log")" "ssm send-command" 0 "A host that is $ping_status must never receive SendCommand."
done

# The host dropping offline after the check: SSM gives up on delivery and the
# command ends TimedOut, which fails like any other unverified install.
for terminal_status in TimedOut Failed Cancelled; do
    printf '%s\n' "$terminal_status" >"$work_directory/sequence.txt"
    output="$(run_install_runtime MOCK_PING_STATUS=Online 2>&1)" &&
        fail "An install that ends $terminal_status must fail install-runtime."
    assert_contains "$output" "finished with status $terminal_status" "An install that ends $terminal_status must be reported."
done
printf '%s\n' "InProgress" >"$work_directory/sequence.txt"
output="$(run_install_runtime MOCK_PING_STATUS=Online 2>&1)" &&
    fail "An install that never finishes must fail install-runtime."
assert_contains "$output" "Timed out waiting" "An unfinished install must be reported."
printf '%s\n' "Success" >"$work_directory/sequence.txt"
output="$(run_install_runtime MOCK_PING_STATUS=Online MOCK_SEND_COMMAND_FAIL=true 2>&1)" &&
    fail "A SendCommand failure must fail install-runtime."
assert_contains "$output" "Unable to send" "The SendCommand failure must be reported."
output="$(run_install_runtime EC2_INSTANCE_ID=not-an-instance 2>&1)" &&
    fail "A malformed EC2_INSTANCE_ID must be rejected by install-runtime."
assert_contains "$output" "does not match the expected instance id format" "The malformed instance id must be reported."
assert_absent "$(cat "$work_directory/calls.log")" "ssm" "A malformed instance id must be refused before any AWS call."

# An unreadable ping status is not "not Online": it fails closed as well.
failing_aws_directory="$work_directory/failing-aws"
mkdir -p "$failing_aws_directory"
printf '#!/usr/bin/env bash\nprintf "aws %%s\\n" "$*" >>"$MOCK_CALL_LOG"\necho "AccessDenied" >&2\nexit 254\n' >"$failing_aws_directory/aws"
chmod 755 "$failing_aws_directory/aws"
output="$(run_install_runtime PATH="$failing_aws_directory:$PATH" 2>&1)" &&
    fail "A failed DescribeInstanceInformation must fail install-runtime."
assert_contains "$output" "Unable to query DescribeInstanceInformation" "The lookup failure must be reported."
assert_absent "$(cat "$work_directory/calls.log")" "send-command" "A failed lookup must never send a command."

output="$(bash "$DEPLOY_SCRIPT" install 2>&1)" && fail "An unknown command must be rejected."
assert_contains "$output" "Unknown command" "An unknown command must be reported."

# --- the runtime-only payload, executed against a sandbox --------------------
assert_count "$(bash -c 'source "$1"; runtime_artifact_files' _ "$DEPLOY_SCRIPT")" ".sh" 3 \
    "runtime_artifact_files must list the three scripts."
[[ "$(bash -c 'source "$1"; runtime_artifact_files' _ "$DEPLOY_SCRIPT" | tr '\n' ' ')" == \
    "$WRAPPER_FILE $DEPLOY_FILE $INSTALLER_FILE $UNIT_FILE " ]] ||
    fail "runtime_artifact_files must list exactly the four artifacts the payload installs."

runtime_commands_json="$(bash -c 'source "$1"; build_install_runtime_commands' _ "$DEPLOY_SCRIPT")" ||
    fail "The orchestrator must render its runtime command list."
runtime_index() {
    printf '%s' "$runtime_commands_json" | jq -r --arg needle "$1" 'to_entries[] | select(.value | contains($needle)) | .key' | head -n 1
}
runtime_mktemp_index="$(runtime_index "mktemp -d")"
first_host_read_index="$(runtime_index "if runtime_current; then")"
installer_index="$(runtime_index "bash \"\$tmp_dir/$INSTALLER_FILE\"")"
post_install_check_index="$(runtime_index "runtime_current || {")"
[[ "$runtime_mktemp_index" =~ ^[0-9]+$ && "$first_host_read_index" =~ ^[0-9]+$ ]] ||
    fail "The runtime payload must compare the host copies and create one temporary directory."
[[ "$installer_index" =~ ^[0-9]+$ && "$post_install_check_index" =~ ^[0-9]+$ ]] ||
    fail "The runtime payload must run the installer and compare the host copies again afterwards."
((first_host_read_index < installer_index && installer_index < post_install_check_index)) ||
    fail "The runtime payload must compare, install only then, and verify the installed copies last."
for artifact_path in "/opt/ec-portfolio/runtime/demo/$WRAPPER_FILE" "/opt/ec-portfolio/runtime/demo/$DEPLOY_FILE" \
    "/opt/ec-portfolio/runtime/demo/$INSTALLER_FILE" "/etc/systemd/system/$UNIT_FILE"; do
    assert_contains "$(printf '%s' "$runtime_commands_json" | jq -r '.[]' | grep '^runtime_current()')" "'$artifact_path'" \
        "The runtime payload must compare the installed $artifact_path."
done
# Both payloads hold the wrapper's deployment lock and check the release order
# before they read any host copy, and record this release only once the copies
# are verified. The runtime install keeps the lock until it exits; the deploy
# payload releases it just before the wrapper, which takes it itself.
payload_index() {
    printf '%s' "$1" | jq -r --arg needle "$2" 'to_entries[] | select(.value | contains($needle)) | .key' | head -n 1
}
for payload_name in runtime deploy; do
    if [[ "$payload_name" == runtime ]]; then payload_json="$runtime_commands_json"; else payload_json="$commands_json"; fi
    lock_open_index="$(payload_index "$payload_json" "exec 9>'/var/lock/ec-portfolio-demo-deploy.lock'")"
    lock_index="$(payload_index "$payload_json" "flock --nonblock 9 || {")"
    order_index="$(payload_index "$payload_json" "if [ \"\$installed_order\" -gt \"\$release_order\" ]")"
    order_value_index="$(payload_index "$payload_json" "release_order='$TEST_RUN_NUMBER'")"
    host_read_index="$(payload_index "$payload_json" "bash \"\$tmp_dir/$INSTALLER_FILE\"")"
    [[ "$payload_name" == deploy ]] || host_read_index="$(payload_index "$payload_json" "if runtime_current; then")"
    check_index="$(payload_index "$payload_json" "runtime_current || {")"
    same_order_index="$(payload_index "$payload_json" "if [ \"\$installed_order\" -eq \"\$release_order\" ] && [ \"\$installed_sha\" != \"\$release_sha\" ]")"
    record_index="$(payload_index "$payload_json" "{ mkdir -p '/opt/ec-portfolio/runtime/demo' && printf")"
    for index_name in lock_open_index lock_index order_index order_value_index same_order_index host_read_index check_index record_index; do
        [[ "${!index_name}" =~ ^[0-9]+$ ]] || fail "The $payload_name payload is missing its $index_name step."
    done
    ((lock_open_index < lock_index && lock_index < order_value_index && order_value_index < order_index &&
        order_index <= same_order_index && same_order_index < record_index && record_index < host_read_index &&
        host_read_index < check_index)) ||
        fail "The $payload_name payload must lock, check the release order, record the release, and only then install and verify."
done
[[ -z "$(printf '%s' "$runtime_commands_json" | jq -r '.[]' | grep -E '^exec 9>&-|flock --unlock|flock -u')" ]] ||
    fail "The runtime payload must hold the deployment lock until it exits."
unlock_index="$(printf '%s' "$commands_json" | jq -r 'to_entries[] | select(.value == "exec 9>&-") | .key')"
deploy_check_index="$(payload_index "$commands_json" "runtime_current || {")"
wrapper_index="$(printf '%s' "$commands_json" | jq -r 'to_entries[] | select(.value == "/opt/ec-portfolio/runtime/demo/deploy-api-from-ssm.sh") | .key')"
[[ "$unlock_index" =~ ^[0-9]+$ && "$wrapper_index" =~ ^[0-9]+$ ]] &&
    ((deploy_check_index < unlock_index && unlock_index + 1 == wrapper_index)) ||
    fail "The deploy payload must release the lock right before the wrapper, after verifying the installed copies."
wrapper_lock_file="$(sed -n 's/^readonly DEFAULT_DEPLOY_LOCK_FILE="\(.*\)"$/\1/p' "$SCRIPT_DIRECTORY/$WRAPPER_FILE")"
[[ -n "$wrapper_lock_file" && "$(bash -c 'source "$1"; printf "%s" "$REMOTE_DEPLOY_LOCK_FILE"' _ "$DEPLOY_SCRIPT")" == "$wrapper_lock_file" ]] ||
    fail "Every install must take the same lock file as the installed wrapper ($wrapper_lock_file)."

verified_commands="$(bash -c 'source "$1"; verified_artifact_commands' _ "$DEPLOY_SCRIPT")"
verified_line_count="$(printf '%s\n' "$verified_commands" | wc -l | tr -d ' ')"
((verified_line_count > 0 && verified_line_count <= first_host_read_index)) ||
    fail "The verified artifacts must come before the host copies are compared."
locked_commands="$(bash -c 'source "$1"; locked_install_commands' _ "$DEPLOY_SCRIPT")"
locked_line_count="$(printf '%s\n' "$locked_commands" | wc -l | tr -d ' ')"
for payload_json in "$runtime_commands_json" "$commands_json"; do
    [[ "$(printf '%s' "$payload_json" | jq -r '.[]' | head -n "$verified_line_count")" == "$verified_commands" ]] ||
        fail "Both payloads must start with exactly the same verified artifacts."
    [[ "$(printf '%s' "$payload_json" | jq -r '.[]' | sed -n "$((verified_line_count + 1)),$((verified_line_count + locked_line_count))p")" == "$locked_commands" ]] ||
        fail "Both payloads must continue with exactly the same locked install commands."
done
for artifact in "$WRAPPER_FILE" "$DEPLOY_FILE" "$INSTALLER_FILE" "$UNIT_FILE"; do
    checksum_index="$(runtime_index "$artifact checksum mismatch")"
    [[ "$checksum_index" =~ ^[0-9]+$ ]] || fail "The runtime payload must verify $artifact."
    ((checksum_index < first_host_read_index && checksum_index < runtime_mktemp_index)) ||
        fail "$artifact must be verified before any host file is read or created."
done
[[ -z "$(printf '%s' "$runtime_commands_json" | jq -r '.[] | select(. == "/opt/ec-portfolio/runtime/demo/deploy-api-from-ssm.sh")')" ]] ||
    fail "The runtime payload must never run the wrapper."

render_runtime_payload() {
    printf '%s' "$runtime_commands_json" | jq -r '.[]' |
        sed -e "s|/opt/ec-portfolio/runtime/demo|$1/opt/ec-portfolio/runtime/demo|g" \
            -e "s|/etc/systemd/system|$1/etc/systemd/system|g" \
            -e "s|/var/lock/|$1/var/lock/|g"
}

# A host without the artifacts: the installer runs, the wrapper never does.
sandbox="$(payload_sandbox)"
output="$(run_payload "$sandbox" "$(render_runtime_payload "$sandbox")" 2>&1)" ||
    fail "A runtime payload on a host without the artifacts must install them: $output"
assert_contains "$output" "Host runtime installed and verified; the API was not redeployed." "The runtime install must be reported."
[[ "$(cat "$sandbox/payload-events.log")" == "installer" ]] || fail "Only the installer may run in a runtime release."
[[ ! -s "$sandbox/wrapper-ran.log" ]] || fail "A runtime release must never reach the wrapper."
for installed_file in "$WRAPPER_FILE" "$DEPLOY_FILE" "$INSTALLER_FILE"; do
    cmp -s "$(installed_directory "$sandbox")/$installed_file" "$SCRIPT_DIRECTORY/$installed_file" ||
        fail "A runtime release must install $installed_file byte for byte."
done
cmp -s "$sandbox/etc/systemd/system/$UNIT_FILE" "$SCRIPT_DIRECTORY/$UNIT_FILE" ||
    fail "A runtime release must install the unit byte for byte."

# The same host again: everything matches, nothing is installed.
: >"$sandbox/payload-events.log"
output="$(run_payload "$sandbox" "$(render_runtime_payload "$sandbox")" 2>&1)" ||
    fail "A runtime payload on an up-to-date host must succeed."
assert_contains "$output" "already matches this release; nothing installed." "An up-to-date host must be reported."
[[ ! -s "$sandbox/payload-events.log" ]] || fail "An up-to-date host must not run the installer."

# One stale artifact on the host is enough to install.
for stale_file in "$(installed_directory "$sandbox")/$DEPLOY_FILE" "$sandbox/etc/systemd/system/$UNIT_FILE"; do
    printf 'older release\n' >"$stale_file"
    : >"$sandbox/payload-events.log"
    run_payload "$sandbox" "$(render_runtime_payload "$sandbox")" >/dev/null 2>&1 ||
        fail "A host with a stale $(basename -- "$stale_file") must be updated."
    [[ "$(cat "$sandbox/payload-events.log")" == "installer" ]] ||
        fail "A stale $(basename -- "$stale_file") must run the installer."
    [[ ! -s "$sandbox/wrapper-ran.log" ]] || fail "Updating a stale artifact must never reach the wrapper."
done

# While another install or a deployment holds the lock, nothing is read,
# installed or reported as installed: the command fails, so nothing is recorded.
printf 'older release\n' >"$(installed_directory "$sandbox")/$DEPLOY_FILE"
: >"$sandbox/payload-events.log"
hold_lock "$sandbox"
output="$(run_payload "$sandbox" "$(render_runtime_payload "$sandbox")" 2>&1)" &&
    fail "A runtime install must fail while the deployment lock is held."
release_lock
assert_contains "$output" "Another deployment or runtime install is running on this host; nothing was installed." \
    "A held lock must be reported."
[[ ! -s "$sandbox/payload-events.log" ]] || fail "A held lock must stop the installer from running."
[[ "$(cat "$(installed_directory "$sandbox")/$DEPLOY_FILE")" == "older release" ]] ||
    fail "A held lock must leave the host copies untouched."
run_payload "$sandbox" "$(render_runtime_payload "$sandbox")" >/dev/null 2>&1 ||
    fail "Once the lock is free, the same install must succeed."

# An installer that exits 0 without leaving these exact files on the host is
# not a verified install: the command fails, so nothing is recorded after it.
printf 'older release\n' >"$(installed_directory "$sandbox")/$WRAPPER_FILE"
: >"$sandbox/payload-events.log"
output="$(MOCK_INSTALLER_NOOP=true run_payload "$sandbox" "$(render_runtime_payload "$sandbox")" 2>&1)" &&
    fail "An install that leaves a stale artifact on the host must fail."
assert_contains "$output" "does not match this release after installation" "An unverified install must be reported."
[[ "$(cat "$sandbox/payload-events.log")" == "installer" ]] || fail "The installer must have run before the check."
[[ ! -s "$sandbox/wrapper-ran.log" ]] || fail "An unverified install must never reach the wrapper."
[[ "$(cat "$(release_record "$sandbox")")" == "$TEST_RUN_NUMBER $TEST_SHA" ]] ||
    fail "An unverified install keeps the record of its own release, so no older release can follow it."

# A tampered artifact fails before the host is read or written.
for tampered_file in "$WRAPPER_FILE" "$DEPLOY_FILE" "$INSTALLER_FILE" "$UNIT_FILE"; do
    sandbox="$(payload_sandbox)"
    output="$(run_payload "$sandbox" "$(render_runtime_payload "$sandbox" | tamper_payload "$tampered_file")" 2>&1)" &&
        fail "A tampered $tampered_file must fail the runtime command."
    assert_contains "$output" "$tampered_file checksum mismatch" "A tampered $tampered_file must be reported."
    [[ ! -e "$(installed_directory "$sandbox")" && ! -s "$sandbox/payload-events.log" ]] ||
        fail "A tampered $tampered_file must not install anything."
done

# --- installs are ordered on the host: an older release never follows a newer --
# render_commands <commands json> <sandbox>
render_commands() {
    printf '%s' "$1" | jq -r '.[]' |
        sed -e "s|/opt/ec-portfolio/runtime/demo|$2/opt/ec-portfolio/runtime/demo|g" \
            -e "s|/etc/systemd/system|$2/etc/systemd/system|g" \
            -e "s|/var/lock/|$2/var/lock/|g"
}
# release_payload <runtime|deploy> <run number> [artifact directory] [commit]: the command list
# a given run sends, from the reviewed artifacts or from an altered copy of them.
release_payload() {
    local builder="build_install_runtime_commands"
    [[ "$1" == runtime ]] || builder="build_install_and_run_commands"
    GITHUB_RUN_NUMBER="$2" GITHUB_SHA="${4:-$TEST_SHA}" bash -c 'source "$1"; "$2"' _ "${3:-$SCRIPT_DIRECTORY}/deploy-runtime.sh" "$builder"
}
older_artifacts="$work_directory/older-artifacts"
mkdir -p "$older_artifacts"
cp "$DEPLOY_SCRIPT" "$SCRIPT_DIRECTORY/$WRAPPER_FILE" "$SCRIPT_DIRECTORY/$DEPLOY_FILE" \
    "$SCRIPT_DIRECTORY/$INSTALLER_FILE" "$SCRIPT_DIRECTORY/$UNIT_FILE" "$older_artifacts/"
printf '\n# runtime of an older release\n' >>"$older_artifacts/$DEPLOY_FILE"
readonly OLDER_RUN_NUMBER="419"
readonly NEWER_RUN_NUMBER="421"
host_holds_reviewed_runtime() {
    cmp -s "$(installed_directory "$1")/$DEPLOY_FILE" "$SCRIPT_DIRECTORY/$DEPLOY_FILE"
}

# L2-B: the newer release installs first, then an older command reaches the host
# (one the SSM agent delivers late, or one that stalled before the lock). The
# lock is free by then, so only the release order stops it, for both payloads.
sandbox="$(payload_sandbox)"
run_payload "$sandbox" "$(render_commands "$(release_payload runtime "$TEST_RUN_NUMBER")" "$sandbox")" >/dev/null 2>&1 ||
    fail "The newer release must install."
[[ "$(cat "$(release_record "$sandbox")")" == "$TEST_RUN_NUMBER $TEST_SHA" ]] ||
    fail "A verified install must record its run number and commit."
for older_payload in runtime deploy; do
    : >"$sandbox/payload-events.log"
    : >"$sandbox/wrapper-ran.log"
    output="$(run_payload "$sandbox" "$(render_commands "$(release_payload "$older_payload" "$OLDER_RUN_NUMBER" "$older_artifacts")" "$sandbox")" 2>&1)" &&
        fail "An older release's $older_payload command must be refused after a newer install."
    assert_contains "$output" "taken by a newer release (run $TEST_RUN_NUMBER, $TEST_SHA); this older release (run $OLDER_RUN_NUMBER) installs nothing." \
        "The refused older $older_payload command must say why."
    [[ ! -s "$sandbox/payload-events.log" && ! -s "$sandbox/wrapper-ran.log" ]] ||
        fail "A refused older $older_payload command must neither install nor reach the wrapper."
    host_holds_reviewed_runtime "$sandbox" || fail "A refused older $older_payload command must leave the newer runtime in place."
    [[ "$(cat "$(release_record "$sandbox")")" == "$TEST_RUN_NUMBER $TEST_SHA" ]] ||
        fail "A refused older $older_payload command must leave the record alone."
done

# The same run again (a re-run keeps its number and commit) and a newer run are both accepted;
# a newer run that finds the runtime current still records itself.
run_payload "$sandbox" "$(render_commands "$(release_payload runtime "$TEST_RUN_NUMBER")" "$sandbox")" >/dev/null 2>&1 ||
    fail "A re-run of the release that installed the runtime must be accepted."
run_payload "$sandbox" "$(render_commands "$(release_payload runtime "$NEWER_RUN_NUMBER")" "$sandbox")" >/dev/null 2>&1 ||
    fail "A newer release must be accepted."
[[ "$(cat "$(release_record "$sandbox")")" == "$NEWER_RUN_NUMBER $TEST_SHA" ]] ||
    fail "A newer release that finds the runtime current must still record itself."
output="$(run_payload "$sandbox" "$(render_commands "$(release_payload runtime "$TEST_RUN_NUMBER")" "$sandbox")" 2>&1)" &&
    fail "Once a newer release recorded itself, an older one must be refused even with identical artifacts."

# An install record that cannot be read refuses every install; it is never
# taken for a missing one.
for record_content in "garbage" "" "1234567890123456789 $TEST_SHA" "-5 $TEST_SHA" "$NEWER_RUN_NUMBER" \
    "$NEWER_RUN_NUMBER HEAD" "$NEWER_RUN_NUMBER $(printf '%s' "$TEST_SHA" | tr 'a-f' 'A-F')" "$NEWER_RUN_NUMBER ${TEST_SHA:0:39}"; do
    printf '%s\n' "$record_content" >"$(release_record "$sandbox")"
    : >"$sandbox/payload-events.log"
    output="$(run_payload "$sandbox" "$(render_commands "$(release_payload runtime "$NEWER_RUN_NUMBER")" "$sandbox")" 2>&1)" &&
        fail "An install record [$record_content] must refuse the install."
    assert_contains "$output" "is unreadable; nothing was installed." "An install record [$record_content] must be reported."
    [[ ! -s "$sandbox/payload-events.log" ]] || fail "An install record [$record_content] must stop the installer."
done

# The same run number with another commit means the record or the numbering is
# not what this order assumes: every install is refused until an operator looks.
printf '%s %s\n' "$NEWER_RUN_NUMBER" "$TEST_SHA" >"$(release_record "$sandbox")"
other_sha="fedcba9876543210fedcba9876543210fedcba98"
for payload_kind in runtime deploy; do
    : >"$sandbox/payload-events.log"
    : >"$sandbox/wrapper-ran.log"
    output="$(run_payload "$sandbox" "$(render_commands "$(release_payload "$payload_kind" "$NEWER_RUN_NUMBER" "" "$other_sha")" "$sandbox")" 2>&1)" &&
        fail "A $payload_kind command with the recorded run number but another commit must be refused."
    assert_contains "$output" "names run $NEWER_RUN_NUMBER with commit $TEST_SHA, not $other_sha; nothing was installed." \
        "The conflicting $payload_kind command must say why it is refused."
    [[ ! -s "$sandbox/payload-events.log" && ! -s "$sandbox/wrapper-ran.log" ]] ||
        fail "A conflicting $payload_kind command must neither install nor reach the wrapper."
    [[ "$(cat "$(release_record "$sandbox")")" == "$NEWER_RUN_NUMBER $TEST_SHA" ]] ||
        fail "A conflicting $payload_kind command must leave the record alone."
done

# The release is recorded before anything is installed. A record that cannot be
# written stops the command before the installer; an install that fails after it
# leaves this release recorded, so a re-run of it is accepted and an older
# release still is not.
sandbox="$(payload_sandbox)"
mkdir -p "$(release_record "$sandbox").tmp"
output="$(run_payload "$sandbox" "$(render_commands "$(release_payload runtime "$TEST_RUN_NUMBER")" "$sandbox")" 2>&1)" &&
    fail "An install whose release cannot be recorded must fail."
assert_contains "$output" "Unable to record this release on the host; nothing was installed." "A failed record must be reported."
[[ ! -s "$sandbox/payload-events.log" ]] || fail "A failed record must stop the installer."
[[ ! -e "$(release_record "$sandbox")" ]] || fail "A failed record must not leave a record behind."
rmdir "$(release_record "$sandbox").tmp"
output="$(MOCK_INSTALLER_FAIL=true run_payload "$sandbox" "$(render_commands "$(release_payload runtime "$TEST_RUN_NUMBER")" "$sandbox")" 2>&1)" &&
    fail "A failed installer must fail the command."
[[ "$(cat "$(release_record "$sandbox")")" == "$TEST_RUN_NUMBER $TEST_SHA" ]] ||
    fail "A release whose install failed must stay recorded."
run_payload "$sandbox" "$(render_commands "$(release_payload runtime "$OLDER_RUN_NUMBER" "$older_artifacts")" "$sandbox")" >/dev/null 2>&1 &&
    fail "An older release must be refused after a newer one failed to install."
run_payload "$sandbox" "$(render_commands "$(release_payload runtime "$TEST_RUN_NUMBER")" "$sandbox")" >/dev/null 2>&1 ||
    fail "A re-run of the release whose install failed must be accepted."
host_holds_reviewed_runtime "$sandbox" || fail "The re-run must install the reviewed runtime."

# L2-A: an older install still holds the lock when the newer one arrives. The
# newer one fails, so nothing is recorded after it, and succeeds once re-run.
sandbox="$(payload_sandbox)"
hold_lock "$sandbox"
output="$(run_payload "$sandbox" "$(render_commands "$(release_payload runtime "$TEST_RUN_NUMBER")" "$sandbox")" 2>&1)" &&
    fail "An install must fail while an older one holds the lock."
release_lock
assert_contains "$output" "Another deployment or runtime install is running on this host" "The held lock must be reported."
[[ ! -e "$(release_record "$sandbox")" ]] || fail "An install refused by the lock must record nothing."

# The deploy payload under a held lock fails before it installs anything, and
# never reaches the wrapper.
: >"$sandbox/payload-events.log"
hold_lock "$sandbox"
output="$(run_payload "$sandbox" "$(render_payload "$sandbox")" 2>&1)" &&
    fail "The deploy payload must fail while the deployment lock is held."
release_lock
assert_contains "$output" "Another deployment or runtime install is running on this host; nothing was installed." \
    "The deploy payload must report the held lock."
[[ ! -s "$sandbox/payload-events.log" && ! -s "$sandbox/wrapper-ran.log" ]] ||
    fail "The deploy payload must neither install nor reach the wrapper under a held lock."

# With the lock free, the deploy payload installs, records itself and releases the
# lock so that the wrapper can take it: the wrapper is reached and does not
# report a concurrent deployment.
output="$(run_payload "$sandbox" "$(render_payload "$sandbox")" 2>&1)" || true
assert_absent "$output" "Another deployment is already running" "The deploy payload must not hold the lock the wrapper takes."
[[ -s "$sandbox/wrapper-ran.log" ]] || fail "The deploy payload must reach the wrapper once it releases the lock."
[[ "$(cat "$(release_record "$sandbox")")" == "$TEST_RUN_NUMBER $TEST_SHA" ]] ||
    fail "The deploy payload must record its release once the installed copies are verified."

# --- the workflow wires the scope through without skipping deploy-api --------
job_block() {
    awk -v job="  ${1}:" '
        $0 == job { inside = 1; print; next }
        inside && /^  [a-z]/ { exit }
        inside { print }
    ' "$WORKFLOW_FILE"
}
publish_job="$(job_block build-and-push-api)"
deploy_job="$(job_block deploy-api)"
frontend_job="$(job_block deploy-frontends)"
[[ -n "$publish_job" && -n "$deploy_job" && -n "$frontend_job" ]] || fail "Could not read the deployment jobs from $WORKFLOW_FILE"

assert_contains "$publish_job" "run: infra/runtime/demo/publish-api-image.sh release-scope" \
    "build-and-push-api must decide the release scope."
assert_contains "$publish_job" "api_changed: \${{ steps.scope.outputs.api_changed }}" "build-and-push-api must export api_changed."
assert_contains "$publish_job" "api_converge: \${{ steps.scope.outputs.api_converge }}" "build-and-push-api must export api_converge."
assert_contains "$publish_job" "runtime_pending: \${{ steps.scope.outputs.runtime_pending }}" "build-and-push-api must export runtime_pending."
scope_line="$(printf '%s\n' "$publish_job" | grep -n "publish-api-image.sh release-scope" | cut -d: -f1)"
for gated_mode in ensure-image migration-guard assert-rollback-image; do
    mode_line="$(printf '%s\n' "$publish_job" | grep -n "run: infra/runtime/demo/publish-api-image.sh $gated_mode\$" | cut -d: -f1)"
    [[ "$mode_line" =~ ^[0-9]+$ ]] || fail "build-and-push-api must still run $gated_mode."
    ((scope_line < mode_line)) || fail "The scope must be decided before $gated_mode."
    [[ "$(printf '%s\n' "$publish_job" | sed -n "$((mode_line - 1))p")" == "        if: steps.scope.outputs.api_changed == 'true'" ]] ||
        fail "$gated_mode must run only when the API build context changed."
done
# The desired image SHA is recorded by deploy-api alone, after the runtime gate
# and under the same approval as the delivery.
assert_absent "$publish_job" "record-desired" "build-and-push-api must never record the desired image SHA."
assert_absent "$publish_job" "deploy-runtime.sh" "build-and-push-api must never reach the host."

for scope_name in api_changed api_converge runtime_pending; do
    scope_variable="RELEASE_$(printf '%s' "$scope_name" | tr '[:lower:]' '[:upper:]')"
    assert_contains "$deploy_job" "$scope_variable: \${{ needs.build-and-push-api.outputs.$scope_name }}" \
        "deploy-api must receive $scope_name."
    assert_contains "$deploy_job" "[[ \"\$$scope_variable\" =~ ^(true|false)\$ ]]" \
        "deploy-api must refuse an undecided $scope_name before any step it gates."
done
assert_contains "$deploy_job" "run: infra/runtime/demo/deploy-runtime.sh release" "deploy-api must run the scoped release."
assert_absent "$deploy_job" "run: infra/runtime/demo/deploy-runtime.sh deploy" "deploy-api must not bypass the scope."
assert_contains "$deploy_job" "infra/runtime/demo/publish-api-image.test.sh" \
    "deploy-api must test the publication contract it records the desired image with."

deploy_step_line() {
    local line
    line="$(printf '%s\n' "$deploy_job" | grep -nxF -- "$1" | cut -d: -f1)"
    [[ "$line" =~ ^[0-9]+$ ]] || fail "deploy-api must contain exactly: $1"
    printf '%s' "$line"
}
validate_line="$(deploy_step_line "      - name: Validate deployment environment")"
credential_line="$(deploy_step_line "      - name: Configure short-lived AWS credentials")"
install_line="$(deploy_step_line "        run: infra/runtime/demo/deploy-runtime.sh install-runtime")"
previous_line="$(deploy_step_line "        run: infra/runtime/demo/publish-api-image.sh read-desired")"
record_line="$(deploy_step_line "        run: infra/runtime/demo/publish-api-image.sh record-desired")"
release_line="$(deploy_step_line "        run: infra/runtime/demo/deploy-runtime.sh release")"
restore_line="$(deploy_step_line "        run: infra/runtime/demo/publish-api-image.sh restore-desired")"
((validate_line < credential_line && credential_line < install_line && install_line < previous_line &&
    previous_line < record_line && record_line < release_line && release_line < restore_line)) ||
    fail "deploy-api must validate the scope, install the runtime, remember and record the desired image, release, and restore last, in that order."
[[ "$(printf '%s\n' "$deploy_job" | sed -n "$((previous_line - 2)),$((previous_line - 1))p")" == \
    "        id: previous"$'\n'"        if: env.RELEASE_API_CHANGED == 'true'" ]] ||
    fail "The previous desired image must be read, as step previous, exactly when a new API image is recorded."
restore_step="$(printf '%s\n' "$deploy_job" | sed -n "$((restore_line - 5)),${restore_line}p")"
assert_contains "$restore_step" "      - name: Restore the desired API image after a failed release" "The restore step must directly follow its name."
assert_contains "$restore_step" "        if: (failure() || cancelled()) && steps.previous.outcome == 'success'" \
    "The restore must run on failure or cancellation, and only once the previous values were read."
assert_contains "$restore_step" "PREVIOUS_DESIRED_IMAGE_SHA: \${{ steps.previous.outputs.previous_desired }}" \
    "The restore must put back the desired image SHA read before recording."
assert_contains "$restore_step" "PREVIOUS_PENDING_MIGRATION_IMAGE_SHA: \${{ steps.previous.outputs.previous_pending }}" \
    "The restore must put back the pending migration image SHA read before recording."
[[ "$(printf '%s\n' "$deploy_job" | sed -n "$((install_line - 1))p")" == \
    "        if: env.RELEASE_API_CHANGED == 'true' && env.RELEASE_RUNTIME_PENDING == 'true'" ]] ||
    fail "The runtime gate must run exactly for a new API image whose runtime changed."
[[ "$(printf '%s\n' "$deploy_job" | sed -n "$((record_line - 1))p")" == "        if: env.RELEASE_API_CHANGED == 'true'" ]] ||
    fail "The desired image must be recorded exactly for a new API image."
[[ "$(printf '%s\n' "$deploy_job" | sed -n "$((release_line - 1))p")" == "      - name: Release to the EC2 host when online" ]] ||
    fail "The release step must run unconditionally."
assert_count "$deploy_job" "continue-on-error" 0 "No deploy-api step may let a failed gate fall through to the record step."

# A release that installs the runtime and then deploys spends both budgets
# inside one credential.
runtime_install_delivery_timeout="$(read_constant "$DEPLOY_SCRIPT" "RUNTIME_INSTALL_DELIVERY_TIMEOUT_SECONDS")"
runtime_install_budget=$(($(read_constant "$DEPLOY_SCRIPT" "RUNTIME_INSTALL_POLL_ATTEMPTS") *
    $(read_constant "$DEPLOY_SCRIPT" "RUNTIME_INSTALL_POLL_INTERVAL_SECONDS")))
((runtime_install_delivery_timeout >= 30)) ||
    fail "SendCommand rejects a delivery timeout below 30s."
(((runtime_install_budget - runtime_install_delivery_timeout) >= 60)) ||
    fail "The runtime install budget (${runtime_install_budget}s) must outlast its delivery timeout (${runtime_install_delivery_timeout}s) by the installer's own systemctl bounds."
(((oidc_credential_seconds - runtime_install_budget - poll_budget) >= MIN_OPERATIONAL_HEADROOM_SECONDS)) ||
    fail "The OIDC credential (${oidc_credential_seconds}s) must leave ${MIN_OPERATIONAL_HEADROOM_SECONDS}s above the runtime install (${runtime_install_budget}s) and deployment (${poll_budget}s) budgets."
# The job itself must never be skipped by the scope, or deploy-frontends, which
# needs it, would be skipped too for every push that does not touch the API.
[[ "$(printf '%s\n' "$deploy_job" | grep -c '^    if:')" == 1 ]] || fail "deploy-api must keep exactly one job-level if."
assert_contains "$deploy_job" "    if: github.event_name == 'push' && github.ref == 'refs/heads/main'" \
    "deploy-api's job-level if must stay the push condition alone."
assert_absent "$(printf '%s\n' "$deploy_job" | grep '^    if:')" "outputs" "deploy-api's job-level if must not read the scope."
# deploy-frontends is skipped only by its own frontend scope
# (frontend-release-scope.test.sh), never by this one.
for api_scope_reference in "needs.build-and-push-api" "needs.deploy-api" "api_changed" "api_converge" "runtime_pending"; do
    assert_absent "$(printf '%s\n' "$frontend_job" | grep '^    if:')" "$api_scope_reference" "deploy-frontends must not read the API release scope."
done

# Run numbers order installs only within one workflow. ci.yml must therefore be
# the one workflow that runs this script, and the one the script accepts.
for workflow in "$(dirname -- "$WORKFLOW_FILE")"/*.yml "$(dirname -- "$WORKFLOW_FILE")"/*.yaml; do
    [[ -e "$workflow" && "$workflow" != "$WORKFLOW_FILE" ]] || continue
    assert_absent "$(cat "$workflow")" "deploy-runtime.sh" "Only ci.yml may run deploy-runtime.sh, not $(basename -- "$workflow")."
done
[[ "$(basename -- "$WORKFLOW_FILE")" == "ci.yml" ]] || fail "The workflow that runs deploy-runtime.sh must be ci.yml."
assert_contains "$(cat "$DEPLOY_SCRIPT")" "workflows/ci\\.yml@refs/heads/main\$'" \
    "deploy-runtime.sh must accept only the CI workflow on main."

printf '[deploy-runtime-test] PASS\n'
