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
    occurrences="$(grep -c "^    $2\$" <<<"$1" || true)"
    (( occurrences == 1 )) ||
        fail "$3 must call $2 exactly once in main() (found $occurrences)."
}

# $1 body, $2 earlier call, $3 later call, $4 description
assert_ordered() {
    local earlier later
    earlier="$(grep -n "^    $2\$" <<<"$1" | head -n 1 | cut -d: -f1 || true)"
    later="$(grep -n "^    $3\$" <<<"$1" | head -n 1 | cut -d: -f1 || true)"
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

renew_backup_line="$(grep -n "^    back_up_origin_tls_state$" <<<"$renew_contents" | head -n 1 | cut -d: -f1 || true)"
[[ -n "$renew_backup_line" ]] || fail "Unable to locate the backup call in renew-origin-cert.sh."

# --- 3. a no-change renewal returns before the backup -----------------------
# The stored archive already matches, so there is nothing to write.
no_change_block="$(sed -n '/is not due for renewal/,/^    fi$/p' <<<"$renew_contents")"
assert_contains "$no_change_block" "return" \
    "A no-change renewal must return before the backup step."
early_return_line="$(grep -n "is not due for renewal" <<<"$renew_contents" | tail -n 1 | cut -d: -f1 || true)"
[[ -n "$early_return_line" ]] || fail "Unable to locate the no-change early return."
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
sync_code="$(sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*#.*$//' <<<"$sync_contents")"

# Matched from a here-string. Piped into `grep -q`, grep exits on its first
# match, printf dies of SIGPIPE, and `set -o pipefail` reports 141 -- so the
# result flips on file size and scheduling.
if grep -qE '(^|[;&|(]|\bthen\b|\bdo\b|\bexec\b)[[:space:]]*(sudo[[:space:]]+)?(certbot|nginx|systemctl)\b' <<<"$sync_code"; then
    fail "The backup helper must not run certbot, Nginx or systemctl."
fi

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
    if grep -qE '(^|[;&|(]|\bthen\b|\bdo\b)[[:space:]]*(cat|echo|printf)[[:space:]][^|]*(privkey|fullchain|cert\.pem)' <<<"$script_body"; then
        fail "A script prints certificate or key file contents."
    fi
done

# --- 10. the bucket is required, not optional -------------------------------
for script_body in "$acme_contents" "$renew_contents"; do
    grep -Fq 'Required environment variable is missing: ORIGIN_TLS_BUCKET' <<<"$script_body" ||
        fail "ORIGIN_TLS_BUCKET must be required, so a run cannot silently skip the backup."
done

# --- 10b. the bucket survives the sudo re-exec -------------------------------
# configure-acme.sh re-execs itself under sudo before validate_inputs runs, so a
# variable missing from --preserve-env is gone by the time it is required and
# every non-root invocation fails.
preserve_env_line="$(grep -F -- '--preserve-env=' <<<"$acme_contents" | head -n 1 || true)"
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

# --- 13. the Certbot global configuration contract --------------------------
# Certbot reads /etc/letsencrypt/cli.ini and ${XDG_CONFIG_HOME:-~/.config}/
# letsencrypt/cli.ini before any command-line flag, and either may declare
# pre-hook, post-hook or deploy-hook, which run as root.
#
# /etc/letsencrypt/cli.ini is not ours to forbid: on Amazon Linux 2023 the
# certbot RPM owns it and writes it on every install, carrying exactly
# "preconfigured-renewal = True" and "max-log-backups = 0". Refusing it would
# block renewal on every host with certbot installed and block issuance on every
# replacement host the moment dnf put it back. So it is held to a contract --
# still the package's file, still saying only those two things -- and anything
# else fails closed. The per-user path stays forbidden outright.

certbot_marker="$work_directory/certbot-invoked"
fake_bin="$work_directory/fake-bin"
mkdir -p "$fake_bin"

# Records the environment certbot is handed, so the pinning is checked by
# observation rather than by grepping the source.
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

# Stands in for rpm. The sandbox files belong to no package, so the real rpm
# would refuse every fixture and the contract could never be exercised. The fake
# answers from two files the tests write, which is what lets a single fixture be
# replayed as pristine package state, as tampered state, or as unowned.
cat >"$fake_bin/rpm" <<'FAKERPM'
#!/usr/bin/env bash
# -qf --queryformat '%{NAME}\n' FILE  -> owner name on stdout, or exit 1
# -Vf FILE                            -> exit 0 pristine, 1 modified
mode=""
for arg in "$@"; do
    case "$arg" in
        -qf) mode="owner" ;;
        -Vf) mode="verify" ;;
    esac
