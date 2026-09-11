#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALLER_SOURCE="$SCRIPT_DIRECTORY/install-api-convergence.sh"
readonly WRAPPER_SOURCE="$SCRIPT_DIRECTORY/deploy-api-from-ssm.sh"
readonly DEPLOY_SOURCE="$SCRIPT_DIRECTORY/deploy-api.sh"
readonly UNIT_SOURCE="$SCRIPT_DIRECTORY/ec-portfolio-api-converge.service"
readonly INSTALLER_FILE="install-api-convergence.sh"
readonly WRAPPER_FILE="deploy-api-from-ssm.sh"
readonly DEPLOY_FILE="deploy-api.sh"
readonly UNIT_FILE="ec-portfolio-api-converge.service"

work_directory=""

cleanup() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-api-convergence-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup EXIT

fail() {
    printf '[api-convergence-install-test] FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    printf '%s' "$1" | grep -Fq -- "$2" || fail "$3 (expected to find: $2)"
}

assert_absent() {
    printf '%s' "$1" | grep -Fq -- "$2" && fail "$3 (unexpectedly found: $2)"
    return 0
}

assert_file_mode() {
    local actual expected="$2" file="$1"

    actual="$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file")"
    [[ "$actual" == "$expected" ]] ||
        fail "$file must have mode $expected, found $actual."
}

write_os_release() {
    local sandbox="$1" id="$2" version_id="$3"

    mkdir -p "$sandbox/etc"
    printf 'ID=%s\nVERSION_ID=%s\n' "$id" "$version_id" >"$sandbox/etc/os-release"
}

install_command_mocks() {
    local sandbox="$1"

    mkdir -p "$sandbox/bin"

    cat >"$sandbox/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$SYSTEMCTL_CALL_LOG"
if [[ -n "${MOCK_SYSTEMCTL_FAIL_ON:-}" && "$*" == "$MOCK_SYSTEMCTL_FAIL_ON" ]]; then
    exit 1
fi
MOCK

    cat >"$sandbox/bin/timeout" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
while (($# > 0)); do
    case "$1" in
    --signal=* | --kill-after=*) shift ;;
    *s | *m) shift; break ;;
    *) break ;;
    esac
done
exec "$@"
MOCK

    chmod 755 "$sandbox/bin/systemctl" "$sandbox/bin/timeout"
}

# The production installer deliberately has fixed root-owned destinations and
# refuses non-root/non-AL2023 execution. For a behavioral test on both macOS and
# Linux CI, make a mechanically retargeted copy. Static assertions below keep
# the production root, platform, ownership and destination contracts covered.
prepare_test_bundle() {
    local sandbox="$1" bundle="$sandbox/bundle"

    mkdir -p "$bundle"
    cp "$WRAPPER_SOURCE" "$bundle/$WRAPPER_FILE"
    cp "$DEPLOY_SOURCE" "$bundle/$DEPLOY_FILE"
    cp "$UNIT_SOURCE" "$bundle/$UNIT_FILE"
    sed \
        -e "s|readonly RUNTIME_DIRECTORY=\"/opt/ec-portfolio/runtime/demo\"|readonly RUNTIME_DIRECTORY=\"$sandbox/opt/ec-portfolio/runtime/demo\"|" \
        -e "s|readonly SYSTEMD_DIRECTORY=\"/etc/systemd/system\"|readonly SYSTEMD_DIRECTORY=\"$sandbox/etc/systemd/system\"|" \
        -e "s|/etc/os-release|$sandbox/etc/os-release|g" \
        -e 's/^    (( EUID == 0 )) || fail "Root privileges are required\."$/    : # Root validation is covered by the static contract./' \
        -e 's/install -d -o root -g root/install -d/' \
        -e 's/install -o root -g root/install/' \
        "$INSTALLER_SOURCE" >"$bundle/$INSTALLER_FILE"
    chmod 755 "$bundle/$INSTALLER_FILE"
}

