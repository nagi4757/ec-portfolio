#!/usr/bin/env bash

# Behaviour tests for the issuance/renewal -> backup write-back contract.
#
# The point of these tests is the failure direction: a certificate that renews
# successfully but is never copied off the host leaves a replacement host with
# nothing to restore, and that must be reported rather than swallowed. Equally,
# a failed backup must not damage the certificate or Nginx that are already
# working.
#
# Everything runs against fakes in a sandbox. No certbot, no Nginx, no AWS call,
# no systemctl, and the production /etc/letsencrypt is never touched.

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ACME_SCRIPT="$SCRIPT_DIRECTORY/configure-acme.sh"
readonly RENEW_SCRIPT="$SCRIPT_DIRECTORY/renew-origin-cert.sh"
readonly RENEW_UNIT="$SCRIPT_DIRECTORY/ec-portfolio-certbot-renew.service"
readonly SYNC_SCRIPT="$SCRIPT_DIRECTORY/sync-origin-tls.sh"

work_directory=""

cleanup_tests() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-writeback-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup_tests EXIT

fail() {
    printf '[origin-tls-writeback-test] FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    printf '%s' "$1" | grep -Fq -- "$2" || fail "$3 (expected to find: $2)"
}

assert_absent() {
    printf '%s' "$1" | grep -Fq -- "$2" && fail "$3 (unexpectedly found: $2)"
    return 0
}

work_directory="$(mktemp -d /tmp/ec-portfolio-writeback-test.XXXXXX)"

# Runs the script's real back_up_origin_tls_state() against a fake helper, in
# its own process so the script's globals and traps stay contained. The helper
# path is overridden through the same env hook the script exposes, so the code
# under test is the production function, not a copy of it.
#
# $1 script, $2 fake helper exit code, $3 marker file
run_backup_step() {
    local script="$1"
    local helper_status="$2"
    local marker="$3"
    local helper="$work_directory/helper-$helper_status.sh"

    cat >"$helper" <<HELPER
#!/usr/bin/env bash
printf '%s\n' "backup invoked: \$*" >>"$marker"
printf 'ORIGIN_TLS_BUCKET=%s\n' "\${ORIGIN_TLS_BUCKET-}" >>"$marker"
exit $helper_status
HELPER
    chmod 755 "$helper"

    ORIGIN_TLS_BUCKET="sandbox-bucket" \
        ORIGIN_TLS_SYNC_SCRIPT="$helper" \
        bash -c 'source "$1"; back_up_origin_tls_state' _ "$script" 2>&1
}

# --- 1. both scripts declare the write-back step ----------------------------
acme_contents="$(cat "$ACME_SCRIPT")"
renew_contents="$(cat "$RENEW_SCRIPT")"

assert_contains "$acme_contents" "back_up_origin_tls_state" \
    "configure-acme.sh must back the issued certificate up."
assert_contains "$renew_contents" "back_up_origin_tls_state" \
    "renew-origin-cert.sh must back the renewed certificate up."

# --- 2. the backup runs only after the certificate is validated/installed ---
# Ordering is the contract: backing up before validation would store a
# certificate that was never checked. The call is counted rather than located,
# because an extra earlier call would leave the last one correctly placed and
# still upload unvalidated state.
main_body() {
    printf '%s\n' "$1" | sed -n '/^main() {$/,/^}$/p'
}

# $1 body, $2 call line, $3 description
assert_called_once() {
    local occurrences
    occurrences="$(printf '%s\n' "$1" | grep -c "^    $2\$" || true)"
    (( occurrences == 1 )) ||
        fail "$3 must call $2 exactly once in main() (found $occurrences)."
}

# $1 body, $2 earlier call, $3 later call, $4 description
assert_ordered() {
    local earlier later
    earlier="$(printf '%s\n' "$1" | grep -n "^    $2\$" | head -n 1 | cut -d: -f1)"
    later="$(printf '%s\n' "$1" | grep -n "^    $3\$" | head -n 1 | cut -d: -f1)"
    [[ -n "$earlier" && -n "$later" && "$earlier" -lt "$later" ]] ||
        fail "$4 ($2 must precede $3)."
}

