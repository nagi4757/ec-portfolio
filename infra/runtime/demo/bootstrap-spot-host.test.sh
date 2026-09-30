#!/usr/bin/env bash

# Behaviour tests for the Spot replacement bootstrap, pre and post phase.
#
# The ordering is the contract, so it is asserted by observation: every external
# command the bootstrap depends on is faked, each fake appends a marker, and the
# resulting marker sequence is compared against the required order. A test that
# only grepped the source would pass on a script whose steps ran in the wrong
# order at run time.
#
# No AWS call, no dnf, no systemctl, no certbot, and the production
# /etc/letsencrypt is never read or written. Runs under bash 3.2 and bash 5.

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly BOOTSTRAP_SCRIPT="$SCRIPT_DIRECTORY/bootstrap-spot-host.sh"
readonly POST_UNIT_FILE="$SCRIPT_DIRECTORY/ec-portfolio-spot-post-bootstrap.service"
readonly COMPUTE_SPOT_TF="$SCRIPT_DIRECTORY/../../terraform/demo/compute_spot.tf"
readonly CLUSTER="ec-portfolio-demo"
readonly BUCKET="ec-portfolio-demo-origin-tls-776c2eab754b36a00164763604"
readonly ASG_NAME="ec-portfolio-demo-ecs-spot"
readonly HOOK_NAME="ec-portfolio-demo-ecs-spot-launching"
readonly INSTANCE="i-0123456789abcdef0"

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

# The body of one shell function, comments stripped.
function_body() {
    awk -v name="$1" '
        $0 ~ "^" name "\\(\\) \\{" { inside = 1; next }
        inside && /^}/ { exit }
        inside { print }' <<<"$script_code"
}

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

# Phase 6C-4a: the ECS agent is never started synchronously. Starting it and
# waiting from user data would wait for cloud-final, which is waiting for this
# script.
assert_absent "$script_code" "enable --now ecs" \
    "The bootstrap must never start the ECS agent synchronously."
assert_contains "$script_code" 'run_systemctl start --no-block "$POST_BOOTSTRAP_UNIT"' \
    "The post-bootstrap must be queued without blocking."

# The pre phase contains no wait for the agent or the task, and reports nothing.
pre_body="$(function_body run_pre_bootstrap_steps)"
[[ -n "$pre_body" ]] || fail "run_pre_bootstrap_steps must exist."
for forbidden in wait_for_cluster_registration wait_for_api_readiness configure_origin \
    enable_renewal_timer report_ record_serving_ready_marker; do
    assert_absent "$pre_body" "$forbidden" \
        "The pre phase runs in user data and must not call $forbidden."
done
post_body="$(function_body run_post_bootstrap_steps)"
for required in wait_for_cluster_registration wait_for_api_readiness configure_origin \
    enable_renewal_timer report_continue; do
    assert_contains "$post_body" "$required" "The post phase must call $required."
done

# The signal traps are what turn systemd's start timeout into an ABANDON.
assert_contains "$script_code" "trap 'exit 143' TERM" "SIGTERM must end the run with 143."
assert_contains "$script_code" "trap 'exit 130' INT" "SIGINT must end the run with 130."

# ---------------------------------------------------------------------------
# Static contract: the post-bootstrap unit
# ---------------------------------------------------------------------------

post_unit="$(sed -e 's/^[[:space:]]*#.*$//' "$POST_UNIT_FILE")"
for line in "Type=oneshot" "After=cloud-final.service ecs.service" "Wants=ecs.service" \
    "EnvironmentFile=/etc/ec-portfolio/spot-post-bootstrap.env" \
    "ExecStart=/opt/ec-portfolio/runtime/demo/bootstrap-spot-host.sh post"; do
    grep -qxF -- "$line" <<<"$post_unit" ||
        fail "The post-bootstrap unit must contain the line: $line"
done
# Enabled units come back on every boot; the launch lifecycle action does not.
assert_absent "$post_unit" "[Install]" \
    "The post-bootstrap unit must have no [Install] section: it runs on the first boot only."
assert_absent "$post_unit" "EnvironmentFile=-" \
    "A missing post-bootstrap environment must fail the unit."
assert_absent "$post_unit" "ExecStart=-" \
    "A failed post-bootstrap must fail the unit."

# The unit's start timeout, plus its stop timeout, must end before the launch
# hook's heartbeat. Otherwise the hook could apply its default while the post
# phase is still inside a wait, and the post phase's own ABANDON would arrive
# too late to be the one that decides.
unit_seconds() {
    sed -n "s/^$1=\\([0-9]*\\)s\$/\\1/p" <<<"$post_unit"
}
start_timeout="$(unit_seconds TimeoutStartSec)"
stop_timeout="$(unit_seconds TimeoutStopSec)"
heartbeat="$(sed -n 's/^[[:space:]]*heartbeat_timeout[[:space:]]*=[[:space:]]*\([0-9]*\)[[:space:]]*$/\1/p' "$COMPUTE_SPOT_TF")"
[[ -n "$start_timeout" && -n "$stop_timeout" && -n "$heartbeat" ]] ||
    fail "The unit timeouts and the hook heartbeat must all be readable."
# 12 minutes for the pre phase: the 10-minute certbot budget and the rest.
(( 720 + start_timeout + stop_timeout < heartbeat )) ||
    fail "Pre (720s) + post start ($start_timeout s) + stop ($stop_timeout s) must fit inside the heartbeat ($heartbeat s)."

