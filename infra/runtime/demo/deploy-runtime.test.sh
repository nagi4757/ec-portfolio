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

# --- a host with no managed-instance record is also a soft no-op ------------
printf '%s\n' "Success" >"$work_directory/sequence.txt"
output="$(run_deploy MOCK_PING_STATUS=None 2>&1)" ||
    fail "A host with no managed-instance record must not fail the job."
assert_contains "$output" "is not Online" "A missing managed-instance record must be reported."
calls="$(cat "$work_directory/calls.log")"
assert_absent "$calls" "send-command" "A missing managed-instance record must never receive SendCommand."

# --- an online host that deploys successfully -------------------------------
printf '%s\n' "Success" >"$work_directory/sequence.txt"
output="$(run_deploy MOCK_PING_STATUS=Online 2>&1)" ||
    fail "A successful deployment must succeed."
assert_contains "$output" "Deployment command succeeded." "Success must be reported."
calls="$(cat "$work_directory/calls.log")"
assert_contains "$calls" "ssm send-command" "An online host must receive exactly one SendCommand."

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

printf '[deploy-runtime-test] PASS\n'