acme_main="$(main_body "$acme_contents")"
renew_main="$(main_body "$renew_contents")"
[[ -n "$acme_main" && -n "$renew_main" ]] || fail "Unable to locate main() in a script."

assert_called_once "$acme_main" "back_up_origin_tls_state" "configure-acme.sh"
assert_called_once "$renew_main" "back_up_origin_tls_state" "renew-origin-cert.sh"

assert_ordered "$acme_main" "validate_certificate_contract" "back_up_origin_tls_state" \
    "configure-acme.sh must validate the certificate before backing it up"
assert_ordered "$renew_main" "reload_nginx_after_change" "back_up_origin_tls_state" \
    "renew-origin-cert.sh must reload Nginx before backing the certificate up"

renew_backup_line="$(printf '%s\n' "$renew_contents" | grep -n "^    back_up_origin_tls_state$" | head -n 1 | cut -d: -f1)"

# --- 3. a no-change renewal returns before the backup -----------------------
# The stored archive already matches, so there is nothing to write.
no_change_block="$(printf '%s\n' "$renew_contents" |
    sed -n '/is not due for renewal/,/^    fi$/p')"
assert_contains "$no_change_block" "return" \
    "A no-change renewal must return before the backup step."
early_return_line="$(printf '%s\n' "$renew_contents" | grep -n "is not due for renewal" | tail -n 1 | cut -d: -f1)"
[[ "$early_return_line" -lt "$renew_backup_line" ]] ||
    fail "The no-change early return must come before the backup call."

# --- 4. issuance succeeds when the backup succeeds --------------------------
marker="$work_directory/acme-ok.log"
: >"$marker"
output="$(run_backup_step "$ACME_SCRIPT" 0 "$marker")" ||
    fail "Issuance must succeed when the backup succeeds."
assert_contains "$(cat "$marker")" "backup invoked: backup" \
    "The backup helper must be invoked with the backup subcommand."
assert_contains "$(cat "$marker")" "ORIGIN_TLS_BUCKET=sandbox-bucket" \
    "The bucket must be passed through to the backup helper."

# --- 5. issuance fails when the backup fails --------------------------------
marker="$work_directory/acme-fail.log"
: >"$marker"
status=0
output="$(run_backup_step "$ACME_SCRIPT" 1 "$marker")" || status=$?
(( status != 0 )) ||
    fail "A failed backup must fail issuance rather than be swallowed."
assert_contains "$(cat "$marker")" "backup invoked" \
    "The backup helper must still have been attempted."

# --- 6. renewal succeeds when the backup succeeds ---------------------------
marker="$work_directory/renew-ok.log"
: >"$marker"
output="$(run_backup_step "$RENEW_SCRIPT" 0 "$marker")" ||
    fail "Renewal must succeed when the backup succeeds."

# --- 7. renewal fails when the backup fails ---------------------------------
marker="$work_directory/renew-fail.log"
: >"$marker"
status=0
output="$(run_backup_step "$RENEW_SCRIPT" 1 "$marker")" || status=$?
(( status != 0 )) ||
    fail "A failed backup must fail renewal rather than be swallowed."

# --- 8. a failed backup must not remove or revert local state ---------------
# The real helper only reads /etc/letsencrypt and writes a temp archive, so the
# contract is asserted on what the script executes: it must never run certbot,
# Nginx or systemctl, and must never delete the certbot tree. Comments and
# operator-facing messages legitimately name those things, so the check is made
# against code lines with comments stripped, matching a command in statement
# position rather than the bare word anywhere in the file.
sync_contents="$(cat "$SYNC_SCRIPT")"
sync_code="$(printf '%s\n' "$sync_contents" | sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*#.*$//')"

printf '%s\n' "$sync_code" |
    grep -qE '(^|[;&|(]|\bthen\b|\bdo\b|\bexec\b)[[:space:]]*(sudo[[:space:]]+)?(certbot|nginx|systemctl)\b' &&
    fail "The backup helper must not run certbot, Nginx or systemctl."

