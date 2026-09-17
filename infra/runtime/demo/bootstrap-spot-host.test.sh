#!/usr/bin/env bash

# Behaviour tests for the Spot replacement bootstrap.
#
# The ordering is the contract, so it is asserted by observation: every external
# command the bootstrap depends on is faked, each fake appends a marker, and the
# resulting marker sequence is compared against the required order. A test that
# only grepped the source would pass on a script whose steps ran in the wrong
# order at run time.
#
# No AWS call, no dnf, no systemctl, no certbot, and the production
# /etc/letsencrypt is never read or written.

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly BOOTSTRAP_SCRIPT="$SCRIPT_DIRECTORY/bootstrap-spot-host.sh"
readonly CLUSTER="ec-portfolio-demo"
readonly BUCKET="ec-portfolio-demo-origin-tls-776c2eab754b36a00164763604"

work_directory=""

cleanup_tests() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-spot-bootstrap-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup_tests EXIT

fail() {
    printf '[spot-bootstrap-test] FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "$3 (expected to find: $2)"
}

assert_absent() {
    [[ "$1" != *"$2"* ]] || fail "$3 (unexpectedly found: $2)"
}

work_directory="$(mktemp -d /tmp/ec-portfolio-spot-bootstrap-test.XXXXXX)"

script_contents="$(cat "$BOOTSTRAP_SCRIPT")"
script_code="$(sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*#.*$//' <<<"$script_contents")"

# ---------------------------------------------------------------------------
# Static contract: paths that must not exist in this script at all.
# ---------------------------------------------------------------------------

# Taking production traffic is a separate, deliberate step. A bootstrap that
# could move the Elastic IP would promote a host the moment it finished, before
# anyone decided it should serve.
for forbidden in "AssociateAddress" "associate-address"; do
    assert_absent "$script_code" "$forbidden" \
        "The bootstrap must never associate the Elastic IP: $forbidden"
done

# Issuing a certificate on a replacement is the failure Phase 6B exists to
# prevent: every replacement would burn a duplicate-certificate rate limit.
for forbidden in "certonly" "--dry-run"; do
    assert_absent "$script_code" "$forbidden" \
        "The bootstrap must never issue or trial a certificate: $forbidden"
done

# Downloading its own runtime would mean deciding at run time what root runs.
for forbidden in "githubusercontent" "github.com" "curl -O" "wget"; do
    assert_absent "$script_code" "$forbidden" \
        "The bootstrap must not fetch runtime artifacts: $forbidden"
done

assert_contains "$script_code" "does not download artifacts" \
    "The bundle resolution must say that nothing is downloaded."

# ---------------------------------------------------------------------------
# Behavioural harness
# ---------------------------------------------------------------------------

fake_bin="$work_directory/bin"
mkdir -p "$fake_bin"
marker_file="$work_directory/markers"
state_directory="$work_directory/state"
mkdir -p "$state_directory"

# Each fake records what it was asked and consults a per-case failure switch,
# so one harness can replay every failure mode.
make_fake() {
    local name="$1" body="$2"
    cat >"$fake_bin/$name" <<FAKE
#!/usr/bin/env bash
$body
FAKE
    chmod 755 "$fake_bin/$name"
}

make_fake systemctl '
case "$*" in
    *"disable --now ecs"*)  printf "ecs-stop\n"  >>"$MARKER_FILE" ;;
    *"enable --now ecs"*)
        [[ -e "$STATE_DIR/fail-ecs-start" ]] && exit 1
        printf "ecs-start\n" >>"$MARKER_FILE" ;;
    *"enable --now ec-portfolio-certbot-renew.timer"*) printf "renew-install\n" >>"$MARKER_FILE" ;;
esac
exit 0'

make_fake dnf '
if [[ -e "$STATE_DIR/fail-certbot-install" ]]; then exit 1; fi
printf "certbot-install\n" >>"$MARKER_FILE"
exit 0'

make_fake certbot 'printf "certbot-invoked\n" >>"$MARKER_FILE"; exit 0'

make_fake sha256sum '
if [[ "$1" == "--check" ]]; then
    [[ -e "$STATE_DIR/fail-bundle" ]] && exit 1
    printf "bundle-verify\n" >>"$MARKER_FILE"
    exit 0
fi
printf "0000000000000000000000000000000000000000000000000000000000000000  %s\n" "${!#}"'

make_fake curl '
for arg in "$@"; do
    case "$arg" in
        *51678*)
            [[ -e "$STATE_DIR/fail-registration" ]] && exit 1
            printf "registration\n" >>"$MARKER_FILE"
            printf "{\"Cluster\":\"c\"}\n"; exit 0 ;;
        *8080*)
            [[ -e "$STATE_DIR/fail-readiness" ]] && exit 1
            printf "api-ready\n" >>"$MARKER_FILE"
            printf "{\"status\":\"UP\"}\n"; exit 0 ;;
    esac