# ---------------------------------------------------------------------------
# Behavioural harness
# ---------------------------------------------------------------------------

fake_bin="$work_directory/bin"
mkdir -p "$fake_bin"
state_directory="$work_directory/state"
mkdir -p "$state_directory"

make_fake() {
    local name="$1" body="$2"
    cat >"$fake_bin/$name" <<FAKE
#!/usr/bin/env bash
$body
FAKE
    chmod 755 "$fake_bin/$name"
}

# `enable --now` and `disable --now` are modelled as what they are: two
# operations. The enable half takes effect and is recorded as durable unit state
# under $STATE_DIR/units before the start half is allowed to fail, so a test can
# tell "never touched the unit" from "left it enabled for the next boot".
#
# Anything that would start the ECS agent synchronously is recorded as
# ecs-sync-start, which no case may ever produce.
make_fake systemctl '
units="$STATE_DIR/units"
mkdir -p "$units"
case "$*" in
    "disable --now ecs")
        printf "ecs-stop-attempted\n" >>"$MARKER_FILE"
        printf "x" >>"$units/ecs-disable-attempts"
        attempts="$(wc -c <"$units/ecs-disable-attempts" | tr -d " ")"
        if [[ -e "$STATE_DIR/fail-ecs-initial-disable" && "$attempts" == "1" ]]; then
            exit 1
        fi
        rm -f "$units/ecs.enabled"
        printf "ecs-stop\n" >>"$MARKER_FILE" ;;
    "enable ecs")
        : >"$units/ecs.enabled"
        printf "ecs-enable-attempted\n" >>"$MARKER_FILE"
        [[ -e "$STATE_DIR/fail-ecs-enable" ]] && exit 1
        printf "ecs-enable\n" >>"$MARKER_FILE" ;;
    "disable --now ec-portfolio-certbot-renew.timer")
        rm -f "$units/renew.enabled"
        printf "renew-disable\n" >>"$MARKER_FILE" ;;
    "enable --now ec-portfolio-certbot-renew.timer")
        : >"$units/renew.enabled"
        printf "renew-enable-attempted\n" >>"$MARKER_FILE"
        [[ -e "$STATE_DIR/fail-renew-enable" ]] && exit 1
        printf "renew-enable\n" >>"$MARKER_FILE" ;;
    "enable --now ec-portfolio-imds-guard.service")
        : >"$units/imds-guard.enabled"
        printf "imds-guard-enable-attempted\n" >>"$MARKER_FILE"
        [[ -e "$STATE_DIR/fail-imds-guard-enable" ]] && exit 1
        printf "imds-guard-enable\n" >>"$MARKER_FILE" ;;
    "start --no-block ec-portfolio-spot-post-bootstrap.service")
        printf "post-queue-attempted\n" >>"$MARKER_FILE"
        [[ -e "$STATE_DIR/fail-post-queue" ]] && exit 1
        printf "post-queued\n" >>"$MARKER_FILE" ;;
    "stop --no-block ec-portfolio-spot-post-bootstrap.service")
        printf "post-cancelled\n" >>"$MARKER_FILE" ;;
    "daemon-reload")
        printf "daemon-reload\n" >>"$MARKER_FILE" ;;
    *ecs*)
        printf "ecs-sync-start %s\n" "$*" >>"$MARKER_FILE" ;;
    *)
        printf "systemctl-unexpected %s\n" "$*" >>"$MARKER_FILE" ;;
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
            printf "registration-poll\n" >>"$MARKER_FILE"
            [[ -e "$STATE_DIR/fail-registration" ]] && exit 1
            printf "registration\n" >>"$MARKER_FILE"
            printf "{\"Cluster\":\"%s\"}\n" "$(cat "$STATE_DIR/cluster-name" 2>/dev/null || printf "ec-portfolio-demo")"
            exit 0 ;;
        *8080*)
            printf "readiness-poll\n" >>"$MARKER_FILE"
            [[ -e "$STATE_DIR/fail-readiness" ]] && exit 1
            printf "api-ready\n" >>"$MARKER_FILE"
            printf "{\"status\":\"UP\"}\n"; exit 0 ;;
    esac
done
exit 0'

# The lifecycle report. The result is recorded both as attempted and, unless
# the case makes it fail, as delivered, together with the arguments.
make_fake aws '
. "$STATE_DIR/report-identity.sh"
report_identity aws
case "$*" in
    *complete-lifecycle-action*)
        result=""; previous=""
        for arg in "$@"; do
            [[ "$previous" == "--lifecycle-action-result" ]] && result="$arg"
            previous="$arg"
        done
        printf "lifecycle-%s-attempted\n" "$result" >>"$MARKER_FILE"
        printf "lifecycle-args %s\n" "$*" >>"$MARKER_FILE"
        [[ -e "$STATE_DIR/fail-lifecycle-$result" ]] && exit 1
        printf "lifecycle-%s\n" "$result" >>"$MARKER_FILE"
        exit 0 ;;
esac
printf "aws-unexpected %s\n" "$*" >>"$MARKER_FILE"
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
    */ecs.config)
        printf "ecs-config\n" >>"$MARKER_FILE"
        printf "ecs-config-installed-lines=%s\n" "$(wc -l <"$target" | tr -d " ")" >>"$MARKER_FILE" ;;
    */ec-portfolio-certbot-renew.timer) printf "renew-install\n" >>"$MARKER_FILE" ;;
    */ec-portfolio-imds-guard.service) printf "imds-guard-install\n" >>"$MARKER_FILE" ;;
    */ec-portfolio-spot-post-bootstrap.service) printf "post-install\n" >>"$MARKER_FILE" ;;
    */spot-post-bootstrap.env) printf "post-env\n" >>"$MARKER_FILE" ;;
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

