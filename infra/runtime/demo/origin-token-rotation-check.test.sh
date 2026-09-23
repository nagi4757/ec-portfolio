#!/usr/bin/env bash

# Behaviour tests for origin-token-rotation-check.sh.
#
# The check is sourced and its functions are called with sandbox paths: it
# requires root and a live Nginx otherwise. curl is a stub that answers the way
# the Nginx map would for the tokens listed in the sandbox, and it records its
# arguments so the tests can prove no token is ever passed on a command line.
# aws returns a fixture SSM token. No request leaves the machine.

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CHECK_SCRIPT="$SCRIPT_DIRECTORY/origin-token-rotation-check.sh"

readonly OLD_TOKEN="old_token_0123456789abcdefghijklmnopqrstuv"
readonly NEW_TOKEN="new-token-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"

work_directory=""

cleanup_tests() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-origin-rotation-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup_tests EXIT

fail() {
    printf '[origin-rotation-check-test] FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "$3 (expected to find: $2)"
}

assert_absent() {
    [[ "$1" != *"$2"* ]] || fail "$3 (unexpectedly found: $2)"
}

mode_of() {
    stat -f %Lp -- "$1" 2>/dev/null || stat -c %a -- "$1"
}

work_directory="$(mktemp -d /tmp/ec-portfolio-origin-rotation-test.XXXXXX)"
readonly STUB_BIN="$work_directory/bin"
export SANDBOX="$work_directory/sandbox"
mkdir -p "$STUB_BIN" "$SANDBOX/requests"

# curl answers like the origin: 403 without a header or with a token the map
# does not accept, 200 with an accepted one.
cat >"$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SANDBOX/curl-arguments.log"
token=""
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--config" ]]; then
        token="$(sed -n 's/^header = "X-Origin-Verify: \(.*\)"$/\1/p' "$2")"
        shift 2
    else
        shift
    fi
done
if [[ -n "$token" ]] && grep -qxF -- "$token" "$SANDBOX/accepted"; then
    printf '200'
else
    printf '403'
