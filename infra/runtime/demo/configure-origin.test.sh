#!/usr/bin/env bash

# Behaviour tests for the origin verification map of configure-origin.sh.
#
# The script is sourced rather than executed: it requires root, Nginx and
# systemd, while the map logic under test is plain functions. Each case runs in
# its own subshell so a fail() inside the script only ends that case. Tokens are
# throwaway fixtures; no AWS call is made.

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CONFIGURE_SCRIPT="$SCRIPT_DIRECTORY/configure-origin.sh"

readonly OLD_TOKEN="old_token_0123456789abcdefghijklmnopqrstuv"
readonly NEW_TOKEN="new-token-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
readonly OTHER_TOKEN="other_token_zyxwvutsrqponmlkjihgfedcba98"

work_directory=""

cleanup_tests() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-configure-origin-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup_tests EXIT

fail() {
    printf '[configure-origin-test] FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "$3 (expected to find: $2)"
}

# Runs a snippet with the script's functions defined. Prints the snippet's
# output; the exit status is the snippet's.
with_script() {
    bash -c 'set -euo pipefail; source "$1"; trap - EXIT; eval "$2"' _ "$CONFIGURE_SCRIPT" "$1"
}

write_map() {
    local file="$1"
    shift
    {
        printf '%s\n' 'map $http_x_origin_verify $ec_portfolio_origin_verified {' '    default 0;'
        local token
        for token in "$@"; do
            printf '    ~^%s$ 1;\n' "$token"
        done
        printf '%s\n' '}'
    } >"$file"
}

work_directory="$(mktemp -d /tmp/ec-portfolio-configure-origin-test.XXXXXX)"
cd "$work_directory"

# --- 1. the default map is byte-for-byte the pre-rotation format ------------

write_map expected-single.conf "$OLD_TOKEN"
with_script "origin_verify_token='$OLD_TOKEN'; render_origin_verify_map" >rendered-single.conf
cmp -s expected-single.conf rendered-single.conf ||
    fail "Without a retained token the map must be exactly the single-token format installed today."

write_map expected-double.conf "$NEW_TOKEN" "$OLD_TOKEN"
with_script "origin_verify_token='$NEW_TOKEN'; retained_origin_verify_token='$OLD_TOKEN'; render_origin_verify_map" \
    >rendered-double.conf
cmp -s expected-double.conf rendered-double.conf ||
    fail "With a retained token the map must accept the SSM token and the retained token."

# --- 2. the installed map parser accepts only the managed format ------------

write_map installed-one.conf "$OLD_TOKEN"
[[ "$(with_script "read_installed_origin_verify_tokens installed-one.conf")" == "$OLD_TOKEN" ]] ||
    fail "A single-token map must yield its token."

write_map installed-two.conf "$OLD_TOKEN" "$NEW_TOKEN"
[[ "$(with_script "read_installed_origin_verify_tokens installed-two.conf")" == "$OLD_TOKEN"$'\n'"$NEW_TOKEN" ]] ||
    fail "A two-token map must yield both tokens in order."

for case_name in foreign-line short-token missing-file; do
    case "$case_name" in
        foreign-line)
            write_map candidate.conf "$OLD_TOKEN"
            printf '    ~^.*$ 1;\n' >>candidate.conf
            ;;
        short-token)
            write_map candidate.conf "short"
            ;;
        missing-file)
            rm -f candidate.conf
            ;;
    esac
    status=0
    with_script "read_installed_origin_verify_tokens candidate.conf" >/dev/null 2>&1 || status=$?
    ((status != 0)) || fail "The parser must refuse a map with a $case_name."
done

# --- 3. selecting the retained token -----------------------------------------

select_with() {
    local ssm_token="$1"
    local map_file="$2"
    with_script "origin_verify_token='$ssm_token'
select_retained_origin_verify_token '$map_file'
printf '%s' \"\$retained_origin_verify_token\""
}

[[ "$(select_with "$NEW_TOKEN" installed-one.conf)" == "$OLD_TOKEN" ]] ||
    fail "Rotating to a new SSM token must retain the installed old token."
[[ "$(select_with "$NEW_TOKEN" installed-two.conf)" == "$OLD_TOKEN" ]] ||
    fail "Re-running during rotation must keep the same two tokens."
[[ -z "$(select_with "$OLD_TOKEN" installed-one.conf)" ]] ||
    fail "When the installed map already holds only the SSM token, nothing is retained."

status=0
output="$(select_with "$OTHER_TOKEN" installed-two.conf 2>&1)" || status=$?
((status != 0)) || fail "A third token must never be accepted."
assert_contains "$output" "more than one token besides the SSM token" "The refusal must say why."

status=0
output="$(select_with "$NEW_TOKEN" candidate.conf 2>&1)" || status=$?
((status != 0)) || fail "A missing installed map must stop the rotation."
assert_contains "$output" "missing or not in the managed format" "The refusal must say why."

# --- 4. the mode switch ------------------------------------------------------

[[ "$(with_script 'unset ORIGIN_VERIFY_RETAIN_INSTALLED_TOKEN; resolve_token_retention; printf %s "$retain_installed_token"')" == "false" ]] ||
    fail "Unset must keep the single-token behaviour."
[[ "$(with_script 'ORIGIN_VERIFY_RETAIN_INSTALLED_TOKEN=true; resolve_token_retention; printf %s "$retain_installed_token"')" == "true" ]] ||
    fail "true must enable retention."
status=0
with_script 'ORIGIN_VERIFY_RETAIN_INSTALLED_TOKEN=yes; resolve_token_retention' >/dev/null 2>&1 || status=$?
((status != 0)) || fail "Any value but true or false must be refused."

# --- 5. static contract ------------------------------------------------------

script_contents="$(cat "$CONFIGURE_SCRIPT")"
assert_contains "$script_contents" "ORIGIN_VERIFY_RETAIN_INSTALLED_TOKEN,AWS_REGION" \
    "The retention switch must survive the sudo re-exec."
assert_contains "$script_contents" 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' \
    "main must only run when the script is executed."
assert_contains "$script_contents" 'select_retained_origin_verify_token "$NGINX_SECRET_CONFIG"' \
    "Retention must read the installed map before it is replaced."

printf '[configure-origin-test] PASS\n'