done
case "$mode" in
    owner)
        if [[ -f "$FAKE_RPM_OWNER_FILE" ]]; then cat "$FAKE_RPM_OWNER_FILE"; exit 0; fi
        echo "file is not owned by any package" >&2; exit 1 ;;
    verify)
        if [[ -f "$FAKE_RPM_TAMPERED_FILE" ]]; then echo "S.5....T.  c file"; exit 1; fi
        exit 0 ;;
    *) exit 2 ;;
esac
FAKERPM
chmod 755 "$fake_bin/rpm"

rpm_owner_file="$work_directory/fake-rpm-owner"
rpm_tampered_file="$work_directory/fake-rpm-tampered"
printf 'certbot\n' >"$rpm_owner_file"
rm -f "$rpm_tampered_file"

# $1 script, $2 sandbox prefix, rest: extra environment
run_contract() {
    local script="$1" prefix="$2"
    shift 2
    env "$@" PATH="$fake_bin:$PATH" CERTBOT_CONFIG_PREFIX="$prefix" \
        FAKE_RPM_OWNER_FILE="$rpm_owner_file" FAKE_RPM_TAMPERED_FILE="$rpm_tampered_file" \
        bash -c 'source "$1"; verify_global_certbot_config_contract' _ "$script" 2>&1
}

# Runs the real guard and then the real run_certbot, which is the order main()
# uses. The sourced script sets `set -e`, so a failing guard ends the run before
# certbot -- that is the property under test, and the marker proves it.
run_contract_then_certbot() {
    local script="$1" prefix="$2"
    shift 2
    env "$@" PATH="$fake_bin:$PATH" CERTBOT_CONFIG_PREFIX="$prefix" \
        FAKE_RPM_OWNER_FILE="$rpm_owner_file" FAKE_RPM_TAMPERED_FILE="$rpm_tampered_file" \
        bash -c 'source "$1"; verify_global_certbot_config_contract; run_certbot certbot plugins' \
        _ "$script" 2>&1
}

# The Amazon Linux 2023 package default, byte for byte in the directives that
# matter. Confirmed against certbot-2.6.0-4.amzn2023.0.1.noarch.
write_package_cli_ini() {
    mkdir -p "$1/etc/letsencrypt"
    cat >"$1/etc/letsencrypt/cli.ini" <<'PKG'
# This is an example of the kind of things you can specify in this file.
preconfigured-renewal = True
max-log-backups = 0
PKG
}

new_prefix() {
    local p="$work_directory/sandbox-$1-$2"
    rm -rf "$p"; mkdir -p "$p"
    printf '%s' "$p"
}

hostile_xdg="$work_directory/hostile-xdg"
hostile_home="$work_directory/hostile-home"
mkdir -p "$hostile_xdg/letsencrypt" "$hostile_home/.config/letsencrypt"
printf 'pre-hook = /tmp/evil.sh\n' >"$hostile_xdg/letsencrypt/cli.ini"
printf 'pre-hook = /tmp/evil.sh\n' >"$hostile_home/.config/letsencrypt/cli.ini"