fi
STUB
cat >"$STUB_BIN/aws" <<'STUB'
#!/usr/bin/env bash
cat "$SANDBOX/ssm-token"
STUB
# timeout --signal=TERM --kill-after=5s 30s <command...>
cat >"$STUB_BIN/timeout" <<'STUB'
#!/usr/bin/env bash
while [[ "$1" == --* ]]; do shift; done
shift
exec "$@"
STUB
cat >"$STUB_BIN/sha256sum" <<'STUB'
#!/usr/bin/env bash
shasum -a 256
STUB
chmod 755 "$STUB_BIN"/*

map_with() {
    {
        printf '%s\n' 'map $http_x_origin_verify $ec_portfolio_origin_verified {' '    default 0;'
        local token
        for token in "$@"; do
            printf '    ~^%s$ 1;\n' "$token"
        done
        printf '%s\n' '}'
    } >"$SANDBOX/origin-secret.conf"
    printf '%s\n' "$@" >"$SANDBOX/accepted"
}

# Runs a check function in a fresh process with the sandbox wired in.
run_check() {
    check_status=0
    check_output="$(PATH="$STUB_BIN:$PATH" ORIGIN_SERVER_NAME="origin-demo.example.test" \
        bash -c 'set -euo pipefail
source "$1"
trap - EXIT
request_directory="$SANDBOX/requests"
read_origin_verify_token
eval "$2"' _ "$CHECK_SCRIPT" "$1" 2>&1)" || check_status=$?
}

readonly STATE="$SANDBOX/state"
readonly SECRET="$SANDBOX/origin-secret.conf"

# --- 1. capture keeps the non-SSM token, privately --------------------------

printf '%s' "$NEW_TOKEN" >"$SANDBOX/ssm-token"
map_with "$NEW_TOKEN" "$OLD_TOKEN"
run_check "capture_previous_token '$SECRET' '$STATE'"
((check_status == 0)) || fail "Capture must succeed while the origin accepts two tokens: $check_output"
[[ "$(cat "$STATE/previous-token")" == "$OLD_TOKEN" ]] || fail "The captured token must be the non-SSM token."
[[ "$(mode_of "$STATE")" == "700" && "$(mode_of "$STATE/previous-token")" == "600" ]] ||
    fail "The captured token must be readable by its owner only."
assert_contains "$check_output" "previous=" "Capture must report fingerprints."

map_with "$NEW_TOKEN"
run_check "capture_previous_token '$SECRET' '$SANDBOX/other-state'"
((check_status != 0)) || fail "Capture must refuse when the origin accepts only the SSM token."
assert_contains "$check_output" "ORIGIN_VERIFY_RETAIN_INSTALLED_TOKEN=true" "The refusal must say what to run first."

# --- 2. both: the old and the new token are accepted ------------------------

map_with "$NEW_TOKEN" "$OLD_TOKEN"
run_check "verify_rotation_state both '$SECRET' '$STATE/previous-token'"
((check_status == 0)) || fail "Both tokens accepted must pass: $check_output"
assert_contains "$check_output" "PASS previous token: HTTP 200" "The old token must be proved accepted."
assert_contains "$check_output" "PASS no header: HTTP 403" "A request without a header must be refused."

map_with "$NEW_TOKEN"
run_check "verify_rotation_state both '$SECRET' '$STATE/previous-token'"
((check_status != 0)) || fail "both must fail once the old token is no longer accepted."
assert_contains "$check_output" "FAIL previous token: HTTP 403, expected 200" "The failing token must be named."

# --- 3. new-only: the old token is refused and the map holds the new one ----

map_with "$NEW_TOKEN"
run_check "verify_rotation_state new-only '$SECRET' '$STATE/previous-token'"
((check_status == 0)) || fail "The finished rotation must pass new-only: $check_output"
assert_contains "$check_output" "PASS previous token: HTTP 403" "The old token must be proved refused."
assert_contains "$check_output" "PASS installed map: the SSM token only" "The map must hold the new token alone."

map_with "$NEW_TOKEN" "$OLD_TOKEN"
run_check "verify_rotation_state new-only '$SECRET' '$STATE/previous-token'"
((check_status != 0)) || fail "new-only must fail while the old token is still accepted."

# --- 4. refusals --------------------------------------------------------------

printf '%s' "$NEW_TOKEN" >"$SANDBOX/same-token"
run_check "verify_rotation_state both '$SECRET' '$SANDBOX/same-token'"
((check_status != 0)) || fail "A captured token equal to the SSM token must be refused."

run_check "verify_rotation_state both '$SECRET' '$SANDBOX/missing'"
((check_status != 0)) || fail "Verification without a captured token must be refused."

# --- 5. no token on a command line or in any output -------------------------

curl_arguments="$(cat "$SANDBOX/curl-arguments.log")"
for token in "$OLD_TOKEN" "$NEW_TOKEN"; do
    assert_absent "$curl_arguments" "$token" "A token must never be a curl argument."
done
map_with "$NEW_TOKEN" "$OLD_TOKEN"
run_check "capture_previous_token '$SECRET' '$SANDBOX/state-2'; verify_rotation_state both '$SECRET' '$STATE/previous-token'"
for token in "$OLD_TOKEN" "$NEW_TOKEN"; do
    assert_absent "$check_output" "$token" "A token must never be printed."
done
[[ -z "$(ls -A "$SANDBOX/requests")" ]] || fail "Per-request header files must be deleted."

# --- 6. forget ----------------------------------------------------------------

run_check "forget_captured_token '$STATE'"
((check_status == 0)) || fail "forget must succeed: $check_output"
[[ ! -e "$STATE" ]] || fail "forget must delete the captured token and its directory."

# --- 7. static contract -------------------------------------------------------

check_contents="$(cat "$CHECK_SCRIPT")"
assert_contains "$check_contents" 'curl_arguments+=(--config "$header_file")' "Tokens must reach curl through a config file."
assert_absent "$check_contents" '--header "X-Origin-Verify: $' "A token must never be put in a header argument."
assert_contains "$check_contents" 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' "main must only run when executed."

printf '[origin-rotation-check-test] PASS\n'
