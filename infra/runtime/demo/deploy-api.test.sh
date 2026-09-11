#!/usr/bin/env bash

# Signal behaviour of deploy-api.sh.
#
# deploy-api.sh only cleans up through an EXIT trap, and the rollback inside it
# is conditional on a non-zero status. Bash runs that EXIT trap on an untrapped
# SIGTERM but reports status 0 there, so without the signal traps the rollback
# is skipped exactly when it matters. These tests drive the real cleanup()
# through each signal path against a fake docker whose container state can be
# asserted afterwards.
#
# The script is sourced rather than executed because deploy-api.sh requires
# root; sourcing installs the real traps and defines the real cleanup() in a
# subshell we can signal.

set -euo pipefail

# Job control, enabled for the whole script rather than inside a subshell, so it
# actually takes effect. It matters twice. A background job of a non-interactive
# shell without job control inherits SIGINT as ignored, and a signal ignored on
# entry cannot be trapped, so the INT case would silently test nothing. Job
# control also puts each scenario in its own process group, which is what makes
# it safe to signal the group the way systemd signals a whole unit; without it
# the group would be this test's own.
set -m

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly DEPLOY_API_SCRIPT="$SCRIPT_DIRECTORY/deploy-api.sh"

readonly API_CONTAINER="ec-portfolio-demo-api"
readonly CANDIDATE_CONTAINER="ec-portfolio-demo-api-candidate"
readonly ROLLBACK_CONTAINER="ec-portfolio-demo-api-rollback"

work_directory=""

cleanup_tests() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-deploy-api-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup_tests EXIT

fail() {
    printf '[deploy-api-test] FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    printf '%s' "$1" | grep -Fq -- "$2" || fail "$3 (expected to find: $2)"
}

assert_absent() {
    printf '%s' "$1" | grep -Fq -- "$2" && fail "$3 (unexpectedly found: $2)"
    return 0
}

# --- fake docker ------------------------------------------------------------
# Containers are files under $work_directory/containers. The file content is the
# run state, so a rollback can be asserted on both the name and the state.
install_fakes() {
    local bin_directory="$work_directory/bin"
    mkdir -p "$bin_directory" "$work_directory/containers"

    cat >"$bin_directory/docker" <<'MOCK'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "docker $*" >>"$DOCKER_CALL_LOG"
registry="$CONTAINER_DIR"

case "${1-}" in
container)
    # docker container inspect <name>
    [[ "${2-}" == "inspect" ]] || exit 64
    [[ -f "$registry/${3-}" ]] || exit 1
    printf '{}\n'
    ;;
inspect)
    name="${!#}"
    [[ -f "$registry/$name" ]] || exit 1
    printf '%s\n' "$(cat "$registry/$name")"
    ;;
rm)
    name="${!#}"
    rm -f "$registry/$name"
    ;;
rename)
    from="${2-}"; to="${3-}"
    [[ -f "$registry/$from" ]] || exit 1
    # Real docker refuses to rename onto a name that is already taken. Without
    # this the rollback could appear to succeed while silently discarding the
    # container still holding the destination name.
    [[ ! -e "$registry/$to" ]] || exit 1
    mv "$registry/$from" "$registry/$to"
    ;;
start)
    name="${!#}"
    [[ -f "$registry/$name" ]] || exit 1
    printf 'running\n' >"$registry/$name"
    ;;
stop)
    name="${!#}"
    [[ -f "$registry/$name" ]] || exit 1
    printf 'stopped\n' >"$registry/$name"
    ;;
logout)
    : ;;
*)
    exit 0 ;;
esac
MOCK
    chmod 755 "$bin_directory/docker"
    PATH="$bin_directory:$PATH"
    export PATH
}

container_state() {
    local name="$1"
    if [[ -f "$work_directory/containers/$name" ]]; then
        cat "$work_directory/containers/$name"
    else
        printf 'absent'
    fi
}

reset_world() {
    rm -rf -- "$work_directory/containers"
    mkdir -p "$work_directory/containers"
    : >"$work_directory/docker-calls.log"
    rm -f "$work_directory/ready.marker"
}

# Scenario runner: a real separate process that sources deploy-api.sh, adopts
# the state the scenario needs, announces readiness through a marker file and
# then waits to be signalled. The marker is what makes the timing deterministic,
# rather than sleeping and hoping the process got far enough.
write_scenario_runner() {
    cat >"$work_directory/scenario.sh" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$SCENARIO_DEPLOY_API_SCRIPT"

replacement_started="$SCENARIO_REPLACEMENT_STARTED"
rollback_pending="$SCENARIO_ROLLBACK_PENDING"
ecr_login_succeeded="false"

: >"$SCENARIO_READY_MARKER"
# Stands in for a bounded wait such as wait_for_host_readiness. The signal, not
# this timeout, is what ends the process; the timeout only stops a broken test
# from hanging forever.
sleep 60
RUNNER
    chmod 755 "$work_directory/scenario.sh"

    # Same idea without a signal: adopt the state, then exit with a chosen code
    # so the non-signal paths through cleanup() are covered by the same harness.
    cat >"$work_directory/exit-scenario.sh" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source "$SCENARIO_DEPLOY_API_SCRIPT"

replacement_started="$SCENARIO_REPLACEMENT_STARTED"
rollback_pending="$SCENARIO_ROLLBACK_PENDING"
ecr_login_succeeded="false"

exit "$SCENARIO_EXIT_CODE"
RUNNER
    chmod 755 "$work_directory/exit-scenario.sh"
}