for script in "$ACME_SCRIPT" "$RENEW_SCRIPT"; do
    script_name="${script##*/}"

    # --- the package default is accepted -----------------------------------
    pkg_prefix="$(new_prefix pkg "$script_name")"
    write_package_cli_ini "$pkg_prefix"
    run_contract "$script" "$pkg_prefix" >/dev/null ||
        fail "$script_name must accept the certbot package default cli.ini."

    # A host with no certbot installed yet has no file at all.
    absent_prefix="$(new_prefix absent "$script_name")"
    run_contract "$script" "$absent_prefix" >/dev/null ||
        fail "$script_name must accept a host with no Certbot global configuration."

    # --- tampering with the package file is refused -------------------------
    touch "$rpm_tampered_file"
    if run_contract "$script" "$pkg_prefix" >/dev/null 2>&1; then
        fail "$script_name must refuse a modified package cli.ini."
    fi
    tamper_output="$(run_contract "$script" "$pkg_prefix" || true)"
    assert_contains "$tamper_output" "differs from what the certbot package installed" \
        "$script_name must say the package file was modified."
    rm -f "$rpm_tampered_file"

    # --- a file no package owns is refused ----------------------------------
    rm -f "$rpm_owner_file"
    if run_contract "$script" "$pkg_prefix" >/dev/null 2>&1; then
        fail "$script_name must refuse a cli.ini that no RPM package owns."
    fi
    # Owned by the wrong package is refused too.
    printf 'some-other-package\n' >"$rpm_owner_file"
    if run_contract "$script" "$pkg_prefix" >/dev/null 2>&1; then
        fail "$script_name must refuse a cli.ini owned by a package other than certbot."
    fi
    printf 'certbot\n' >"$rpm_owner_file"

    # --- injected directives are refused ------------------------------------
    for injected in \
        'pre-hook = /tmp/evil.sh' \
        'post-hook = /tmp/evil.sh' \
        'deploy-hook = /tmp/evil.sh' \
        'renew-hook = /tmp/evil.sh' \
        'server = https://attacker.invalid/directory' \
        'authenticator = manual' \
        'config-dir = /tmp/attacker' \
        'work-dir = /tmp/attacker' \
        'logs-dir = /tmp/attacker' \
        'unknown-key = 1'
    do
        inj_prefix="$(new_prefix inj "$script_name-${RANDOM}")"
        write_package_cli_ini "$inj_prefix"
        printf '%s\n' "$injected" >>"$inj_prefix/etc/letsencrypt/cli.ini"
        if run_contract "$script" "$inj_prefix" >/dev/null 2>&1; then
            fail "$script_name must refuse a package cli.ini carrying: ${injected%% *}"
        fi
    done

    # An allowed key with a value outside its syntax is refused, which is what
    # stops smuggling through a key that is itself on the list.
    for bad_value in 'preconfigured-renewal = True; pre-hook = /tmp/evil.sh' \
        'max-log-backups = 0 /tmp/evil.sh' \
        'preconfigured-renewal = /tmp/evil.sh'
    do
        val_prefix="$(new_prefix val "$script_name-${RANDOM}")"
        mkdir -p "$val_prefix/etc/letsencrypt"
        printf '%s\n' "$bad_value" >"$val_prefix/etc/letsencrypt/cli.ini"
        if run_contract "$script" "$val_prefix" >/dev/null 2>&1; then
            fail "$script_name must refuse an out-of-syntax value: $bad_value"
        fi
    done

    # --- a symlink at the global path is refused ----------------------------
    link_prefix="$(new_prefix link "$script_name")"
    mkdir -p "$link_prefix/etc/letsencrypt"
    ln -s "$work_directory/no-such-cli.ini" "$link_prefix/etc/letsencrypt/cli.ini"
    if run_contract "$script" "$link_prefix" >/dev/null 2>&1; then
        fail "$script_name must refuse a symlink at the global configuration path."
    fi

    # --- the per-user path is forbidden outright ----------------------------
    for user_shape in file dangling; do
        user_prefix="$(new_prefix user "$script_name-$user_shape")"
        write_package_cli_ini "$user_prefix"
        mkdir -p "$user_prefix/root/.config/letsencrypt"
        if [[ "$user_shape" == file ]]; then
            printf 'preconfigured-renewal = True\n' >"$user_prefix/root/.config/letsencrypt/cli.ini"
        else
            ln -s "$work_directory/no-such-user-cli.ini" "$user_prefix/root/.config/letsencrypt/cli.ini"
        fi
        if run_contract "$script" "$user_prefix" >/dev/null 2>&1; then
            fail "$script_name must refuse a per-user cli.ini ($user_shape)."
        fi
    done

    # --- the caller's environment cannot move the checked paths -------------
    for hostile_env in \
        "XDG_CONFIG_HOME=$hostile_xdg" \
        "XDG_CONFIG_HOME=" \
        "XDG_CONFIG_HOME=relative-path" \
        "HOME=$hostile_home" \
        "HOME="
    do
        run_contract "$script" "$pkg_prefix" "$hostile_env" >/dev/null ||
            fail "$script_name contract must not depend on the caller's ${hostile_env%%=*}."
    done

    # --- end to end, through the real run_certbot ---------------------------
    # A refused configuration must stop the run before certbot executes.
    rm -f "$certbot_marker"
    bad_prefix="$(new_prefix bad "$script_name")"
    write_package_cli_ini "$bad_prefix"
    printf 'deploy-hook = /tmp/evil.sh\n' >>"$bad_prefix/etc/letsencrypt/cli.ini"
    if run_contract_then_certbot "$script" "$bad_prefix" >/dev/null 2>&1; then
        fail "$script_name must not reach certbot while the global configuration is out of contract."
    fi
    [[ ! -e "$certbot_marker" ]] ||
        fail "$script_name invoked certbot despite an out-of-contract Certbot configuration."

    # Positive control: the package default does reach certbot, which is what
    # keeps the assertion above from passing vacuously. The fake records the
    # environment it was handed, so the pinning is observed.
    rm -f "$certbot_marker"
    run_contract_then_certbot "$script" "$pkg_prefix" \
        "XDG_CONFIG_HOME=$hostile_xdg" "HOME=$hostile_home" >/dev/null ||
        fail "$script_name must reach certbot on a host carrying the package default cli.ini."
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

