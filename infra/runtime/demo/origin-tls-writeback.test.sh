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

# Matched with a glob rather than `printf | grep -Fq`. grep -q exits on its
# first match, printf then dies of SIGPIPE, and under `set -o pipefail` the
# pipeline reports 141 -- so a haystack whose match comes early and whose
# remainder is still being written fails the assertion it just satisfied. That
# race is a function of file size and scheduling, which made it intermittent.
# sync-origin-tls.test.sh already uses this form.
assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "$3 (expected to find: $2)"
}

assert_absent() {
    [[ "$1" != *"$2"* ]] || fail "$3 (unexpectedly found: $2)"
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

# Here-string, not a pipe, for the same SIGPIPE reason as assert_contains -- and
# here the failure mode is the dangerous direction: a pipeline that reports 141
# makes the `&&` skip fail(), so a helper that really did delete /etc/letsencrypt
# would pass this check.
if grep -qE 'rm[[:space:]].*/etc/letsencrypt' <<<"$sync_code"; then
    fail "The backup helper must not delete the certbot tree."
fi

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

# --- 13. the Certbot configuration lookup is pinned, not predicted ----------
# Certbot reads /etc/letsencrypt/cli.ini and ${XDG_CONFIG_HOME:-~/.config}/
# letsencrypt/cli.ini before any command-line flag, and either may declare
# pre-hook, post-hook or deploy-hook, which run as root.
#
# The second path follows the caller's environment. Measured against certbot:
# XDG unset with HOME=/root gives /root/.config/letsencrypt/cli.ini; an empty or
# relative XDG_CONFIG_HOME resolves against the working directory; an absolute
# one is taken as given. The scripts therefore pin the environment rather than
# predict it, and these tests hold them to that.

certbot_marker="$work_directory/certbot-invoked"
fake_bin="$work_directory/fake-bin"
mkdir -p "$fake_bin"

# Records the environment certbot is actually handed, so the pinning is checked
# by observation rather than by grepping the source.
cat >"$fake_bin/certbot" <<FAKE
#!/usr/bin/env bash
{
    printf 'certbot invoked: %s\n' "\$*"
    printf 'HOME=%s\n' "\${HOME-<unset>}"
    printf 'XDG_CONFIG_HOME=%s\n' "\${XDG_CONFIG_HOME-<unset>}"
} >>"$certbot_marker"
exit 0
FAKE
chmod 755 "$fake_bin/certbot"

# The scripts wrap certbot in `timeout`. A fake keeps this suite independent of
# whether the host has GNU coreutils.
cat >"$fake_bin/timeout" <<'FAKETIMEOUT'
#!/usr/bin/env bash
while [[ "$1" == --* ]]; do shift; done
shift
exec "$@"
FAKETIMEOUT
chmod 755 "$fake_bin/timeout"

# Runs the script's real verify_no_global_certbot_config() in its own process.
# $1 script, $2 sandbox prefix, rest: caller environment to expose
run_preflight() {
    local script="$1" prefix="$2"
    shift 2
    env "$@" PATH="$fake_bin:$PATH" CERTBOT_CONFIG_PREFIX="$prefix" \
        bash -c 'source "$1"; verify_no_global_certbot_config' _ "$script" 2>&1
}

# Runs the real guard and then the real run_certbot, which is the order main()
# uses. The sourced script sets `set -e`, so a failing guard aborts before
# certbot -- that is the property under test, and the marker proves it.
# $1 script, $2 sandbox prefix, rest: caller environment to expose
run_guard_then_certbot() {
    local script="$1" prefix="$2"
    shift 2
    env "$@" PATH="$fake_bin:$PATH" CERTBOT_CONFIG_PREFIX="$prefix" \
        bash -c 'source "$1"; verify_no_global_certbot_config; run_certbot certbot plugins' \
        _ "$script" 2>&1
}

# $1 sandbox prefix, $2 path under it, $3 contents
seed_config() {
    mkdir -p "$1/$(dirname "$2")"
    printf '%s\n' "$3" >"$1/$2"
}

hostile_xdg="$work_directory/hostile-xdg"
hostile_home="$work_directory/hostile-home"
mkdir -p "$hostile_xdg/letsencrypt" "$hostile_home/.config/letsencrypt"
printf 'pre-hook = /tmp/evil.sh\n' >"$hostile_xdg/letsencrypt/cli.ini"
printf 'pre-hook = /tmp/evil.sh\n' >"$hostile_home/.config/letsencrypt/cli.ini"

for script in "$ACME_SCRIPT" "$RENEW_SCRIPT"; do
    script_name="${script##*/}"

    # Both canonical locations are refused.
    for canonical in "etc/letsencrypt/cli.ini" "root/.config/letsencrypt/cli.ini"; do
        prefix="$work_directory/sandbox-${script_name}-${canonical//\//-}"
        mkdir -p "$prefix"
        seed_config "$prefix" "$canonical" 'pre-hook = /tmp/evil.sh'
        if run_preflight "$script" "$prefix" >/dev/null 2>&1; then
            fail "$script_name must refuse /$canonical."
        fi
        output="$(run_preflight "$script" "$prefix" || true)"
        assert_contains "$output" "Certbot global configuration file" \
            "$script_name must name the refused configuration file (/$canonical)."

        # Refusal must not touch operator state.
        [[ -f "$prefix/$canonical" ]] ||
            fail "$script_name must not delete the configuration it refuses."
        assert_contains "$(cat "$prefix/$canonical")" "pre-hook = /tmp/evil.sh" \
            "$script_name must not rewrite the configuration it refuses."
    done

    # A benign file is refused too: the contract bans the file, not a directive
    # list, which is what also removes --server and --authenticator override.
    benign_prefix="$work_directory/sandbox-benign-$script_name"
    mkdir -p "$benign_prefix"
    seed_config "$benign_prefix" "etc/letsencrypt/cli.ini" 'rsa-key-size = 4096'
    if run_preflight "$script" "$benign_prefix" >/dev/null 2>&1; then
        fail "$script_name must refuse any global Certbot configuration, hooks or not."
    fi

    # A dangling symlink is a path certbot would read once its target appeared.
    dangling_prefix="$work_directory/sandbox-dangling-$script_name"
    mkdir -p "$dangling_prefix/etc/letsencrypt"
    ln -s "$work_directory/no-such-cli.ini" "$dangling_prefix/etc/letsencrypt/cli.ini"
    if run_preflight "$script" "$dangling_prefix" >/dev/null 2>&1; then
        fail "$script_name must refuse a dangling symlink at a canonical path."
    fi

    # A clean host passes. Without this the refusals above could hold for the
    # wrong reason, and it is also what proves the guard does not report failure
    # from a resolver that quietly died in a command substitution.
    clean_prefix="$work_directory/sandbox-clean-$script_name"
    mkdir -p "$clean_prefix"
    run_preflight "$script" "$clean_prefix" >/dev/null ||
        fail "$script_name must accept a host with no Certbot global configuration."

    # The caller's environment cannot move the checked paths. Every hostile
    # shape from the measured table is offered; the canonical locations under
    # the sandbox stay empty, so the guard must still pass.
    for hostile_env in \
        "XDG_CONFIG_HOME=$hostile_xdg" \
        "XDG_CONFIG_HOME=" \
        "XDG_CONFIG_HOME=relative-path" \
        "HOME=$hostile_home" \
        "HOME="
    do
        run_preflight "$script" "$clean_prefix" "$hostile_env" >/dev/null ||
            fail "$script_name preflight must not depend on the caller's ${hostile_env%%=*}."
    done

    # And a configuration at a canonical path is still caught while the caller
    # points the environment elsewhere.
    hostile_prefix="$work_directory/sandbox-hostile-$script_name"
    mkdir -p "$hostile_prefix"
    seed_config "$hostile_prefix" "root/.config/letsencrypt/cli.ini" 'deploy-hook = /tmp/evil.sh'
    if run_preflight "$script" "$hostile_prefix" \
        "XDG_CONFIG_HOME=$hostile_xdg" "HOME=$hostile_home" >/dev/null 2>&1; then
        fail "$script_name must still refuse a canonical configuration under a hostile environment."
    fi

    # End to end, through the real run_certbot: a refused configuration must
    # stop the run before certbot is executed.
    rm -f "$certbot_marker"
    if run_guard_then_certbot "$script" "$hostile_prefix" >/dev/null 2>&1; then
        fail "$script_name must not reach certbot while a global configuration exists."
    fi
    [[ ! -e "$certbot_marker" ]] ||
        fail "$script_name invoked certbot despite a prohibited Certbot configuration."

    # Positive control: on a clean host the same path does reach certbot, which
    # is what makes the assertion above meaningful rather than vacuous. The fake
    # records the environment it was handed, so the pinning is observed.
    rm -f "$certbot_marker"
    run_guard_then_certbot "$script" "$clean_prefix" \
        "XDG_CONFIG_HOME=$hostile_xdg" "HOME=$hostile_home" >/dev/null ||
        fail "$script_name must reach certbot on a host with no global configuration."
    [[ -e "$certbot_marker" ]] ||
        fail "The certbot harness is not wired: $script_name never reached certbot."
    marker_contents="$(cat "$certbot_marker")"
    assert_contains "$marker_contents" "HOME=/root" \
        "$script_name must hand certbot a pinned HOME, whatever the caller exported."
    assert_contains "$marker_contents" "XDG_CONFIG_HOME=<unset>" \
        "$script_name must clear XDG_CONFIG_HOME before invoking certbot."
    assert_absent "$marker_contents" "$hostile_home" \
        "The caller's HOME must not reach certbot."
    assert_absent "$marker_contents" "$hostile_xdg" \
        "The caller's XDG_CONFIG_HOME must not reach certbot."
done

rm -f "$certbot_marker"

# --- 14. the preflight precedes the certbot invocation in both scripts ------
# The end-to-end check above proves the guard stops the run. This proves the
# call sits before certbot in main() as well, so the ordering is not an accident
# of how the tests drive the functions.
# $1 script contents, $2 script name
assert_guard_precedes_certbot() {
    local body guard certbot_call
    body="$(main_body "$1")"
    # `|| true` on both: under set -e with pipefail a grep that matches nothing
    # fails the pipeline, the assignment fails with it, and the script dies
    # before reaching the checks below -- reporting a bare exit 1 instead of
    # saying which contract was broken.
    guard="$(printf '%s\n' "$body" | grep -n "^    verify_no_global_certbot_config$" | head -n 1 | cut -d: -f1 || true)"
    certbot_call="$(printf '%s\n' "$body" | grep -n "^    run_certbot certbot" | head -n 1 | cut -d: -f1 || true)"
    [[ -n "$guard" ]] ||
        fail "$2 must call verify_no_global_certbot_config in main()."
    [[ -n "$certbot_call" ]] ||
        fail "Unable to locate the certbot invocation in $2 main()."
    (( guard < certbot_call )) ||
        fail "$2 must check for a global Certbot configuration before invoking certbot."
}

assert_guard_precedes_certbot "$acme_contents" "configure-acme.sh"
assert_guard_precedes_certbot "$renew_contents" "renew-origin-cert.sh"

# The guard must not reintroduce a resolver whose failure disappears into a
# command substitution: fail() would run in the subshell, the loop would iterate
# over nothing, and the function would return 0 on a host it could not check.
for script_contents in "$acme_contents" "$renew_contents"; do
    assert_absent "$script_contents" 'for candidate in "$GLOBAL_CERTBOT_CONFIG_FILE" "$(' \
        "The guard must not resolve a candidate path in a command substitution."
    assert_contains "$script_contents" 'for candidate in "${GLOBAL_CERTBOT_CONFIG_FILES[@]}"' \
        "The guard must iterate the literal canonical path list."
    assert_contains "$script_contents" '-u XDG_CONFIG_HOME' \
        "certbot must be invoked with XDG_CONFIG_HOME cleared."
    assert_contains "$script_contents" 'HOME="$CERTBOT_HOME"' \
        "certbot must be invoked with HOME pinned to the constant the guard uses."
    assert_contains "$script_contents" '--no-directory-hooks' \
        "The certbot invocation must keep disabling renewal-hooks/ directories."
done

printf '[origin-tls-writeback-test] PASS\n'