# $1 exit code, $2 replacement_started, $3 rollback_pending
run_exit_scenario() {
    local code="$1"
    local replacement="$2"
    local rollback="$3"
    local status=0

    SCENARIO_DEPLOY_API_SCRIPT="$DEPLOY_API_SCRIPT" \
        DOCKER_CALL_LOG="$work_directory/docker-calls.log" \
        CONTAINER_DIR="$work_directory/containers" \
        SCENARIO_REPLACEMENT_STARTED="$replacement" \
        SCENARIO_ROLLBACK_PENDING="$rollback" \
        SCENARIO_EXIT_CODE="$code" \
        bash "$work_directory/exit-scenario.sh" >/dev/null 2>&1 || status=$?

    scenario_status="$status"
}

# Result is reported through $scenario_status, not stdout: a command
# substitution would run this in a subshell where job control is not in
# effect, and the process group signalling below depends on it.
# $1 signal, $2 replacement_started, $3 rollback_pending
scenario_status=0
run_signal_scenario() {
    local signal="$1"
    local replacement="$2"
    local rollback="$3"
    local marker="$work_directory/ready.marker"
    local status=0
    local pid
    local waited=0

    rm -f "$marker"

    SCENARIO_DEPLOY_API_SCRIPT="$DEPLOY_API_SCRIPT" \
        DOCKER_CALL_LOG="$work_directory/docker-calls.log" \
        CONTAINER_DIR="$work_directory/containers" \
        SCENARIO_REPLACEMENT_STARTED="$replacement" \
        SCENARIO_ROLLBACK_PENDING="$rollback" \
        SCENARIO_READY_MARKER="$marker" \
        bash "$work_directory/scenario.sh" >/dev/null 2>&1 &
    pid=$!

    while [[ ! -f "$marker" ]]; do
        sleep 0.1
        waited=$((waited + 1))
        ((waited < 300)) || fail "The scenario runner never became ready."
    done

    # A negative pid signals the whole process group, which is what systemd's
    # default KillMode=control-group does to a unit. The foreground child dies
    # with it, so bash services the trap immediately instead of waiting the
    # child out.
    kill -"$signal" -"$pid" 2>/dev/null || true
    wait "$pid" || status=$?

    scenario_status="$status"
}

work_directory="$(mktemp -d /tmp/ec-portfolio-deploy-api-test.XXXXXX)"
install_fakes
write_scenario_runner

# --- 1. TERM before replacement ---------------------------------------------
# Nothing was swapped yet, so there is nothing to roll back, but the
# unconditional cleanup still has to run.
reset_world
printf 'running\n' >"$work_directory/containers/$API_CONTAINER"
printf 'running\n' >"$work_directory/containers/$CANDIDATE_CONTAINER"

run_signal_scenario TERM false false
status="$scenario_status"
[[ "$status" -eq 143 ]] ||
    fail "TERM before replacement must exit 143 (got $status)."
[[ "$(container_state "$API_CONTAINER")" == "running" ]] ||
    fail "TERM before replacement must leave the serving container alone."
[[ "$(container_state "$CANDIDATE_CONTAINER")" == "absent" ]] ||
    fail "TERM before replacement must still remove the candidate container."
calls="$(cat "$work_directory/docker-calls.log")"
assert_absent "$calls" "rename" "No rollback rename may happen before replacement started."

# --- 2. TERM inside the replacement critical section ------------------------
# The previous container has been renamed aside and the new one does not exist
# yet. This is the window where skipping the rollback leaves nothing serving.
reset_world
printf 'stopped\n' >"$work_directory/containers/$ROLLBACK_CONTAINER"

run_signal_scenario TERM true true
status="$scenario_status"
[[ "$status" -eq 143 ]] ||
    fail "TERM during replacement must exit 143 (got $status)."
[[ "$(container_state "$API_CONTAINER")" == "running" ]] ||
    fail "TERM during replacement must restore the previous container and start it (state: $(container_state "$API_CONTAINER"))."
[[ "$(container_state "$ROLLBACK_CONTAINER")" == "absent" ]] ||
    fail "No stale rollback container may remain after the rollback."
calls="$(cat "$work_directory/docker-calls.log")"
assert_contains "$calls" "docker rename $ROLLBACK_CONTAINER $API_CONTAINER" \
    "The rollback must rename the previous container back."
assert_contains "$calls" "docker start $API_CONTAINER" \
    "The rollback must start the restored container."