done
exit 0'

make_fake timeout '
while [[ "$1" == --* ]]; do shift; done
shift
exec "$@"'

# Portable stand-in: bash 3.2 has no negative array subscripts, so the operands
# are collected by stripping the flags rather than indexed from the end.
make_fake install '
mode=copy
files=""
while [ $# -gt 0 ]; do
    case "$1" in
        -d) mode=dir; shift ;;
        -o|-g|-m) shift 2 ;;
        *) files="$files $1"; shift ;;
    esac
done
set -- $files
if [ "$mode" = dir ]; then mkdir -p "$@"; exit 0; fi
src=""; target=""
for f in "$@"; do src="$target"; target="$f"; done
[ -n "$target" ] || exit 0
mkdir -p "$(dirname "$target")"
if [ -n "$src" ] && [ -e "$src" ]; then cp "$src" "$target"; else : >"$target"; fi
chmod 755 "$target" 2>/dev/null || true
case "$target" in
    */ecs.config) printf "ecs-config\n" >>"$MARKER_FILE" ;;
esac
exit 0'

for tool in bash env grep mktemp rm sed awk cat stat id dirname sleep cp mkdir printf sudo; do
    tool_path="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$tool_path" ]] && ln -sf "$tool_path" "$fake_bin/$tool"
done

