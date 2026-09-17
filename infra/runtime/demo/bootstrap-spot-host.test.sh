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

# `enable --now` is modelled as what it actually is: two operations. The enable
# half takes effect and is recorded as durable unit state under $STATE_DIR/units
# before the start half is allowed to fail, so a test can tell the difference
# between "never touched the unit" and "left it enabled for the next boot". A
# fake that simply exited before doing anything would make the cleanup contract
# untestable.
make_fake systemctl '
units="$STATE_DIR/units"
mkdir -p "$units"
case "$*" in
    *"disable --now ecs"*)
        # Every attempt is recorded, the successful ones separately, so a test
        # can tell "the cleanup retried" from "the first call worked".
        printf "ecs-stop-attempted\n" >>"$MARKER_FILE"
        printf "x" >>"$units/ecs-disable-attempts"
        attempts="$(wc -c <"$units/ecs-disable-attempts" | tr -d " ")"
        if [[ -e "$STATE_DIR/fail-ecs-initial-disable" && "$attempts" == "1" ]]; then
            # Partial: the stop half took effect, the unit is still enabled.
            exit 1
        fi
        rm -f "$units/ecs.enabled"
        printf "ecs-stop\n" >>"$MARKER_FILE" ;;
    *"disable --now ec-portfolio-certbot-renew.timer"*)
        rm -f "$units/renew.enabled"
        printf "renew-disable\n" >>"$MARKER_FILE" ;;
    *"enable --now ec-portfolio-certbot-renew.timer"*)
        : >"$units/renew.enabled"
        printf "renew-enable-attempted\n" >>"$MARKER_FILE"
        [[ -e "$STATE_DIR/fail-renew-enable" ]] && exit 1
        printf "renew-enable\n" >>"$MARKER_FILE" ;;
    *"enable --now ecs"*)
        : >"$units/ecs.enabled"
        printf "ecs-enable-attempted\n" >>"$MARKER_FILE"
        [[ -e "$STATE_DIR/fail-ecs-start" ]] && exit 1
        printf "ecs-start\n" >>"$MARKER_FILE" ;;
    *"daemon-reload"*) printf "renew-install\n" >>"$MARKER_FILE" ;;
esac
exit 0'

make_fake dnf '
. "$STATE_DIR/report-identity.sh"
report_identity dnf
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
            printf "{\"Cluster\":\"%s\"}\n" "$(cat "$STATE_DIR/cluster-name" 2>/dev/null || printf "ec-portfolio-demo")"
            exit 0 ;;
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
if [ "$mode" = dir ]; then
    mkdir -p "$@"
    for created in "$@"; do
        case "$created" in
            */run/ec-portfolio-demo) printf "marker-dir\n" >>"$MARKER_FILE" ;;
        esac
    done
    exit 0
fi
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

# Every helper stand-in sources this and records, from inside its own process,
# which credential-provider, endpoint and trust variables actually reached it.
# The assertions below read these lines rather than the bootstrap's output: a
# variable missing from a log says nothing about the child's environment.
# The identity policy the bootstrap must enforce, named once. Both the reporter
# the stand-ins source and the assertions below are driven from this list, so a
# variable added to the policy cannot be silently left unasserted.
IDENTITY_ENV=(
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
    AWS_PROFILE AWS_DEFAULT_PROFILE AWS_CREDENTIAL_FILE
    AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE
    AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN
    AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_CREDENTIALS_RELATIVE_URI
    AWS_EC2_METADATA_DISABLED AWS_EC2_METADATA_SERVICE_ENDPOINT
    AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE
    AWS_ENDPOINT_URL AWS_ENDPOINT_URL_S3 AWS_ENDPOINT_URL_SSM AWS_ENDPOINT_URL_ROUTE53
    AWS_CA_BUNDLE REQUESTS_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR BOTO_CONFIG
)