# --- 3. TERM during the final readiness wait --------------------------------
# The new container already exists and is failing readiness. The rollback has to
# remove it and restore the previous one.
reset_world
printf 'running\n' >"$work_directory/containers/$API_CONTAINER"
printf 'stopped\n' >"$work_directory/containers/$ROLLBACK_CONTAINER"

run_signal_scenario TERM true true
status="$scenario_status"
[[ "$status" -eq 143 ]] ||
    fail "TERM during final readiness must exit 143 (got $status)."
[[ "$(container_state "$API_CONTAINER")" == "running" ]] ||
    fail "The restored container must be running after rollback."
[[ "$(container_state "$ROLLBACK_CONTAINER")" == "absent" ]] ||
    fail "No stale rollback container may remain after the rollback."
calls="$(cat "$work_directory/docker-calls.log")"
assert_contains "$calls" "docker rm -f $API_CONTAINER" \
    "The failed replacement container must be removed before restoring."

# Ordering is the contract, not just presence. docker refuses to rename onto a
# name that is still taken, so removing the failed container has to come first.
# If it did not, the rename would fail and the rollback would only look like it
# had worked.
remove_line="$(printf '%s\n' "$calls" | grep -n -F "docker rm -f $API_CONTAINER" | head -n 1 | cut -d: -f1)"
rename_line="$(printf '%s\n' "$calls" | grep -n -F "docker rename $ROLLBACK_CONTAINER $API_CONTAINER" | head -n 1 | cut -d: -f1)"
[[ -n "$remove_line" && -n "$rename_line" && "$remove_line" -lt "$rename_line" ]] ||
    fail "The failed container must be removed before the rollback rename (rm at ${remove_line:-none}, rename at ${rename_line:-none})."

# --- 4. INT gets the same rollback, with its own exit status ----------------
reset_world
printf 'stopped\n' >"$work_directory/containers/$ROLLBACK_CONTAINER"

run_signal_scenario INT true true
status="$scenario_status"
[[ "$status" -eq 130 ]] ||
    fail "INT must exit 130 (got $status)."
[[ "$(container_state "$API_CONTAINER")" == "running" ]] ||
    fail "INT during replacement must roll back exactly like TERM."
[[ "$(container_state "$ROLLBACK_CONTAINER")" == "absent" ]] ||
    fail "No stale rollback container may remain after an INT rollback."

# --- 5. A clean exit still succeeds and rolls nothing back ------------------
reset_world
printf 'running\n' >"$work_directory/containers/$API_CONTAINER"
printf 'stopped\n' >"$work_directory/containers/$ROLLBACK_CONTAINER"

run_exit_scenario 0 false false
status="$scenario_status"
[[ "$status" -eq 0 ]] || fail "A clean exit must stay 0 (got $status)."
calls="$(cat "$work_directory/docker-calls.log")"
assert_absent "$calls" "rename" "A successful run must not roll back."

# --- 6. A non-signal failure keeps the existing rollback semantics ----------
reset_world
printf 'running\n' >"$work_directory/containers/$API_CONTAINER"
printf 'stopped\n' >"$work_directory/containers/$ROLLBACK_CONTAINER"

run_exit_scenario 1 true true
status="$scenario_status"
[[ "$status" -eq 1 ]] || fail "A plain failure must preserve its exit code (got $status)."
[[ "$(container_state "$API_CONTAINER")" == "running" ]] ||
    fail "A plain failure must roll back as before."
[[ "$(container_state "$ROLLBACK_CONTAINER")" == "absent" ]] ||
    fail "A plain failure must not leave a stale rollback container."

# --- 7. static contract: the traps are installed and ordered ----------------
script_contents="$(cat "$DEPLOY_API_SCRIPT")"
assert_contains "$script_contents" "trap 'exit 143' TERM" \
    "SIGTERM must exit with the conventional 128+15 status."
assert_contains "$script_contents" "trap 'exit 130' INT" \
    "SIGINT must exit with the conventional 128+2 status."
assert_contains "$script_contents" "trap cleanup EXIT" \
    "The existing EXIT cleanup contract must remain."
assert_contains "$script_contents" "trap '' TERM INT" \
    "cleanup must not be interruptible by a second signal."

# The deployment contract itself must be untouched by this change.
assert_contains "$script_contents" "readonly READINESS_ATTEMPTS=36" \
    "The readiness attempt count must be unchanged."
assert_contains "$script_contents" "readonly READINESS_INTERVAL_SECONDS=5" \
    "The readiness interval must be unchanged."
assert_contains "$script_contents" "readonly READINESS_CURL_MAX_TIME_SECONDS=3" \
    "The readiness probe timeout must be unchanged."
assert_contains "$script_contents" "readonly API_STOP_GRACE_SECONDS=30" \
    "The stop grace must be unchanged."
assert_absent "$script_contents" "flock" \
    "deploy-api.sh must not take the deployment lock; the wrapper owns it."

printf '[deploy-api-test] PASS\n'