# Builds a bundle directory holding the script under test and stand-ins for the
# artifacts it resolves. The stand-ins record their own markers.
build_bundle() {
    local bundle="$1"
    mkdir -p "$bundle"
    cp "$BOOTSTRAP_SCRIPT" "$bundle/bootstrap-spot-host.sh"
    chmod 755 "$bundle/bootstrap-spot-host.sh"

    cat >"$bundle/sync-origin-tls.sh" <<'SYNC'
#!/usr/bin/env bash
[[ "$1" == "restore" ]] || exit 0
[[ -e "$STATE_DIR/fail-restore" ]] && exit 1
printf 'restore\n' >>"$MARKER_FILE"
printf 'restore-bucket=%s\n' "${ORIGIN_TLS_BUCKET-}" >>"$MARKER_FILE"
printf 'restore-static-creds=%s\n' "${AWS_ACCESS_KEY_ID-<unset>}" >>"$MARKER_FILE"
exit 0
SYNC

    cat >"$bundle/renew-origin-cert.sh" <<'RENEW'
#!/usr/bin/env bash
verify_global_certbot_config_contract() {
    [[ -e "$STATE_DIR/fail-cli-contract" ]] && return 1
    printf 'cli-contract\n' >>"$MARKER_FILE"
    return 0
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then :; fi
RENEW

    cat >"$bundle/configure-origin.sh" <<'ORIGINCFG'
#!/usr/bin/env bash
printf 'nginx-configure\n' >>"$MARKER_FILE"
printf 'smoke-mode=%s\n' "${ORIGIN_SMOKE_MODE-<unset>}" >>"$MARKER_FILE"
[[ -e "$STATE_DIR/fail-smoke" ]] && exit 1
printf 'ecs-smoke\n' >>"$MARKER_FILE"
exit 0
ORIGINCFG

    printf '#!/usr/bin/env bash\nexit 0\n' >"$bundle/origin-smoke-check-ecs.sh"
    : >"$bundle/ec-portfolio-certbot-renew.service"
    : >"$bundle/ec-portfolio-certbot-renew.timer"
    : >"$bundle/bundle.sha256"
    chmod 755 "$bundle/sync-origin-tls.sh" "$bundle/renew-origin-cert.sh" \
        "$bundle/configure-origin.sh" "$bundle/origin-smoke-check-ecs.sh"
}

# Runs the real ordering against a sandbox prefix. main() still refuses to run
# unprivileged, which is asserted statically below; the suite drives
# run_bootstrap_steps so the sequence itself is observed.
#
# $1 case name, rest: failure switch file names
run_bootstrap() {
    local case_name="$1"
    shift
    local root="$work_directory/$case_name"
    rm -rf "$root"; mkdir -p "$root/etc" "$root/run" "$root/usr/local/sbin" "$root/etc/systemd/system"
    local bundle="$root/bundle"
    build_bundle "$bundle"

    current_markers="$root/markers"
    : >"$current_markers"
    rm -f "$state_directory"/fail-*
    local switch
    for switch in "$@"; do : >"$state_directory/$switch"; done

    env PATH="$fake_bin:$PATH" \
        MARKER_FILE="$current_markers" STATE_DIR="$state_directory" \
        SPOT_BOOTSTRAP_PREFIX="$root" \
        SPOT_BUNDLE_SHA256_FILE="$bundle/bundle.sha256" \
        ECS_CLUSTER_NAME="$CLUSTER" ORIGIN_TLS_BUCKET="$BUCKET" \
        AWS_ACCESS_KEY_ID="leaked-static-key" \
        SPOT_REGISTRATION_ATTEMPTS=2 SPOT_REGISTRATION_INTERVAL_SECONDS=0 \
        SPOT_READINESS_ATTEMPTS=2 SPOT_READINESS_INTERVAL_SECONDS=0 \
        bash -c 'source "$1"; validate_inputs; run_bootstrap_steps' \
        _ "$bundle/bootstrap-spot-host.sh" >"$root/output" 2>&1 && last_status=0 || last_status=$?
    last_root="$root"
    return 0
}

markers() {
    tr '\n' ' ' <"$current_markers"
}

marker_present() {
    grep -qxF "$1" "$current_markers" 2>/dev/null
}

serving_ready_exists() {
    [[ -e "$last_root/run/ec-portfolio-demo/spot-serving-ready" ]]
}

current_markers=""
last_status=0
last_root=""

# --- 1. the success path runs every step in the required order --------------
run_bootstrap success
(( last_status == 0 )) || fail "The success path must exit 0. Output: $(cat "$last_root/output")"

expected_order=(
    ecs-stop bundle-verify restore certbot-install cli-contract renew-install
    ecs-config ecs-start registration api-ready nginx-configure ecs-smoke
)
observed="$(grep -xE 'ecs-stop|bundle-verify|restore|certbot-install|cli-contract|renew-install|ecs-config|ecs-start|registration|api-ready|nginx-configure|ecs-smoke' "$current_markers" | tr '\n' ' ')"
expected="$(printf '%s ' "${expected_order[@]}")"
[[ "$observed" == "$expected" ]] ||
    fail "Marker order mismatch.
  expected: $expected
  observed: $observed"

# serving-ready is the last action, and only on success.
serving_ready_exists || fail "The success path must record the serving-ready marker."

# --- 2. the restore runs with the instance role only ------------------------
assert_contains "$(cat "$current_markers")" "restore-static-creds=<unset>" \
    "The restore must not inherit a static AWS credential."
assert_contains "$(cat "$current_markers")" "restore-bucket=$BUCKET" \
    "The restore must be given the configured bucket."

# --- 3. the origin is configured in ECS smoke mode --------------------------
assert_contains "$(cat "$current_markers")" "smoke-mode=ecs" \
    "configure-origin.sh must be invoked with ORIGIN_SMOKE_MODE=ecs."

# --- 4. certbot itself is never invoked -------------------------------------
assert_absent "$(cat "$current_markers")" "certbot-invoked" \
    "The bootstrap must never execute certbot."

# --- 5. every gate leaves the host out of the cluster and not ready ---------
# The agent is held back first, so a failure at any gate leaves a host that
# never registers and never claims to be serving.
for case_spec in \
    "bundle:fail-bundle:bundle-verify" \
    "restore:fail-restore:restore" \
    "certbot:fail-certbot-install:certbot-install" \
    "cli:fail-cli-contract:cli-contract" \
    "registration:fail-registration:registration" \
    "readiness:fail-readiness:api-ready" \
    "smoke:fail-smoke:ecs-smoke"
do
    name="${case_spec%%:*}"
    rest="${case_spec#*:}"
    switch="${rest%%:*}"
    absent_marker="${rest#*:}"

    run_bootstrap "fail-$name" "$switch"
    (( last_status != 0 )) || fail "The $name gate must fail the bootstrap."
    if serving_ready_exists; then fail "A failed $name gate must not record serving-ready."; fi
    if marker_present "$absent_marker"; then fail "A failed $name gate must not report $absent_marker."; fi
    marker_present ecs-stop || fail "The ECS agent must be held back before the $name gate."
done

# --- 6. a failure before the config is written leaves the agent unstarted ---
run_bootstrap ordering-restore fail-restore
if marker_present ecs-config; then fail "A failed restore must not write the ECS agent configuration."; fi
if marker_present ecs-start; then fail "A failed restore must not start the ECS agent."; fi

# --- 7. the agent is stopped before anything else ---------------------------
run_bootstrap ordering-success
first_marker="$(grep -m 1 -xE 'ecs-stop|bundle-verify|restore|ecs-config|ecs-start' "$current_markers")"
[[ "$first_marker" == "ecs-stop" ]] ||
    fail "The ECS agent must be disabled before any other step (first marker was: $first_marker)."

# --- 8. a host that already has certbot state is refused --------------------
run_bootstrap preexisting
mkdir -p "$last_root/etc/letsencrypt"
run_bootstrap_with_existing() {
    local root="$work_directory/preexisting2"
    rm -rf "$root"; mkdir -p "$root/etc/letsencrypt" "$root/run"
    build_bundle "$root/bundle"
    current_markers="$root/markers"; : >"$current_markers"
    rm -f "$state_directory"/fail-*
    env PATH="$fake_bin:$PATH" MARKER_FILE="$current_markers" STATE_DIR="$state_directory" \
        SPOT_BOOTSTRAP_PREFIX="$root" SPOT_BUNDLE_SHA256_FILE="$root/bundle/bundle.sha256" \
        ECS_CLUSTER_NAME="$CLUSTER" ORIGIN_TLS_BUCKET="$BUCKET" \
        bash -c 'source "$1"; validate_inputs; run_bootstrap_steps' \
        _ "$root/bundle/bootstrap-spot-host.sh" >"$root/output" 2>&1 && last_status=0 || last_status=$?
    last_root="$root"
    return 0
}
run_bootstrap_with_existing
(( last_status != 0 )) || fail "A host that already carries certbot state must be refused."
if marker_present restore; then fail "A pre-existing certbot tree must not be restored over."; fi

# --- 9. required inputs are validated ---------------------------------------
for bad_env in "ECS_CLUSTER_NAME=" "ORIGIN_TLS_BUCKET=" "ECS_CLUSTER_NAME=not valid" "ORIGIN_TLS_BUCKET=NotAValidBucket"; do
    if env PATH="$fake_bin:$PATH" ECS_CLUSTER_NAME="$CLUSTER" ORIGIN_TLS_BUCKET="$BUCKET" "$bad_env" \
        bash -c 'source "$1"; validate_inputs' _ "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1; then
        fail "validate_inputs must reject: $bad_env"
    fi
done

# --- 10. the entry point still refuses to run unprivileged ------------------
assert_contains "$script_code" '(( EUID == 0 )) || fail' \
    "validate_platform must still require root."
assert_contains "$script_code" 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' \
    "Sourcing the script must not run a bootstrap."

# --- 11. the sandbox prefix cannot be used against a real host --------------
# The suite needs the seam, a caller of the executable must not have it. Without
# this, one environment variable would redirect /etc/letsencrypt, /etc/ecs and
# /run, and a host could be told to restore TLS state somewhere it did not own
# and then report itself ready.
direct_output="$(env PATH="$fake_bin:$PATH" SPOT_BOOTSTRAP_PREFIX="$work_directory/hijack" \
    ECS_CLUSTER_NAME="$CLUSTER" ORIGIN_TLS_BUCKET="$BUCKET" \
    bash "$BOOTSTRAP_SCRIPT" 2>&1)" && direct_status=0 || direct_status=$?
(( direct_status != 0 )) ||
    fail "Executing the script with SPOT_BOOTSTRAP_PREFIX set must fail."
assert_contains "$direct_output" "test seam" \
    "The refusal must say the prefix is a test seam."
[[ -e "$work_directory/hijack" ]] &&
    fail "A refused run must not create anything under the requested prefix."

# The same variable is accepted when the file is sourced, which is how every
# case above ran. An empty prefix on a direct execution is still allowed: that
# is production.
empty_output="$(env PATH="$fake_bin:$PATH" SPOT_BOOTSTRAP_PREFIX="" \
    ECS_CLUSTER_NAME="$CLUSTER" ORIGIN_TLS_BUCKET="$BUCKET" \
    bash "$BOOTSTRAP_SCRIPT" 2>&1 || true)"
assert_absent "$empty_output" "test seam" \
    "An empty prefix must not be treated as the test seam."

# --- 12. production defaults resolve to the real host paths -----------------
default_paths="$(env PATH="$fake_bin:$PATH" bash -c '
    source "$1"
    printf "%s\n%s\n%s\n%s\n" \
        "$LETSENCRYPT_DIRECTORY" "$ECS_CONFIG_FILE" "$SERVING_READY_MARKER" "$SYNC_TARGET"
' _ "$BOOTSTRAP_SCRIPT")"
for expected in "/etc/letsencrypt" "/etc/ecs/ecs.config" \
    "/run/ec-portfolio-demo/spot-serving-ready" "/usr/local/sbin/ec-portfolio-sync-origin-tls"; do
    assert_contains "$default_paths" "$expected" \
        "With no prefix the script must use the host path $expected."
done

# --- 11. no secret reaches the output ---------------------------------------
run_bootstrap secret-check
output_contents="$(cat "$last_root/output")"
assert_absent "$output_contents" "leaked-static-key" \
    "A static credential in the caller environment must not be echoed."
assert_absent "$output_contents" "BEGIN PRIVATE KEY" \
    "No key material may reach the output."

printf '[spot-bootstrap-test] PASS\n'