{
    printf 'identity_env="%s"\n\n' "${IDENTITY_ENV[*]}"
    cat <<'REPORT'
report_identity() {
    tag="$1"
    for name in $identity_env; do
        printf '%s-identity %s=%s\n' "$tag" "$name" "${!name-<unset>}" >>"$MARKER_FILE"
    done
}
REPORT
} >"$state_directory/report-identity.sh"

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
. "$STATE_DIR/report-identity.sh"
[[ "$1" == "restore" ]] || exit 0
[[ -e "$STATE_DIR/fail-restore" ]] && exit 1
printf 'restore\n' >>"$MARKER_FILE"
printf 'restore-bucket=%s\n' "${ORIGIN_TLS_BUCKET-}" >>"$MARKER_FILE"
printf 'restore-static-creds=%s\n' "${AWS_ACCESS_KEY_ID-<unset>}" >>"$MARKER_FILE"
printf 'restore-profile=%s\n' "${AWS_PROFILE-<unset>}" >>"$MARKER_FILE"
printf 'restore-tls-seam=%s\n' "${ORIGIN_TLS_PARENT_DIRECTORY-<unset>}" >>"$MARKER_FILE"
printf 'restore-region=%s\n' "${AWS_REGION-<unset>}" >>"$MARKER_FILE"
report_identity restore
exit 0
SYNC

    cat >"$bundle/renew-origin-cert.sh" <<'RENEW'