printf '%s\n' "$sync_code" | grep -qE 'rm[[:space:]].*/etc/letsencrypt' &&
    fail "The backup helper must not delete the certbot tree."

# The only removal in the helper is its own scratch directory, and it is fenced
# by the path it created.
assert_contains "$sync_contents" 'rm -rf -- "$work_directory"' \
    "The only deletion must be the helper's own temp directory."
assert_contains "$sync_contents" "refusing to overwrite existing certbot state" \
    "The helper must refuse to overwrite an existing certbot tree."

# The failure messages must say the local state is intact, so an operator reading
# a failed run knows the site is still serving.
assert_contains "$acme_contents" "local certificate and Nginx are untouched" \
    "The issuance backup failure must state that local state is intact."
assert_contains "$renew_contents" "local certificate and Nginx are untouched" \
    "The renewal backup failure must state that local state is intact."

# --- 9. no key material reaches stdout or stderr ----------------------------
combined_output="$(
    cat "$work_directory"/acme-ok.log "$work_directory"/acme-fail.log \
        "$work_directory"/renew-ok.log "$work_directory"/renew-fail.log
)"
for leak in "BEGIN RSA PRIVATE KEY" "BEGIN PRIVATE KEY" "BEGIN EC PRIVATE KEY" "BEGIN CERTIFICATE"; do
    assert_absent "$combined_output" "$leak" \
        "Key or certificate material must never be printed: $leak"
done
# Anchored to statement position and to whole words: without that, "cat" matches
# inside "certificate_file" and the check fires on a plain variable assignment.
for script_body in "$acme_contents" "$renew_contents" "$sync_contents"; do
    printf '%s\n' "$script_body" |
        grep -qE '(^|[;&|(]|\bthen\b|\bdo\b)[[:space:]]*(cat|echo|printf)[[:space:]][^|]*(privkey|fullchain|cert\.pem)' &&
        fail "A script prints certificate or key file contents."
done

# --- 10. the bucket is required, not optional -------------------------------
for script_body in "$acme_contents" "$renew_contents"; do
    printf '%s' "$script_body" | grep -Fq 'Required environment variable is missing: ORIGIN_TLS_BUCKET' ||
        fail "ORIGIN_TLS_BUCKET must be required, so a run cannot silently skip the backup."
done

# --- 10b. the bucket survives the sudo re-exec -------------------------------
# configure-acme.sh re-execs itself under sudo before validate_inputs runs, so a
# variable missing from --preserve-env is gone by the time it is required and
# every non-root invocation fails.
preserve_env_line="$(printf '%s\n' "$acme_contents" | grep -F -- '--preserve-env=' | head -n 1)"
[[ -n "$preserve_env_line" ]] || fail "Unable to locate the sudo re-exec line."
assert_contains "$preserve_env_line" "ORIGIN_TLS_BUCKET" \
    "ORIGIN_TLS_BUCKET must survive the sudo re-exec."

# --- 11. the renewal unit loads the bucket and fails closed if it is absent --
unit_contents="$(cat "$RENEW_UNIT")"
assert_contains "$unit_contents" "EnvironmentFile=/etc/ec-portfolio/origin-tls.env" \
    "The renewal unit must load the bucket name."
assert_absent "$unit_contents" "EnvironmentFile=-" \
    "The env file must not be optional; a missing file must fail the unit."

# --- 12. configure-acme installs the helper and the env file ----------------
assert_contains "$acme_contents" "install_origin_tls_backup" \
    "configure-acme.sh must install the backup helper for the renewal timer."
assert_contains "$acme_contents" "/usr/local/sbin/ec-portfolio-sync-origin-tls" \
    "The helper must be installed to the fixed path the timer can reach."
assert_contains "$acme_contents" 'install -o root -g root -m 755 \' \
    "The installed helper must be root owned and executable."
assert_contains "$acme_contents" "ORIGIN_TLS_ENV_FILE" \
    "The bucket name must be persisted for the renewal timer."

printf '[origin-tls-writeback-test] PASS\n'