run_installer() {
    local sandbox="$1"

    env \
        PATH="$sandbox/bin:$PATH" \
        SYSTEMCTL_CALL_LOG="$sandbox/systemctl-calls.log" \
        bash "$sandbox/bundle/$INSTALLER_FILE"
}

work_directory="$(mktemp -d /tmp/ec-portfolio-api-convergence-test.XXXXXX)"

# --- production installer static safety contract ---------------------------
installer_contents="$(cat "$INSTALLER_SOURCE")"
assert_contains "$installer_contents" '(( EUID == 0 ))' \
    "The installer must require root."
assert_contains "$installer_contents" '"$os_id" == "amzn"' \
    "The installer must require Amazon Linux."
assert_contains "$installer_contents" '"$os_version_id" == 2023*' \
    "The installer must require Amazon Linux 2023."
assert_contains "$installer_contents" 'install -o root -g root -m 0755' \
    "Executable artifacts must be installed as root:root 0755."
assert_contains "$installer_contents" 'install -o root -g root -m 0644' \
    "The unit must be installed as root:root 0644."
assert_contains "$installer_contents" 'run_systemctl daemon-reload' \
    "The installer must reload systemd."
assert_contains "$installer_contents" 'run_systemctl enable "$UNIT_FILE"' \
    "The installer must enable the unit."
assert_contains "$installer_contents" 'run_systemctl is-enabled --quiet "$UNIT_FILE"' \
    "The installer must verify the enabled state."
for forbidden in 'enable --now' 'run_systemctl start' 'run_systemctl restart' \
    'run_systemctl reset-failed' 'start-instances' 'run-instances' 'rds start'; do
    assert_absent "$installer_contents" "$forbidden" \
        "The installer must not contain forbidden activation or AWS start behavior."
done

if (( EUID != 0 )); then
    output="$(bash "$INSTALLER_SOURCE" 2>&1)" &&
        fail "The production installer must reject a non-root caller."
    assert_contains "$output" "Root privileges are required" \
        "The non-root failure must be reported."
fi

# --- systemd unit static contract -------------------------------------------
unit_contents="$(cat "$UNIT_SOURCE")"
for required in \
    'Wants=network-online.target' \
    'After=network-online.target docker.service' \
    'Requires=docker.service' \
    'Type=oneshot' \
    'User=root' \
    'Group=root' \
    'UMask=0077' \
    'ExecStart=/opt/ec-portfolio/runtime/demo/deploy-api-from-ssm.sh' \
    'TimeoutStartSec=20min' \
    'TimeoutStartFailureMode=terminate' \
    'TimeoutStopSec=2min' \
    'KillMode=control-group' \
    'KillSignal=SIGTERM' \
    'SendSIGKILL=yes' \
    'FinalKillSignal=SIGKILL' \
    'Restart=no' \
    'PrivateTmp=true' \
    'NoNewPrivileges=true' \
    'WantedBy=multi-user.target'; do
    assert_contains "$unit_contents" "$required" "The unit contract is incomplete $required."
done
assert_absent "$unit_contents" 'SuccessExitStatus=' \
    "Signal exits 130 and 143 must remain failures."
assert_absent "$unit_contents" 'StartLimit' \
    "The unit must not configure retry through StartLimit directives."

expected_unit="$(cat <<'UNIT'
[Unit]
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
User=root
Group=root
UMask=0077
Environment=CONVERGED_READINESS_ATTEMPTS=36
Environment=CONVERGED_READINESS_INTERVAL_SECONDS=5
ExecStart=/opt/ec-portfolio/runtime/demo/deploy-api-from-ssm.sh
TimeoutStartSec=20min
TimeoutStartFailureMode=terminate
TimeoutStopSec=2min
KillMode=control-group
KillSignal=SIGTERM
SendSIGKILL=yes
FinalKillSignal=SIGKILL
Restart=no
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT
)"
[[ "$unit_contents" == "$expected_unit" ]] ||
    fail "The unit must match the reviewed boot convergence contract exactly."