for tool in bash env grep mktemp rm sed awk cat stat id dirname sleep cp mkdir printf sudo wc tr; do
    tool_path="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$tool_path" ]] && ln -sf "$tool_path" "$fake_bin/$tool"
done

# The bundle's required artifacts, read from the script under test so this
# suite follows the list rather than restating it.
required_artifacts="$(bash -c 'source "$1"; printf "%s\n" "${REQUIRED_BUNDLE_ARTIFACTS[@]}"' _ "$BOOTSTRAP_SCRIPT")"

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

    # The guard's own behaviour is imds-guard.test.sh's subject. Here it only
    # has to report that verify ran, and fail when a case asks it to.
    cat >"$bundle/imds-guard.sh" <<'GUARD'
#!/usr/bin/env bash
[[ "${1:-}" == "verify" ]] || exit 0
[[ -e "$STATE_DIR/fail-imds-verify" ]] && exit 1
printf 'imds-guard-verify\n' >>"$MARKER_FILE"
exit 0
GUARD

    printf '#!/usr/bin/env bash\nexit 0\n' >"$bundle/origin-smoke-check-ecs.sh"
    : >"$bundle/ec-portfolio-certbot-renew.service"
    : >"$bundle/ec-portfolio-certbot-renew.timer"
    : >"$bundle/ec-portfolio-imds-guard.service"
    : >"$bundle/ec-portfolio-spot-post-bootstrap.service"

    # A manifest naming every required artifact exactly once, by relative path.
    : >"$bundle/bundle.sha256"
    local artifact
    while IFS= read -r artifact; do
        printf '%064d  %s\n' 0 "$artifact" >>"$bundle/bundle.sha256"
    done <<<"$required_artifacts"
    chmod 755 "$bundle"/*.sh
}

# The environment every case starts from: valid inputs plus a hostile set of
# credential, endpoint and seam variables the bootstrap must not pass on.
hostile_env=(
    AWS_ACCESS_KEY_ID="leaked-static-key" AWS_PROFILE="leaked-profile"
    AWS_SHARED_CREDENTIALS_FILE="/tmp/evil-credentials"
    AWS_SECRET_ACCESS_KEY="leaked-secret" AWS_SESSION_TOKEN="leaked-token"
    AWS_SECURITY_TOKEN="leaked-token" AWS_DEFAULT_PROFILE="leaked-profile"
    AWS_CREDENTIAL_FILE="/tmp/evil-credentials" AWS_CONFIG_FILE="/tmp/evil-config"
    AWS_WEB_IDENTITY_TOKEN_FILE="/tmp/token"
    AWS_ROLE_ARN="arn:aws:iam::123456789012:role/evil"
    AWS_CONTAINER_CREDENTIALS_FULL_URI="http://127.0.0.1:9999/creds"
    AWS_CONTAINER_CREDENTIALS_RELATIVE_URI="/creds"
    AWS_EC2_METADATA_DISABLED="true"
    AWS_EC2_METADATA_SERVICE_ENDPOINT="http://127.0.0.1:9999"
    AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE="IPv6"
    AWS_ENDPOINT_URL="https://example.invalid"
    AWS_ENDPOINT_URL_S3="https://example.invalid"
    AWS_ENDPOINT_URL_SSM="https://example.invalid"
    AWS_ENDPOINT_URL_ROUTE53="https://example.invalid"
    AWS_CA_BUNDLE="/tmp/evil-ca.pem" REQUESTS_CA_BUNDLE="/tmp/evil-ca.pem"
    SSL_CERT_FILE="/tmp/evil-ca.pem" SSL_CERT_DIR="/tmp/evil-ca"
    BOTO_CONFIG="/tmp/evil-boto"
    ORIGIN_TLS_PARENT_DIRECTORY="/tmp/evil" CERTBOT_CONFIG_PREFIX="/tmp/evil"
)

# Prepares a fresh sandbox root for one case. $1 case name, rest: switch files.
prepare_case() {
    local case_name="$1"
    shift
    local root="$work_directory/$case_name"
    rm -rf "$root"; mkdir -p "$root/etc" "$root/run" "$root/usr/local/sbin" "$root/etc/systemd/system"
    build_bundle "$root/bundle"

    current_markers="$root/markers"
    : >"$current_markers"
    rm -f "$state_directory"/fail-*
    rm -rf "$state_directory/units"
    mkdir -p "$state_directory/units"
    local switch
    for switch in "$@"; do : >"$state_directory/$switch"; done
    last_root="$root"
}

# Runs one phase against the sandbox prefix. The suite sets bootstrap_mode the
# way main() does, then drives the phase function, so the sequence itself is
# observed; main() still refuses to run unprivileged, which is asserted
# statically below. Extra VAR=value arguments override the inputs.
run_phase() {
    local phase="$1"
    shift
    env PATH="$fake_bin:$PATH" \
        MARKER_FILE="$current_markers" STATE_DIR="$state_directory" \
        SPOT_BOOTSTRAP_PREFIX="$last_root" \
        ECS_CLUSTER_NAME="$CLUSTER" ORIGIN_TLS_BUCKET="$BUCKET" \
        AUTOSCALING_GROUP_NAME="$ASG_NAME" LIFECYCLE_HOOK_NAME="$HOOK_NAME" \
        INSTANCE_ID="$INSTANCE" \
        "${hostile_env[@]}" \
        SPOT_REGISTRATION_ATTEMPTS=2 SPOT_REGISTRATION_INTERVAL_SECONDS=0 \
        SPOT_READINESS_ATTEMPTS=2 SPOT_READINESS_INTERVAL_SECONDS=0 \
        "$@" \
        bash -c 'mode="$1"; shift; source "$1"; bootstrap_mode="$mode"; validate_inputs;
            if [[ "$mode" == pre ]]; then run_pre_bootstrap_steps; else run_post_bootstrap_steps; fi' \
        _ "$phase" "$last_root/bundle/bootstrap-spot-host.sh" >"$last_root/output" 2>&1 &&
        last_status=0 || last_status=$?
    return 0
}

# The ECS-optimized AMI ships the agent enabled, so a pre case starts from a
# host whose agent would come back on the next boot unless disabled.
run_pre() {
    local case_name="$1"
    shift
    prepare_case "$case_name" "$@"
    : >"$state_directory/units/ecs.enabled"
    run_phase pre
}

# A post case starts where a successful pre phase left the host: the agent
# enabled and started by the unit's Wants=, the guard enabled.
run_post() {
    local case_name="$1"
    shift
    prepare_case "$case_name" "$@"
    : >"$state_directory/units/ecs.enabled"
    : >"$state_directory/units/imds-guard.enabled"
    run_phase post
}

markers() {
    tr '\n' ' ' <"$current_markers"
}

marker_present() {
    grep -qxF "$1" "$current_markers" 2>/dev/null
}

marker_count() {
    grep -cxF "$1" "$current_markers" 2>/dev/null || printf '0\n'
}

serving_ready_exists() {
    [[ -e "$last_root/run/ec-portfolio-demo/spot-serving-ready" ]]
}

# The fake systemctl keeps enablement as durable state, so "would this unit come
# back on the next boot?" is a question the suite can actually ask.
unit_left_enabled() {
    [[ -e "$state_directory/units/$1.enabled" ]]
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

observed_order() {
    grep -xE "$1" "$current_markers" | tr '\n' ' '
}

current_markers=""
last_status=0
last_root=""

# ===========================================================================
# PRE PHASE
# ===========================================================================

# --- P1. the success path builds the host, hands over, and waits for nothing
run_pre pre-success
(( last_status == 0 )) || fail "The pre phase must exit 0. Output: $(cat "$last_root/output")"

expected_pre=(
    ecs-stop bundle-verify restore certbot-install cli-contract renew-install
    imds-guard-install post-env post-install daemon-reload
    imds-guard-enable imds-guard-verify ecs-config ecs-enable post-queued
)
pre_pattern='ecs-stop|bundle-verify|restore|certbot-install|cli-contract|renew-install|imds-guard-install|post-env|post-install|daemon-reload|imds-guard-enable|imds-guard-verify|ecs-config|ecs-enable|post-queued'
observed="$(observed_order "$pre_pattern")"
expected="$(printf '%s ' "${expected_pre[@]}")"
[[ "$observed" == "$expected" ]] ||
    fail "Pre-phase marker order mismatch.
  expected: $expected
  observed: $observed"

# Nothing in user data waits for the agent, the task or the origin, and nothing
# in user data reports the lifecycle action.
for absent in registration-poll readiness-poll nginx-configure ecs-smoke renew-enable-attempted \
    lifecycle-CONTINUE-attempted lifecycle-ABANDON-attempted; do
    if marker_present "$absent"; then fail "The pre phase must not produce $absent."; fi
done
if grep -q '^ecs-sync-start' "$current_markers"; then
    fail "The pre phase must never start the ECS agent synchronously: $(grep '^ecs-sync-start' "$current_markers")"
fi
if grep -q '^systemctl-unexpected' "$current_markers"; then
    fail "Unexpected systemctl call: $(grep '^systemctl-unexpected' "$current_markers")"
fi
if serving_ready_exists; then fail "The pre phase must not claim serving-ready."; fi

# The agent comes back on later boots, behind the guard, and the guard stays.
unit_left_enabled ecs || fail "The pre phase must leave the ECS agent enabled for later boots."
unit_left_enabled imds-guard || fail "The pre phase must leave the IMDS guard enabled."

# The hand-over carries exactly what the post phase needs, and no secret.
post_env="$(cat "$last_root/etc/ec-portfolio/spot-post-bootstrap.env" 2>/dev/null || true)"
expected_env="ECS_CLUSTER_NAME=$CLUSTER
ORIGIN_TLS_BUCKET=$BUCKET
AUTOSCALING_GROUP_NAME=$ASG_NAME
LIFECYCLE_HOOK_NAME=$HOOK_NAME
INSTANCE_ID=$INSTANCE
AWS_REGION=ap-northeast-1"
[[ "$post_env" == "$expected_env" ]] ||
    fail "The post-bootstrap environment must be exactly the six inputs. Got:
$post_env"
assert_absent "$post_env" "leaked" "No caller credential may reach the post-bootstrap environment."

# The ECS configuration is exactly these lines, each once and in this order:
# the cluster, Spot draining, and the execution role override the API task's
# Parameter Store secrets need on the EC2 launch type. Nothing else, nothing
# sensitive.
expected_ecs_config="ECS_CLUSTER=$CLUSTER
ECS_ENABLE_SPOT_INSTANCE_DRAINING=true
ECS_ENABLE_AWSLOGS_EXECUTIONROLE_OVERRIDE=true"
ecs_config="$(cat "$last_root/etc/ecs/ecs.config" 2>/dev/null || true)"
[[ "$ecs_config" == "$expected_ecs_config" ]] ||
    fail "The ECS configuration must be exactly the three expected lines. Got:
$ecs_config"
[[ "$(grep -c '^ECS_ENABLE_AWSLOGS_EXECUTIONROLE_OVERRIDE=' "$last_root/etc/ecs/ecs.config")" == 1 ]] ||
    fail "The execution role override must be set exactly once."
# Complete at the moment it is installed: one replacement, not a file that is
# installed and then added to.
[[ "$(marker_count "ecs-config-installed-lines=3")" == 1 ]] ||
    fail "The ECS configuration must be installed complete, in one step: $(grep '^ecs-config-installed-lines=' "$current_markers" | tr '\n' ' ')"

# Writing it again leaves the file unchanged: it is replaced, never appended to.
env PATH="$fake_bin:$PATH" MARKER_FILE="$last_root/rewrite-markers" STATE_DIR="$state_directory" \
    SPOT_BOOTSTRAP_PREFIX="$last_root" ECS_CLUSTER_NAME="$CLUSTER" \
    bash -c 'source "$1"; write_ecs_config' _ "$last_root/bundle/bootstrap-spot-host.sh" >/dev/null 2>&1 ||
    fail "A second write of the ECS configuration must succeed."
[[ "$(cat "$last_root/etc/ecs/ecs.config" 2>/dev/null || true)" == "$expected_ecs_config" ]] ||
    fail "A second write must leave the ECS configuration unchanged."

# --- P2. the restore runs with the instance role only ----------------------
for observation in \
    "restore-static-creds=<unset>" "restore-profile=<unset>" "cli-static-creds=<unset>"
do
    assert_contains "$(cat "$current_markers")" "$observation" \
        "Every AWS child must run with the instance role only ($observation)."
done
for observation in "restore-tls-seam=<unset>" "cli-certbot-seam=<unset>"; do
    assert_contains "$(cat "$current_markers")" "$observation" \
        "Helper test seams must not be inherited by a production child ($observation)."
done
for tag in restore cli; do
    assert_identity_clean "$tag"
done

# The positive control for the assertions above. dnf is the one child the
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

assert_contains "$(cat "$current_markers")" "restore-region=ap-northeast-1" \
    "Every AWS child must be given the Region explicitly."
assert_contains "$(cat "$current_markers")" "restore-bucket=$BUCKET" \
    "The restore must be given the configured bucket."
assert_absent "$(cat "$current_markers")" "certbot-invoked" \
    "The bootstrap must never execute certbot."

# --- P3. every pre gate fails closed and hands nothing over -----------------
# The loader reports ABANDON for these, so the pre phase itself reports
# nothing. The agent is held back first and taken out again, the post unit is
# never queued (or is cancelled), and the host never claims to be ready.
for case_spec in \
    "bundle:fail-bundle:bundle-verify" \
    "restore:fail-restore:restore" \
    "certbot:fail-certbot-install:certbot-install" \
    "cli:fail-cli-contract:cli-contract" \
    "guard-enable:fail-imds-guard-enable:imds-guard-enable" \
    "guard-verify:fail-imds-verify:imds-guard-verify" \
    "ecs-enable:fail-ecs-enable:ecs-enable" \
    "post-queue:fail-post-queue:post-queued"
do
    name="${case_spec%%:*}"
    rest="${case_spec#*:}"
    switch="${rest%%:*}"
    absent_marker="${rest#*:}"

    run_pre "pre-fail-$name" "$switch"
    (( last_status != 0 )) || fail "The $name gate must fail the pre phase."
    if marker_present "$absent_marker"; then fail "A failed $name gate must not report $absent_marker."; fi
    if [[ "$name" != "post-queue" ]] && marker_present post-queue-attempted; then
        fail "A failed $name gate must not queue the post-bootstrap."
    fi
    if unit_left_enabled ecs; then fail "A failed $name gate must not leave the ECS agent enabled."; fi
    if serving_ready_exists; then fail "A failed $name gate must not record serving-ready."; fi
    if grep -q '^lifecycle-' "$current_markers"; then
        fail "The pre phase must leave lifecycle reporting to the loader (case $name)."
    fi
done

# A guard that is not proven keeps the agent unconfigured as well as disabled.
for guard_case in "pre-fail-guard-enable" "pre-fail-guard-verify"; do
    current_markers="$work_directory/$guard_case/markers"
    if marker_present ecs-config; then
        fail "The ECS configuration must not be written before the IMDS guard is proven ($guard_case)."
    fi
    if marker_present ecs-enable-attempted; then
        fail "The ECS agent must not be enabled before the IMDS guard is proven ($guard_case)."
    fi
done

# A post unit that may have been queued is cancelled.
current_markers="$work_directory/pre-fail-post-queue/markers"
marker_present post-cancelled ||
    fail "A failed queue must cancel whatever may have been queued."

# --- P4. the agent is stopped before anything else --------------------------
run_pre pre-ordering
marker_present marker-dir ||
    fail "The marker directory step must be observable, or the ordering proves little."
first_marker="$(grep -m 1 -xE 'ecs-stop|marker-dir|bundle-verify|restore|ecs-config|ecs-enable' "$current_markers")"
[[ "$first_marker" == "ecs-stop" ]] ||
    fail "The ECS agent must be disabled before any other step (first marker was: $first_marker)."

# --- P5. a partial *initial* disable is retried by the cleanup --------------
run_pre pre-initial-disable fail-ecs-initial-disable
(( last_status != 0 )) || fail "A failed initial ECS disable must fail the pre phase."
(( $(marker_count ecs-stop-attempted) == 2 )) ||
    fail "The cleanup must retry the disable after the first attempt failed (attempts: $(marker_count ecs-stop-attempted))."
(( $(marker_count ecs-stop) == 1 )) ||
    fail "Exactly one disable should have succeeded, the cleanup retry (succeeded: $(marker_count ecs-stop))."
if unit_left_enabled ecs; then fail "A failed initial disable must not leave the ECS agent enabled."; fi
if marker_present bundle-verify; then fail "A failed initial disable must stop the pre phase."; fi

# --- P6. a partial `enable ecs` is still cleaned up -------------------------
run_pre pre-partial-enable fail-ecs-enable
marker_present ecs-enable-attempted ||
    fail "The partial-enable case must have reached the enable, or it tests nothing."
(( $(marker_count ecs-stop) >= 2 )) ||
    fail "A partial ECS enable must be undone (ecs-stop seen $(marker_count ecs-stop) times)."

# --- P7. a host that already has certbot state is refused -------------------
prepare_case pre-preexisting
: >"$state_directory/units/ecs.enabled"
mkdir -p "$last_root/etc/letsencrypt"
run_phase pre
(( last_status != 0 )) || fail "A host that already carries certbot state must be refused."
if marker_present restore; then fail "A pre-existing certbot tree must not be restored over."; fi

# --- P8. the cleanup does not fire on the success path ----------------------
run_pre pre-cleanup-not-on-success
(( last_status == 0 )) || fail "The pre phase must exit 0. Output: $(cat "$last_root/output")"
(( $(marker_count ecs-stop) == 1 )) || fail "The success path must disable the agent exactly once."
(( $(marker_count ecs-stop-attempted) == 1 )) || fail "The success path must not retry the disable."
if marker_present post-cancelled; then fail "The success path must not cancel the post-bootstrap."; fi

# ===========================================================================
# POST PHASE
# ===========================================================================

# --- Q1. the success path proves the host and reports CONTINUE -------------
run_post post-success
(( last_status == 0 )) || fail "The post phase must exit 0. Output: $(cat "$last_root/output")"
expected_post=(
    bundle-verify registration api-ready nginx-configure ecs-smoke renew-enable lifecycle-CONTINUE
)
post_pattern='bundle-verify|registration|api-ready|nginx-configure|ecs-smoke|renew-enable|lifecycle-CONTINUE|lifecycle-ABANDON'
observed="$(observed_order "$post_pattern")"
expected="$(printf '%s ' "${expected_post[@]}")"
[[ "$observed" == "$expected" ]] ||
    fail "Post-phase marker order mismatch.
  expected: $expected
  observed: $observed"
serving_ready_exists || fail "The post phase must record serving-ready on success."
unit_left_enabled ecs || fail "A finished host must keep the ECS agent enabled."
unit_left_enabled renew || fail "A finished host must keep the renewal timer enabled."
if marker_present ecs-stop-attempted; then fail "The success path must not take the agent down."; fi
(( $(marker_count lifecycle-CONTINUE-attempted) == 1 )) || fail "CONTINUE must be reported exactly once."
if marker_present lifecycle-ABANDON-attempted; then fail "The success path must not report ABANDON."; fi

lifecycle_args="$(grep '^lifecycle-args ' "$current_markers")"
for expected_arg in "--auto-scaling-group-name $ASG_NAME" "--lifecycle-hook-name $HOOK_NAME" \
    "--instance-id $INSTANCE" "--lifecycle-action-result CONTINUE" "--region ap-northeast-1"; do
    assert_contains "$lifecycle_args" "$expected_arg" \
        "The lifecycle report must carry $expected_arg."
done
assert_contains "$(cat "$current_markers")" "smoke-mode=ecs" \
    "configure-origin.sh must be invoked with ORIGIN_SMOKE_MODE=ecs."
assert_contains "$(cat "$current_markers")" "origin-region=ap-northeast-1" \
    "The origin child must be given the Region explicitly."
for tag in origin aws; do
    assert_identity_clean "$tag"
done
assert_contains "$(cat "$current_markers")" "origin-tls-seam=<unset>" \
    "Helper test seams must not reach the origin child."

# --- Q2. every post gate takes the host out and reports ABANDON -------------
for case_spec in \
    "bundle:fail-bundle" \
    "registration:fail-registration" \
    "readiness:fail-readiness" \
    "smoke:fail-smoke" \
    "renew:fail-renew-enable" \
    "continue:fail-lifecycle-CONTINUE"
do
    name="${case_spec%%:*}"
    switch="${case_spec#*:}"

    run_post "post-fail-$name" "$switch"
    (( last_status != 0 )) || fail "The $name gate must fail the post phase."
    (( $(marker_count lifecycle-ABANDON) == 1 )) ||
        fail "A failed $name gate must report ABANDON exactly once. Markers: $(markers)"
    if marker_present lifecycle-CONTINUE; then fail "A failed $name gate must not deliver CONTINUE."; fi
    marker_present ecs-stop || fail "A failed $name gate must take the host back out of the cluster."
    if unit_left_enabled ecs; then fail "A failed $name gate must not leave the ECS agent enabled."; fi
    if serving_ready_exists; then fail "A failed $name gate must not leave serving-ready behind."; fi
    if unit_left_enabled renew; then fail "A failed $name gate must not leave the renewal timer enabled."; fi
done

# The CONTINUE case is the one where the marker was written first: it must be
# removed again because the host never became InService.
current_markers="$work_directory/post-fail-continue/markers"
marker_present lifecycle-CONTINUE-attempted ||
    fail "The CONTINUE-failure case must have attempted CONTINUE, or it tests nothing."

# --- Q3. the agent must register with the expected cluster ------------------
for wrong_cluster in default other-cluster; do
    printf '%s' "$wrong_cluster" >"$state_directory/cluster-name"
    run_post "post-cluster-$wrong_cluster"
    rm -f "$state_directory/cluster-name"
    (( last_status != 0 )) ||
        fail "Registration with '$wrong_cluster' must fail rather than be accepted."
    marker_present lifecycle-ABANDON || fail "A wrong-cluster registration must report ABANDON."
done

# --- Q4. systemd's start timeout becomes an ABANDON -------------------------
# The unit's TimeoutStartSec ends in SIGTERM. The readiness wait below never
# succeeds; the signal must still end in the host taken out and ABANDON sent.
prepare_case post-timeout fail-readiness
: >"$state_directory/units/ecs.enabled"
env PATH="$fake_bin:$PATH" \
    MARKER_FILE="$current_markers" STATE_DIR="$state_directory" \
    SPOT_BOOTSTRAP_PREFIX="$last_root" \
    ECS_CLUSTER_NAME="$CLUSTER" ORIGIN_TLS_BUCKET="$BUCKET" \
    AUTOSCALING_GROUP_NAME="$ASG_NAME" LIFECYCLE_HOOK_NAME="$HOOK_NAME" INSTANCE_ID="$INSTANCE" \
    SPOT_REGISTRATION_ATTEMPTS=2 SPOT_REGISTRATION_INTERVAL_SECONDS=0 \
    SPOT_READINESS_ATTEMPTS=1000 SPOT_READINESS_INTERVAL_SECONDS=1 \
    bash -c 'source "$1"; bootstrap_mode=post; validate_inputs; run_post_bootstrap_steps' \
    _ "$last_root/bundle/bootstrap-spot-host.sh" >"$last_root/output" 2>&1 &
post_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    marker_present readiness-poll && break
    sleep 1
done
marker_present readiness-poll || fail "The timeout case must have reached the readiness wait."
kill -TERM "$post_pid"
timeout_status=0
wait "$post_pid" || timeout_status=$?
(( timeout_status == 143 )) || fail "A post phase ended by SIGTERM must exit 143 (got $timeout_status)."
(( $(marker_count lifecycle-ABANDON) == 1 )) ||
    fail "A post phase ended by SIGTERM must report ABANDON. Markers: $(markers)"
marker_present ecs-stop || fail "A post phase ended by SIGTERM must take the host out of the cluster."
if marker_present lifecycle-CONTINUE-attempted; then fail "A timed-out post phase must not report CONTINUE."; fi

# --- Q5. post inputs are validated, and an ABANDON needs valid identifiers --
prepare_case post-bad-bucket
run_phase post ORIGIN_TLS_BUCKET="NotAValidBucket"
(( last_status != 0 )) || fail "The post phase must refuse an invalid bucket."
marker_present lifecycle-ABANDON ||
    fail "A post phase that fails its input checks must still report ABANDON."

prepare_case post-bad-instance
run_phase post INSTANCE_ID="not-an-instance"
(( last_status != 0 )) || fail "The post phase must refuse an invalid instance ID."
if grep -q '^lifecycle-' "$current_markers"; then
    fail "No lifecycle action may be sent for an instance ID that failed validation."
fi

# ===========================================================================
# BOTH PHASES
# ===========================================================================

# --- B1. required inputs are validated --------------------------------------
valid_inputs=(
    ECS_CLUSTER_NAME="$CLUSTER" ORIGIN_TLS_BUCKET="$BUCKET"
    AUTOSCALING_GROUP_NAME="$ASG_NAME" LIFECYCLE_HOOK_NAME="$HOOK_NAME" INSTANCE_ID="$INSTANCE"
)
env PATH="$fake_bin:$PATH" "${valid_inputs[@]}" \
    bash -c 'source "$1"; validate_inputs' _ "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1 ||
    fail "validate_inputs must accept the valid inputs (positive control)."
for bad_env in "ECS_CLUSTER_NAME=" "ORIGIN_TLS_BUCKET=" "ECS_CLUSTER_NAME=not valid" \
    "ORIGIN_TLS_BUCKET=NotAValidBucket" "AUTOSCALING_GROUP_NAME=" "AUTOSCALING_GROUP_NAME=has space" \
    "LIFECYCLE_HOOK_NAME=" "LIFECYCLE_HOOK_NAME=bad;name" "INSTANCE_ID=" "INSTANCE_ID=i-XYZ" \
    "INSTANCE_ID=i-0123456789abcdef0 extra" "AWS_REGION=us-east-1"; do
    if env PATH="$fake_bin:$PATH" "${valid_inputs[@]}" "$bad_env" \
        bash -c 'source "$1"; validate_inputs' _ "$BOOTSTRAP_SCRIPT" >/dev/null 2>&1; then
        fail "validate_inputs must reject: $bad_env"
    fi
done

# --- B2. the entry point needs a phase and still refuses to run unprivileged
for bad_args in "" "bogus" "pre post"; do
    # shellcheck disable=SC2086
    if env PATH="$fake_bin:$PATH" bash -c 'source "$1"; shift; main "$@"' _ "$BOOTSTRAP_SCRIPT" $bad_args \
        >/dev/null 2>&1; then
        fail "main must refuse the arguments: '$bad_args'"
    fi
done
assert_contains "$script_code" '(( EUID == 0 )) || fail' \
    "validate_platform must still require root."
assert_contains "$script_code" 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' \
    "Sourcing the script must not run a bootstrap."

# --- B3. the bundle manifest must cover every required artifact -------------
# sha256sum --check only validates what a manifest lists, so a manifest is
# refused before it is used unless it names each artifact exactly once by a
# relative path inside the bundle.
manifest_case() {
    local name="$1" manifest_body="$2"
    prepare_case "manifest-$name"
    : >"$state_directory/units/ecs.enabled"
    printf '%s' "$manifest_body" >"$last_root/bundle/bundle.sha256"
    run_phase pre
    (( last_status == 0 ))
}

full_manifest="$(cat "$work_directory/pre-success/bundle/bundle.sha256")
"

for missing in configure-origin.sh imds-guard.sh ec-portfolio-imds-guard.service \
    ec-portfolio-spot-post-bootstrap.service sync-origin-tls.sh; do
    body="$(grep -vF " $missing" <<<"$full_manifest")"
    if manifest_case "missing-${missing%%.*}" "$body"; then
        fail "A manifest omitting $missing must be refused."
    fi
done

if manifest_case duplicate "$full_manifest$(printf '%064d  configure-origin.sh\n' 0)"; then
    fail "A manifest naming an artifact twice must be refused."
fi

if manifest_case absolute "$(printf '%064d  /etc/passwd\n' 0)$full_manifest"; then
    fail "A manifest containing an absolute path must be refused."
fi

if manifest_case traversal "$(printf '%064d  ../outside.sh\n' 0)$full_manifest"; then
    fail "A manifest containing a parent traversal entry must be refused."
fi

# A missing new artifact is refused by the file check too, not only the manifest.
prepare_case missing-guard-file
: >"$state_directory/units/ecs.enabled"
rm -f "$last_root/bundle/imds-guard.sh"
run_phase pre
(( last_status != 0 )) || fail "A bundle without imds-guard.sh must be refused."
assert_contains "$(cat "$last_root/output")" "missing imds-guard.sh" \
    "The refusal must name the missing artifact."

# --- B4. the sandbox prefix cannot be used against a real host --------------
direct_output="$(env PATH="$fake_bin:$PATH" SPOT_BOOTSTRAP_PREFIX="$work_directory/hijack" \
    "${valid_inputs[@]}" bash "$BOOTSTRAP_SCRIPT" pre 2>&1)" && direct_status=0 || direct_status=$?
(( direct_status != 0 )) ||
    fail "Executing the script with SPOT_BOOTSTRAP_PREFIX set must fail."
assert_contains "$direct_output" "test seam" \
    "The refusal must say the prefix is a test seam."
[[ -e "$work_directory/hijack" ]] &&
    fail "A refused run must not create anything under the requested prefix."

empty_output="$(env PATH="$fake_bin:$PATH" SPOT_BOOTSTRAP_PREFIX="" \
    "${valid_inputs[@]}" bash "$BOOTSTRAP_SCRIPT" pre 2>&1 || true)"
assert_absent "$empty_output" "test seam" \
    "An empty prefix must not be treated as the test seam."

# --- B5. production defaults resolve to the real host paths -----------------
default_paths="$(env PATH="$fake_bin:$PATH" bash -c '
    source "$1"
    printf "%s\n" "$LETSENCRYPT_DIRECTORY" "$ECS_CONFIG_FILE" "$SERVING_READY_MARKER" \
        "$SYNC_TARGET" "$IMDS_GUARD_TARGET" "$IMDS_GUARD_UNIT_TARGET" \
        "$POST_BOOTSTRAP_UNIT_TARGET" "$POST_BOOTSTRAP_ENV_FILE"
' _ "$BOOTSTRAP_SCRIPT")"
for expected in "/etc/letsencrypt" "/etc/ecs/ecs.config" \
    "/run/ec-portfolio-demo/spot-serving-ready" "/usr/local/sbin/ec-portfolio-sync-origin-tls" \
    "/usr/local/sbin/ec-portfolio-imds-guard" "/etc/systemd/system/ec-portfolio-imds-guard.service" \
    "/etc/systemd/system/ec-portfolio-spot-post-bootstrap.service" \
    "/etc/ec-portfolio/spot-post-bootstrap.env"; do
    grep -qxF -- "$expected" <<<"$default_paths" ||
        fail "With no prefix the script must use the host path $expected."
done
# The unit reads the file the pre phase writes.
grep -qxF "EnvironmentFile=/etc/ec-portfolio/spot-post-bootstrap.env" <<<"$post_unit" ||
    fail "The post unit's EnvironmentFile must be the file the pre phase writes."

# --- B6. no secret reaches the output ---------------------------------------
for output_case in pre-success post-success; do
    output_contents="$(cat "$work_directory/$output_case/output")"
    assert_absent "$output_contents" "leaked-static-key" \
        "A static credential in the caller environment must not be echoed ($output_case)."
    assert_absent "$output_contents" "BEGIN PRIVATE KEY" \
        "No key material may reach the output ($output_case)."
done

printf '[spot-bootstrap-test] PASS\n'