# --- 14. the contract runs after the package install and before certbot -----
# On a fresh host certbot is not installed yet, so /etc/letsencrypt/cli.ini does
# not exist. A check placed before `dnf install` would pass, the install would
# then write the file, and certbot would read a configuration nothing had
# looked at. The gate has to sit between the two.
acme_main="$(main_body "$acme_contents")"
renew_main="$(main_body "$renew_contents")"

line_of() {
    grep -n "$2" <<<"$1" | head -n 1 | cut -d: -f1 || true
}

acme_install="$(line_of "$acme_main" '^        dnf install -y certbot')"
acme_guard="$(line_of "$acme_main" '^    verify_global_certbot_config_contract$')"
acme_certbot="$(line_of "$acme_main" '^    run_certbot certbot')"
[[ -n "$acme_install" ]] || fail "Unable to locate the certbot package install in configure-acme.sh main()."
[[ -n "$acme_guard" ]] || fail "configure-acme.sh must call verify_global_certbot_config_contract in main()."
[[ -n "$acme_certbot" ]] || fail "Unable to locate the certbot invocation in configure-acme.sh main()."
(( acme_install < acme_guard )) ||
    fail "configure-acme.sh must verify the global Certbot configuration after installing the package."
(( acme_guard < acme_certbot )) ||
    fail "configure-acme.sh must verify the global Certbot configuration before invoking certbot."

renew_guard="$(line_of "$renew_main" '^    verify_global_certbot_config_contract$')"
renew_certbot="$(line_of "$renew_main" '^    run_certbot certbot')"
[[ -n "$renew_guard" ]] || fail "renew-origin-cert.sh must call verify_global_certbot_config_contract in main()."
[[ -n "$renew_certbot" ]] || fail "Unable to locate the certbot invocation in renew-origin-cert.sh main()."
(( renew_guard < renew_certbot )) ||
    fail "renew-origin-cert.sh must verify the global Certbot configuration before invoking certbot."

for script_contents in "$acme_contents" "$renew_contents"; do
    assert_absent "$script_contents" 'for candidate in "$GLOBAL_CERTBOT_CONFIG_FILE" "$(' \
        "The contract must not resolve a candidate path in a command substitution."
    assert_contains "$script_contents" 'command -v rpm >/dev/null 2>&1 ||' \
        "A missing rpm must fail the contract rather than skip the ownership check."
    assert_contains "$script_contents" "rpm -qf --queryformat" \
        "Package ownership must be queried in the form whose exit status is reliable."
    assert_contains "$script_contents" 'rpm -Vf "$file" >/dev/null 2>&1 ||' \
        "Package integrity must be verified and must fail closed."
    assert_contains "$script_contents" '-u XDG_CONFIG_HOME' \
        "certbot must be invoked with XDG_CONFIG_HOME cleared."
    assert_contains "$script_contents" 'HOME="$CERTBOT_HOME"' \
        "certbot must be invoked with HOME pinned to the constant the contract uses."
    assert_contains "$script_contents" '--no-directory-hooks' \
        "The certbot invocation must keep disabling renewal-hooks/ directories."
done

printf '[origin-tls-writeback-test] PASS\n'