#!/usr/bin/env bash
. "$STATE_DIR/report-identity.sh"
verify_global_certbot_config_contract() {
    [[ -e "$STATE_DIR/fail-cli-contract" ]] && return 1
    printf 'cli-contract\n' >>"$MARKER_FILE"
    printf 'cli-static-creds=%s\n' "${AWS_ACCESS_KEY_ID-<unset>}" >>"$MARKER_FILE"
    printf 'cli-certbot-seam=%s\n' "${CERTBOT_CONFIG_PREFIX-<unset>}" >>"$MARKER_FILE"
    report_identity cli
    return 0
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then :; fi
RENEW

    cat >"$bundle/configure-origin.sh" <<'ORIGINCFG'
#!/usr/bin/env bash
. "$STATE_DIR/report-identity.sh"
printf 'nginx-configure\n' >>"$MARKER_FILE"
printf 'smoke-mode=%s\n' "${ORIGIN_SMOKE_MODE-<unset>}" >>"$MARKER_FILE"
printf 'origin-static-creds=%s\n' "${AWS_ACCESS_KEY_ID-<unset>}" >>"$MARKER_FILE"
printf 'origin-profile=%s\n' "${AWS_PROFILE-<unset>}" >>"$MARKER_FILE"
printf 'origin-region=%s\n' "${AWS_REGION-<unset>}" >>"$MARKER_FILE"
printf 'origin-tls-seam=%s\n' "${ORIGIN_TLS_PARENT_DIRECTORY-<unset>}" >>"$MARKER_FILE"
report_identity origin
[[ -e "$STATE_DIR/fail-smoke" ]] && exit 1
printf 'ecs-smoke\n' >>"$MARKER_FILE"
exit 0
ORIGINCFG

    printf '#!/usr/bin/env bash\nexit 0\n' >"$bundle/origin-smoke-check-ecs.sh"
    : >"$bundle/ec-portfolio-certbot-renew.service"
    : >"$bundle/ec-portfolio-certbot-renew.timer"

    # A manifest naming every required artifact exactly once, by relative path.
    : >"$bundle/bundle.sha256"
    local artifact
    for artifact in sync-origin-tls.sh renew-origin-cert.sh configure-origin.sh \
        origin-smoke-check-ecs.sh ec-portfolio-certbot-renew.service \
        ec-portfolio-certbot-renew.timer; do
        printf '%064d  %s\n' 0 "$artifact" >>"$bundle/bundle.sha256"
    done
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
    rm -rf "$state_directory/units"
    # The ECS-optimized AMI ships the agent enabled, so every case starts from
    # a host whose agent would come back on the next boot unless disabled.
    mkdir -p "$state_directory/units"
    : >"$state_directory/units/ecs.enabled"
    local switch
    for switch in "$@"; do : >"$state_directory/$switch"; done

    env PATH="$fake_bin:$PATH" \
        MARKER_FILE="$current_markers" STATE_DIR="$state_directory" \
        SPOT_BOOTSTRAP_PREFIX="$root" \
        ECS_CLUSTER_NAME="$CLUSTER" ORIGIN_TLS_BUCKET="$BUCKET" \
        AWS_ACCESS_KEY_ID="leaked-static-key" AWS_PROFILE="leaked-profile" \
        AWS_SHARED_CREDENTIALS_FILE="/tmp/evil-credentials" \
        AWS_SECRET_ACCESS_KEY="leaked-secret" AWS_SESSION_TOKEN="leaked-token" \
        AWS_SECURITY_TOKEN="leaked-token" AWS_DEFAULT_PROFILE="leaked-profile" \
        AWS_CREDENTIAL_FILE="/tmp/evil-credentials" AWS_CONFIG_FILE="/tmp/evil-config" \
        AWS_WEB_IDENTITY_TOKEN_FILE="/tmp/token" \
        AWS_ROLE_ARN="arn:aws:iam::123456789012:role/evil" \
        AWS_CONTAINER_CREDENTIALS_FULL_URI="http://127.0.0.1:9999/creds" \
        AWS_CONTAINER_CREDENTIALS_RELATIVE_URI="/creds" \
        AWS_EC2_METADATA_DISABLED="true" \
        AWS_EC2_METADATA_SERVICE_ENDPOINT="http://127.0.0.1:9999" \
        AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE="IPv6" \
        AWS_ENDPOINT_URL="https://example.invalid" \
        AWS_ENDPOINT_URL_S3="https://example.invalid" \
        AWS_ENDPOINT_URL_SSM="https://example.invalid" \
        AWS_ENDPOINT_URL_ROUTE53="https://example.invalid" \
        AWS_CA_BUNDLE="/tmp/evil-ca.pem" REQUESTS_CA_BUNDLE="/tmp/evil-ca.pem" \
        SSL_CERT_FILE="/tmp/evil-ca.pem" SSL_CERT_DIR="/tmp/evil-ca" \
        BOTO_CONFIG="/tmp/evil-boto" \
        ORIGIN_TLS_PARENT_DIRECTORY="/tmp/evil" CERTBOT_CONFIG_PREFIX="/tmp/evil" \
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

# The fake systemctl keeps enablement as durable state, so "would this unit come
# back on the next boot?" is a question the suite can actually ask.
unit_left_enabled() {
    [[ -e "$state_directory/units/$1.enabled" ]]
}

marker_count() {
    grep -cxF "$1" "$current_markers" 2>/dev/null || printf '0\n'
}

# Asserts that one AWS child saw none of the identity, endpoint or trust
# variables the caller supplied, reading the child's own report rather than the
# bootstrap's output.
assert_identity_clean() {
    local tag="$1" contents name
    contents="$(cat "$current_markers")"
    for name in "${IDENTITY_ENV[@]}"; do
        assert_contains "$contents" "$tag-identity $name=<unset>" \
            "The $tag child must not inherit $name."
    done
}

current_markers=""
last_status=0
last_root=""

# --- 1. the success path runs every step in the required order --------------
run_bootstrap success
(( last_status == 0 )) || fail "The success path must exit 0. Output: $(cat "$last_root/output")"

expected_order=(
    ecs-stop bundle-verify restore certbot-install cli-contract renew-install
    ecs-config ecs-start registration api-ready nginx-configure ecs-smoke renew-enable
)
observed="$(grep -xE 'ecs-stop|bundle-verify|restore|certbot-install|cli-contract|renew-install|ecs-config|ecs-start|registration|api-ready|nginx-configure|ecs-smoke|renew-enable' "$current_markers" | tr '\n' ' ')"
expected="$(printf '%s ' "${expected_order[@]}")"
[[ "$observed" == "$expected" ]] ||
    fail "Marker order mismatch.
  expected: $expected
  observed: $observed"

# serving-ready is the last action, and only on success.
serving_ready_exists || fail "The success path must record the serving-ready marker."

# --- 2. the restore runs with the instance role only ------------------------
for observation in \
    "restore-static-creds=<unset>" "restore-profile=<unset>" \
    "cli-static-creds=<unset>" "origin-static-creds=<unset>" "origin-profile=<unset>"
do
    assert_contains "$(cat "$current_markers")" "$observation" \
        "Every AWS child must run with the instance role only ($observation)."
done

# The seams belonging to the helpers must not survive into the child either: a
# caller who could set them would choose where TLS state is restored and which
# certbot configuration is validated.
for observation in \
    "restore-tls-seam=<unset>" "cli-certbot-seam=<unset>" "origin-tls-seam=<unset>"
do
    assert_contains "$(cat "$current_markers")" "$observation" \
        "Helper test seams must not be inherited by a production child ($observation)."
done

# Static keys are only the first layer. The credential chain, the endpoint the
# call goes to, and the trust store it validates against are each an inherited
# way to make this host act as somebody else, or to answer it as somebody else.
# Every one of them is read back from inside the child process.
for tag in restore cli origin; do
    assert_identity_clean "$tag"
done

# The positive control for the three assertions above. dnf is the one child the
# bootstrap runs without run_aws_child, so it still sees the caller environment.
# If the harness ever stopped injecting the hostile values, this fails and the
# <unset> assertions are exposed as vacuous.
dnf_identity="$(grep -c '^dnf-identity .*=<unset>$' "$current_markers" || true)"
(( dnf_identity == 0 )) ||
    fail "The harness is not injecting hostile identity variables; the <unset> assertions prove nothing."
for hostile in \
    "dnf-identity AWS_ACCESS_KEY_ID=leaked-static-key" \
    "dnf-identity AWS_WEB_IDENTITY_TOKEN_FILE=/tmp/token" \
    "dnf-identity AWS_ROLE_ARN=arn:aws:iam::123456789012:role/evil" \
    "dnf-identity AWS_CONTAINER_CREDENTIALS_FULL_URI=http://127.0.0.1:9999/creds" \
    "dnf-identity AWS_ENDPOINT_URL_SSM=https://example.invalid" \
    "dnf-identity AWS_ENDPOINT_URL_S3=https://example.invalid" \
    "dnf-identity AWS_CA_BUNDLE=/tmp/evil-ca.pem"
do
    assert_contains "$(cat "$current_markers")" "$hostile" \
        "The harness must actually inject the hostile environment ($hostile)."
done

# The Region is stated rather than discovered.
for observation in "restore-region=ap-northeast-1" "origin-region=ap-northeast-1"; do
    assert_contains "$(cat "$current_markers")" "$observation" \
        "Every AWS child must be given the Region explicitly ($observation)."
done
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
# Blocking the ECS scheduler is the first mutating action the bootstrap takes,
# ahead of even the marker directory it creates for itself. marker-dir is
# included here for exactly that reason: without an observable step before the
# bundle work, "first" could only be asserted against steps far enough down the
# sequence to prove very little.
run_bootstrap ordering-success
marker_present marker-dir ||
    fail "The marker directory step must be observable, or the ordering proves little."
first_marker="$(grep -m 1 -xE 'ecs-stop|marker-dir|bundle-verify|restore|ecs-config|ecs-start' "$current_markers")"
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
        SPOT_BOOTSTRAP_PREFIX="$root" \
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

# --- 10b. a failure after the agent started takes the host back out ---------
# Registration, readiness and the smoke gate all run with the agent already
# enabled. Without cleanup, a host that failed one of them would keep sitting in
# the cluster waiting for work it cannot serve.
for late_case in "registration:fail-registration" "readiness:fail-readiness" "smoke:fail-smoke"; do
    name="${late_case%%:*}"
    switch="${late_case#*:}"

    run_bootstrap "cleanup-$name" "$switch"
    (( last_status != 0 )) || fail "The $name gate must fail the bootstrap."
    marker_present ecs-start ||
        fail "The $name case must have started the agent, or it tests nothing."

    # ecs-stop appears twice: once at the start, once from the cleanup.
    stop_count="$(grep -cxF ecs-stop "$current_markers" || true)"
    (( stop_count >= 2 )) ||
        fail "A failed $name gate must take the host back out of the cluster (ecs-stop seen $stop_count times)."
    if serving_ready_exists; then fail "A failed $name gate must not record serving-ready."; fi
done

# --- 10b-i. a partial `enable --now ecs` is still cleaned up ----------------
# systemctl enable --now is two operations. The enable half can take effect and
# the start half still fail, which exits non-zero while leaving the unit enabled
# for the next boot. A flag raised only after success would skip the cleanup and
# the host would rejoin the cluster after a reboot, unbootstrapped.
run_bootstrap ecs-partial-start fail-ecs-start
(( last_status != 0 )) || fail "A failed ECS agent start must fail the bootstrap."
marker_present ecs-enable-attempted ||
    fail "The partial-start case must have reached the enable, or it tests nothing."
if marker_present ecs-start; then fail "The ECS start must be reported as failed."; fi
(( $(marker_count ecs-stop) >= 2 )) ||
    fail "A partial ECS enable must be undone (ecs-stop seen $(marker_count ecs-stop) times)."
if unit_left_enabled ecs; then
    fail "A failed bootstrap must not leave the ECS agent enabled for the next boot."
fi
if serving_ready_exists; then fail "A failed ECS start must not record serving-ready."; fi

# --- 10b-ii. a partial *initial* disable is retried by the cleanup ----------
# The host arrives with the agent enabled, so the very first step is already a
# mutating one, and `disable --now` is two operations like its counterpart. If
# the flag were raised only at start_ecs_agent, a bootstrap that failed here
# would exit leaving the agent enabled and the cleanup would decline to touch
# it -- the host would rejoin on the next boot having bootstrapped nothing.
run_bootstrap ecs-initial-disable fail-ecs-initial-disable
(( last_status != 0 )) || fail "A failed initial ECS disable must fail the bootstrap."
(( $(marker_count ecs-stop-attempted) == 2 )) ||
    fail "The cleanup must retry the disable after the first attempt failed (attempts: $(marker_count ecs-stop-attempted))."
(( $(marker_count ecs-stop) == 1 )) ||
    fail "Exactly one disable should have succeeded, the cleanup retry (succeeded: $(marker_count ecs-stop))."
if unit_left_enabled ecs; then
    fail "A failed initial disable must not leave the ECS agent enabled for the next boot."
fi
if marker_present bundle-verify; then fail "A failed initial disable must stop the bootstrap."; fi
if serving_ready_exists; then fail "A failed initial disable must not record serving-ready."; fi

# --- 10c. the renewal timer is enabled last, and gates serving-ready --------
run_bootstrap renew-timer fail-renew-enable
(( last_status != 0 )) || fail "A renewal timer that cannot be enabled must fail the bootstrap."
if serving_ready_exists; then fail "A failed renewal timer must not record serving-ready."; fi
marker_present ecs-smoke || fail "The renewal timer must be enabled after the smoke gate."

# --- 10c-i. a partial timer enable is cleaned up too ------------------------
# Same hazard, different unit, and a worse outcome: a failed replacement that
# came back from a reboot renewing certificates would write them to the shared
# bucket from a host that never proved it could serve.
marker_present renew-enable-attempted ||
    fail "The partial timer case must have reached the enable, or it tests nothing."
if marker_present renew-enable; then fail "The timer enable must be reported as failed."; fi
marker_present renew-disable ||
    fail "A partially enabled renewal timer must be disabled by the cleanup."
if unit_left_enabled renew; then
    fail "A failed bootstrap must not leave the renewal timer enabled for the next boot."
fi
(( $(marker_count ecs-stop) >= 2 )) ||
    fail "A failed timer enable must also take the host back out of the cluster."
if unit_left_enabled ecs; then
    fail "A failed timer enable must not leave the ECS agent enabled for the next boot."
fi

# --- 10c-ii. the cleanup does not fire on the success path ------------------
# The positive control for both cases above: a host that finished keeps its
# agent and its renewal timer. Without this, a cleanup that ran unconditionally
# would satisfy every assertion above and break production.
run_bootstrap cleanup-not-on-success
(( last_status == 0 )) || fail "The success path must exit 0. Output: $(cat "$last_root/output")"
serving_ready_exists || fail "The success path must record the serving-ready marker."
unit_left_enabled ecs || fail "A finished host must keep the ECS agent enabled."
unit_left_enabled renew || fail "A finished host must keep the renewal timer enabled."
if marker_present renew-disable; then fail "The success path must not disable the renewal timer."; fi
(( $(marker_count ecs-stop) == 1 )) ||
    fail "The success path must disable the agent exactly once, at the start."
(( $(marker_count ecs-stop-attempted) == 1 )) ||
    fail "The success path must not retry the disable."

# --- 10d. the agent must register with the expected cluster -----------------
for wrong_cluster in default other-cluster; do
    printf '%s' "$wrong_cluster" >"$state_directory/cluster-name"
    run_bootstrap "cluster-$wrong_cluster"
    (( last_status != 0 )) ||
        fail "Registration with '$wrong_cluster' must fail rather than be accepted."
    if serving_ready_exists; then fail "A wrong-cluster registration must not record serving-ready."; fi
done
rm -f "$state_directory/cluster-name"

# --- 10e. the bundle manifest must cover every required artifact ------------
# sha256sum --check only validates what a manifest lists, so a manifest is
# refused before it is used unless it names each artifact exactly once by a
# relative path inside the bundle.
manifest_case() {
    local name="$1" manifest_body="$2"
    local root="$work_directory/manifest-$name"
    rm -rf "$root"; mkdir -p "$root/etc" "$root/run"
    build_bundle "$root/bundle"
    printf '%s' "$manifest_body" >"$root/bundle/bundle.sha256"
    current_markers="$root/markers"; : >"$current_markers"
    rm -f "$state_directory"/fail-*
    env PATH="$fake_bin:$PATH" MARKER_FILE="$current_markers" STATE_DIR="$state_directory" \
        SPOT_BOOTSTRAP_PREFIX="$root" ECS_CLUSTER_NAME="$CLUSTER" ORIGIN_TLS_BUCKET="$BUCKET" \
        SPOT_REGISTRATION_ATTEMPTS=1 SPOT_REGISTRATION_INTERVAL_SECONDS=0 \
        SPOT_READINESS_ATTEMPTS=1 SPOT_READINESS_INTERVAL_SECONDS=0 \
        bash -c 'source "$1"; validate_inputs; run_bootstrap_steps' \
        _ "$root/bundle/bootstrap-spot-host.sh" >"$root/output" 2>&1 && return 0 || return 1
}

full_manifest=''
for artifact in sync-origin-tls.sh renew-origin-cert.sh configure-origin.sh \
    origin-smoke-check-ecs.sh ec-portfolio-certbot-renew.service \
    ec-portfolio-certbot-renew.timer; do
    full_manifest="$full_manifest$(printf '%064d  %s\n' 0 "$artifact")
"
done

# missing a required artifact
for missing in configure-origin.sh origin-smoke-check-ecs.sh sync-origin-tls.sh; do
    body="$(grep -vF " $missing" <<<"$full_manifest")"
    if manifest_case "missing-${missing%%.*}" "$body"; then
        fail "A manifest omitting $missing must be refused."
    fi
done

# duplicate entry
if manifest_case duplicate "$full_manifest$(printf '%064d  configure-origin.sh\n' 0)"; then
    fail "A manifest naming an artifact twice must be refused."
fi

# absolute path
if manifest_case absolute "$(printf '%064d  /etc/passwd\n' 0)$full_manifest"; then
    fail "A manifest containing an absolute path must be refused."
fi

# parent traversal
if manifest_case traversal "$(printf '%064d  ../outside.sh\n' 0)$full_manifest"; then
    fail "A manifest containing a parent traversal entry must be refused."
fi

# checksum mismatch still fails, through sha256sum itself
run_bootstrap checksum-mismatch fail-bundle
(( last_status != 0 )) || fail "A checksum mismatch must fail the bootstrap."

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