expected_environment=$'Environment=CONVERGED_READINESS_ATTEMPTS=36\nEnvironment=CONVERGED_READINESS_INTERVAL_SECONDS=5'
actual_environment="$(grep '^Environment=' "$UNIT_SOURCE")"
[[ "$actual_environment" == "$expected_environment" ]] ||
    fail "Only the boot unit may set the exact 36/5 readiness environment."

wrapper_contents="$(cat "$WRAPPER_SOURCE")"
assert_contains "$wrapper_contents" 'readonly DEFAULT_CONVERGED_READINESS_ATTEMPTS=3' \
    "The wrapper readiness attempt default must remain 3."
assert_contains "$wrapper_contents" 'readonly DEFAULT_CONVERGED_READINESS_INTERVAL_SECONDS=2' \
    "The wrapper readiness interval default must remain 2 seconds."

# --- invalid platform fails before installation or systemd calls ------------
sandbox="$work_directory/invalid-platform"
prepare_test_bundle "$sandbox"
install_command_mocks "$sandbox"
write_os_release "$sandbox" ubuntu 24.04
: >"$sandbox/systemctl-calls.log"
output="$(run_installer "$sandbox" 2>&1)" &&
    fail "A non-AL2023 platform must be rejected."
assert_contains "$output" "Amazon Linux 2023 is required" \
    "The platform failure must be reported."
[[ ! -e "$sandbox/opt" ]] || fail "An invalid platform must not install runtime files."
[[ ! -s "$sandbox/systemctl-calls.log" ]] ||
    fail "An invalid platform must not invoke systemctl."

# --- a missing bundle artifact fails before installation --------------------
sandbox="$work_directory/missing-artifact"
prepare_test_bundle "$sandbox"
install_command_mocks "$sandbox"
write_os_release "$sandbox" amzn 2023
rm "$sandbox/bundle/$UNIT_FILE"
: >"$sandbox/systemctl-calls.log"
output="$(run_installer "$sandbox" 2>&1)" &&
    fail "A missing bundle artifact must be rejected."
assert_contains "$output" "The bundled artifact is missing: $UNIT_FILE" \
    "The missing artifact must be reported."
[[ ! -e "$sandbox/opt" ]] || fail "A missing artifact must not install runtime files."
[[ ! -s "$sandbox/systemctl-calls.log" ]] ||
    fail "A missing artifact must not invoke systemctl."

# --- two successful runs are idempotent and preserve call order -------------
sandbox="$work_directory/idempotent"
prepare_test_bundle "$sandbox"
install_command_mocks "$sandbox"
write_os_release "$sandbox" amzn 2023.8.20250908
mkdir -p "$sandbox/etc/systemd/system"
: >"$sandbox/systemctl-calls.log"
run_installer "$sandbox" >/dev/null
run_installer "$sandbox" >/dev/null

runtime_directory="$sandbox/opt/ec-portfolio/runtime/demo"
systemd_directory="$sandbox/etc/systemd/system"
for executable_file in "$WRAPPER_FILE" "$DEPLOY_FILE" "$INSTALLER_FILE"; do
    [[ -x "$runtime_directory/$executable_file" ]] ||
        fail "$executable_file must be installed and executable."
    cmp -s "$runtime_directory/$executable_file" "$sandbox/bundle/$executable_file" ||
        fail "$executable_file must be byte identical to the bundle source."
    assert_file_mode "$runtime_directory/$executable_file" 755
done
cmp -s "$systemd_directory/$UNIT_FILE" "$sandbox/bundle/$UNIT_FILE" ||
    fail "The installed unit must be byte identical to the bundle source."
assert_file_mode "$systemd_directory/$UNIT_FILE" 644

expected_calls=$'daemon-reload\nenable ec-portfolio-api-converge.service\nis-enabled --quiet ec-portfolio-api-converge.service\ndaemon-reload\nenable ec-portfolio-api-converge.service\nis-enabled --quiet ec-portfolio-api-converge.service'
actual_calls="$(cat "$sandbox/systemctl-calls.log")"
[[ "$actual_calls" == "$expected_calls" ]] ||
    fail "Each installer run must call daemon-reload, enable, then is-enabled in order."

printf '[api-convergence-install-test] PASS\n'
