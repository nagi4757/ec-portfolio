#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly DEPLOY_SCRIPT="$SCRIPT_DIRECTORY/deploy-runtime.sh"

readonly VALID_INSTANCE_ID="i-0123456789abcdef0"

work_directory=""

cleanup() {
    local exit_code=$?
    trap - EXIT
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
    ":latest" "GetDocument" "DescribeDocument"; do
    printf '%s' "$script_contents" | grep -Fq -- "$forbidden" &&
        fail "deploy-runtime.sh must not reference: $forbidden"
done
assert_contains "$script_contents" "install -o root -g root -m 0755" \
    "The installed files must be root owned and 0755."
assert_contains "$script_contents" "checksum mismatch" \
    "The remote install must verify a checksum before use."

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

test_source="$(cat "${BASH_SOURCE[0]}")"
while read -r timing_constant; do
    [[ -n "$timing_constant" ]] || continue
    printf '%s' "$test_source" | grep -Fq -- "\"$timing_constant\"" ||
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
    "infra/runtime/demo/deploy-runtime.test.sh"; do
    assert_contains "$workflow_contents" "$required_suite" \
        "The deploy-api job must run $required_suite"
done

# --- the checksum gate is verified by running the generated remote payload ---
# A static grep proves the text is present, not that the gate actually stops a
# tampered payload. Render the real command list, retarget it at a sandbox so it
# can run without root, and execute it.
readonly WRAPPER_FILE="deploy-api-from-ssm.sh"
readonly DEPLOY_FILE="deploy-api.sh"

# Sourcing happens in its own process so the orchestrator's readonly globals and
# its log/fail helpers cannot collide with the ones this test defines.
render_command_json() {
    bash -c 'source "$1"; build_install_and_run_commands' _ "$DEPLOY_SCRIPT"
}

commands_json="$(render_command_json)" ||
    fail "The orchestrator must render its remote command list."
[[ -n "$commands_json" ]] || fail "The rendered command list must not be empty."

# Rewrites the rendered commands so they can run locally: the install target
# moves under the sandbox and the root ownership flags are dropped. The
# checksum gate itself is left exactly as it will run on the host.
render_payload() {
    local sandbox="$1"

    printf '%s' "$commands_json" | jq -r '.[]' |
        sed -e "s|/opt/ec-portfolio/runtime/demo|$sandbox/opt/ec-portfolio/runtime/demo|g" \
            -e "s|install -o root -g root -m 0755|install -m 0755|g"
}

# Replaces one file's base64 payload with different content, leaving the
# recorded SHA256 untouched. This is what a payload tampered in transit looks
# like to the host.
tamper_payload() {
    local target_file="$1"
    local tampered_b64
    local line

    tampered_b64="$(printf '#!/usr/bin/env bash\nexit 0\n' | base64 | tr -d '\n')"

    while IFS= read -r line; do
        if [[ "$line" == *"> \"\$tmp_dir/$target_file\""* ]]; then
            printf "printf '%%s' '%s' | base64 -d > \"\$tmp_dir/%s\"\n" \
                "$tampered_b64" "$target_file"
        else
            printf '%s\n' "$line"
        fi
    done
}

install_payload_mocks() {
    local sandbox="$1"
    local mock

    mkdir -p "$sandbox/bin"
    # The installed wrapper is the real script, so it needs its dependencies on
    # PATH. Recording a call proves the wrapper was reached at all.
    for mock in aws curl docker; do
        cat >"$sandbox/bin/$mock" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0") $*" >>"$WRAPPER_MARKER"
exit 1
MOCK
        chmod 755 "$sandbox/bin/$mock"
    done

    cat >"$sandbox/bin/flock" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    chmod 755 "$sandbox/bin/flock"
}

run_payload() {
    local sandbox="$1"
    local payload="$2"

    env \
        PATH="$sandbox/bin:$PATH" \
        WRAPPER_MARKER="$sandbox/wrapper-ran.log" \
        DEPLOY_LOCK_FILE="$sandbox/deploy.lock" \
        bash -c "$payload"
}

payload_sandbox() {
    local sandbox
    sandbox="$(mktemp -d "$work_directory/payload.XXXXXX")"
    install_payload_mocks "$sandbox"
    : >"$sandbox/wrapper-ran.log"
    printf '%s' "$sandbox"
}

installed_directory() {
    printf '%s' "$1/opt/ec-portfolio/runtime/demo"
}

# An untampered payload installs both files and reaches the wrapper.
sandbox="$(payload_sandbox)"
run_payload "$sandbox" "$(render_payload "$sandbox")" >/dev/null 2>&1 || true
installed="$(installed_directory "$sandbox")"
[[ -f "$installed/$WRAPPER_FILE" ]] || fail "A valid payload must install the wrapper."
[[ -f "$installed/$DEPLOY_FILE" ]] || fail "A valid payload must install deploy-api.sh."
cmp -s "$installed/$WRAPPER_FILE" "$SCRIPT_DIRECTORY/$WRAPPER_FILE" ||
    fail "The installed wrapper must be byte identical to the reviewed source."
cmp -s "$installed/$DEPLOY_FILE" "$SCRIPT_DIRECTORY/$DEPLOY_FILE" ||
    fail "The installed deploy-api.sh must be byte identical to the reviewed source."
[[ -x "$installed/$WRAPPER_FILE" ]] || fail "The installed wrapper must be executable."
[[ -s "$sandbox/wrapper-ran.log" ]] ||
    fail "A valid payload must reach the installed wrapper."

# A tampered wrapper fails closed and never runs.
for tampered_file in "$WRAPPER_FILE" "$DEPLOY_FILE"; do
    sandbox="$(payload_sandbox)"
    payload="$(render_payload "$sandbox" | tamper_payload "$tampered_file")"

    output="$(run_payload "$sandbox" "$payload" 2>&1)" &&
        fail "A tampered $tampered_file must fail the remote command."
    assert_contains "$output" "$tampered_file checksum mismatch" \
        "A tampered $tampered_file must be reported as a checksum mismatch."

    installed="$(installed_directory "$sandbox")"
    [[ ! -f "$installed/$WRAPPER_FILE" ]] ||
        fail "A tampered $tampered_file must not install the wrapper."
    [[ ! -f "$installed/$DEPLOY_FILE" ]] ||
        fail "A tampered $tampered_file must not install deploy-api.sh."
    [[ ! -s "$sandbox/wrapper-ran.log" ]] ||
        fail "A tampered $tampered_file must never reach the wrapper."
done

printf '[deploy-runtime-test] PASS\n'
