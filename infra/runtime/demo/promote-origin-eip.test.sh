#!/usr/bin/env bash

# Behaviour tests for the Phase 6C-5c-2 origin Elastic IP promotion.
#
# Every external command the promotion depends on is faked -- aws, curl for
# IMDS, timeout, install -- and so is the ECS origin smoke check it re-runs.
# Each fake appends a marker, and the assertions read the marker sequence: the
# order of the steps, how many times each AWS operation ran and with which
# arguments, and which operations never ran at all.
#
# No AWS call, no IMDS, no systemctl. Runs under bash 3.2 and bash 5.

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROMOTION_SCRIPT="$SCRIPT_DIRECTORY/promote-origin-eip.sh"
readonly PROMOTION_UNIT_FILE="$SCRIPT_DIRECTORY/ec-portfolio-spot-eip-promotion.service"
readonly POST_UNIT_FILE="$SCRIPT_DIRECTORY/ec-portfolio-spot-post-bootstrap.service"
readonly BOOTSTRAP_SCRIPT="$SCRIPT_DIRECTORY/bootstrap-spot-host.sh"
readonly ASG_NAME="ec-portfolio-demo-ecs-spot"
readonly INSTANCE="i-0123456789abcdef0"
readonly ON_DEMAND="i-0fedcba9876543210"
readonly OTHER_SPOT="i-0aaaabbbbccccdddd"
readonly ALLOCATION="eipalloc-0123456789abcdef0"

work_directory=""

cleanup_tests() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-eip-promotion-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup_tests EXIT

fail() {
    printf '[eip-promotion-test] FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "$3 (expected to find: $2)"
}

assert_absent() {
    [[ "$1" != *"$2"* ]] || fail "$3 (unexpectedly found: $2)"
}

work_directory="$(mktemp -d /tmp/ec-portfolio-eip-promotion-test.XXXXXX)"

script_code="$(sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*#.*$//' "$PROMOTION_SCRIPT")"

# ---------------------------------------------------------------------------
# Static contract: what the promotion can never do
# ---------------------------------------------------------------------------

# The lifecycle action is complete by the time this runs, and a promotion
# problem is not a host problem: nothing here may undo, replace or resize the
# host, take the agent down or leave the address on nobody.
for forbidden in complete-lifecycle-action terminate-instances stop-instances disassociate-address \
    set-desired-capacity update-auto-scaling-group detach-instances systemctl \
    "record-lifecycle-action-heartbeat" "network-interface-id"; do
    assert_absent "$script_code" "$forbidden" "The promotion must never call $forbidden."
done
(( $(grep -c 'associate-address' <<<"$script_code") == 1 )) ||
    fail "associate-address must have exactly one call site."
for required in '--allocation-id "$EIP_ALLOCATION_ID"' '--instance-id "$INSTANCE_ID"' '--allow-reassociation'; do
    assert_contains "$script_code" "$required" "The association must carry $required."
done
assert_contains "$script_code" '(( EUID == 0 )) || fail' "main must require root."
assert_contains "$script_code" 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' \
    "Sourcing the script must not run a promotion."

# ---------------------------------------------------------------------------
# Static contract: the unit
# ---------------------------------------------------------------------------

promotion_unit="$(sed -e 's/^[[:space:]]*#.*$//' "$PROMOTION_UNIT_FILE")"
for line in "Type=oneshot" "After=ec-portfolio-spot-post-bootstrap.service" \
    "ConditionPathExists=/run/ec-portfolio-demo/spot-serving-ready" \
    "ConditionPathExists=/run/ec-portfolio-demo/spot-continue-accepted" \
    "EnvironmentFile=/etc/ec-portfolio/spot-post-bootstrap.env" \
    "ExecStart=/opt/ec-portfolio/runtime/demo/promote-origin-eip.sh"; do
    grep -qxF -- "$line" <<<"$promotion_unit" ||
        fail "The promotion unit must contain the line: $line"
done
for forbidden in "[Install]" "EnvironmentFile=-" "ExecStart=-" "Restart="; do
    assert_absent "$promotion_unit" "$forbidden" "The promotion unit must not contain $forbidden."
done
grep -qE '^TimeoutStartSec=[0-9]+s$' <<<"$promotion_unit" ||
    fail "The promotion unit must bound its run with TimeoutStartSec."

# One bundle directory and one environment file for both units, and the same
# marker paths in the unit, this script and the bootstrap that writes them.
post_exec="$(sed -n 's/^ExecStart=\(.*\)\/bootstrap-spot-host\.sh post$/\1/p' "$POST_UNIT_FILE")"
[[ "$post_exec" == "/opt/ec-portfolio/runtime/demo" ]] ||
    fail "The promotion unit must run from the post-bootstrap's bundle directory."
marker_paths="$(env -u SPOT_PROMOTION_PREFIX bash -c 'source "$1"; printf "%s %s\n" "$SERVING_READY_MARKER" "$CONTINUE_ACCEPTED_MARKER"' _ "$PROMOTION_SCRIPT")"
bootstrap_paths="$(env -u SPOT_BOOTSTRAP_PREFIX bash -c 'source "$1"; printf "%s %s\n" "$SERVING_READY_MARKER" "$CONTINUE_ACCEPTED_MARKER"' _ "$BOOTSTRAP_SCRIPT")"
[[ "$marker_paths" == "/run/ec-portfolio-demo/spot-serving-ready /run/ec-portfolio-demo/spot-continue-accepted" ]] ||
    fail "The promotion must read the markers at their host paths (got: $marker_paths)."
[[ "$marker_paths" == "$bootstrap_paths" ]] ||
    fail "The promotion and the bootstrap must agree on the marker paths ($marker_paths vs $bootstrap_paths)."

# ---------------------------------------------------------------------------
# Behavioural harness
# ---------------------------------------------------------------------------

fake_bin="$work_directory/bin"
state_directory="$work_directory/state"
mkdir -p "$fake_bin" "$state_directory"

make_fake() {
    local name="$1" body="$2"
    cat >"$fake_bin/$name" <<FAKE
#!/usr/bin/env bash
$body
FAKE
    chmod 755 "$fake_bin/$name"
}

IDENTITY_ENV=(
    AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
    AWS_PROFILE AWS_DEFAULT_PROFILE AWS_CREDENTIAL_FILE
    AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE
    AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN
    AWS_CONTAINER_CREDENTIALS_FULL_URI AWS_CONTAINER_CREDENTIALS_RELATIVE_URI
    AWS_EC2_METADATA_DISABLED AWS_EC2_METADATA_SERVICE_ENDPOINT
    AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE
    AWS_ENDPOINT_URL AWS_ENDPOINT_URL_EC2 AWS_ENDPOINT_URL_AUTO_SCALING AWS_ENDPOINT_URL_SSM
    AWS_CA_BUNDLE REQUESTS_CA_BUNDLE SSL_CERT_FILE SSL_CERT_DIR BOTO_CONFIG
    ORIGIN_SMOKE_MODE SPOT_BOOTSTRAP_PREFIX
)
{
    printf 'identity_env="%s"\n\n' "${IDENTITY_ENV[*]}"
    cat <<'REPORT'
report_identity() {
    tag="$1"
    for name in $identity_env; do
        printf '%s-identity %s=%s\n' "$tag" "$name" "${!name-<unset>}" >>"$MARKER_FILE"
    done
    printf '%s-region %s/%s\n' "$tag" "${AWS_REGION-<unset>}" "${AWS_DEFAULT_REGION-<unset>}" >>"$MARKER_FILE"
}
REPORT
} >"$state_directory/report-identity.sh"

# once <switch>: true the first time the switch is consulted, false afterwards.
cat >>"$state_directory/report-identity.sh" <<'ONCE'
once() {
    [[ -e "$STATE_DIR/$1" && ! -e "$STATE_DIR/$1.used" ]] || return 1
    : >"$STATE_DIR/$1.used"
}
ONCE

# EC2 and Auto Scaling as the promotion sees them. The address holder is state:
# a real association that is allowed moves it to the requested instance.
make_fake aws '
. "$STATE_DIR/report-identity.sh"
report_identity aws
args=" $* "
deny() { printf "An error occurred (%s) when calling the %s operation: User: arn:aws:sts::123456789012:assumed-role/ec-portfolio-demo-ecs-spot/%s is not authorized. Encoded authorization failure message: SECRETENCODED\n" "$1" "$2" "$INSTANCE_UNDER_TEST" >&2; exit 254; }
[[ "$args" == *" --region ap-northeast-1 "* ]] || { printf "aws-unexpected-region %s\n" "$*" >>"$MARKER_FILE"; exit 97; }
case "$args" in
    *" autoscaling describe-auto-scaling-groups "*)
        printf "asg-read %s\n" "$*" >>"$MARKER_FILE"
        once fail-asg-read-once && deny Throttling DescribeAutoScalingGroups
        [[ -e "$STATE_DIR/fail-asg-read" ]] && deny Throttling DescribeAutoScalingGroups
        printf "%s\n" "$(cat "$STATE_DIR/asg-answer")" ;;
    *" ec2 describe-addresses "*)
        printf "holder-read %s\n" "$*" >>"$MARKER_FILE"
        [[ -e "$STATE_DIR/fail-holder-read" ]] && deny RequestLimitExceeded DescribeAddresses
        cat "$STATE_DIR/holder" ;;
    *" ec2 associate-address "*" --dry-run "*|*" ec2 associate-address --dry-run "*)
        printf "dry-run %s\n" "$*" >>"$MARKER_FILE"
        [[ -e "$STATE_DIR/dry-run-unauthorized" ]] && deny UnauthorizedOperation AssociateAddress
        once dry-run-throttle-once && deny RequestLimitExceeded AssociateAddress
        [[ -e "$STATE_DIR/dry-run-succeeds" ]] && exit 0
        deny DryRunOperation AssociateAddress ;;
    *" ec2 associate-address "*)
        printf "associate %s\n" "$*" >>"$MARKER_FILE"
        [[ -e "$STATE_DIR/associate-unauthorized" ]] && deny UnauthorizedOperation AssociateAddress
        once associate-fail-once && deny InternalError AssociateAddress
        [[ -e "$STATE_DIR/associate-fail" ]] && deny InternalError AssociateAddress
        [[ -e "$STATE_DIR/associate-no-effect" ]] || printf "%s\n" "$INSTANCE_UNDER_TEST" >"$STATE_DIR/holder"
        printf "{\"AssociationId\":\"eipassoc-0123456789abcdef0\"}\n" ;;
    *)
        printf "aws-unexpected %s\n" "$*" >>"$MARKER_FILE"; exit 97 ;;
esac
exit 0'

# IMDSv2: a token, then this instance's ID.
make_fake curl '
for arg in "$@"; do
    case "$arg" in
        */api/token)
            printf "imds-token\n" >>"$MARKER_FILE"
            [[ -e "$STATE_DIR/fail-imds" ]] && exit 22
            printf "imds-test-token"; exit 0 ;;
        */meta-data/instance-id)
            printf "imds-instance-id\n" >>"$MARKER_FILE"
            if [[ -e "$STATE_DIR/imds-other-instance" ]]; then printf "%s" "$OTHER_SPOT"; else printf "%s" "$INSTANCE_UNDER_TEST"; fi
            exit 0 ;;
    esac
done
printf "curl-unexpected %s\n" "$*" >>"$MARKER_FILE"
exit 7'

make_fake timeout '
while [[ "$1" == --* ]]; do shift; done
shift
exec "$@"'

make_fake install '
while [ $# -gt 0 ]; do
    case "$1" in
        -d) shift; mkdir -p "${@: -1}"; exit 0 ;;
        -o|-g|-m) shift 2 ;;
        *) shift ;;
    esac
done
exit 0'

make_fake sleep 'printf "sleep %s\n" "$1" >>"$MARKER_FILE"; exit 0'

for tool in bash env grep mktemp rm sed awk cat dirname cp mkdir printf wc tr; do
    tool_path="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$tool_path" ]] && ln -sf "$tool_path" "$fake_bin/$tool"
done

# The script under test inside a bundle directory, next to a stand-in for the
# smoke check that records its own environment.
build_bundle() {
    local bundle="$1"
    mkdir -p "$bundle"
    cp "$PROMOTION_SCRIPT" "$bundle/promote-origin-eip.sh"
    cat >"$bundle/origin-smoke-check-ecs.sh" <<'SMOKE'
#!/usr/bin/env bash
. "$STATE_DIR/report-identity.sh"
printf 'smoke\n' >>"$MARKER_FILE"
printf 'smoke-server-name=%s\n' "${ORIGIN_SERVER_NAME-<unset>}" >>"$MARKER_FILE"
report_identity smoke
once fail-smoke-once && exit 1
[[ -e "$STATE_DIR/fail-smoke" ]] && exit 1
exit 0
SMOKE
    chmod 755 "$bundle"/*.sh
}

hostile_env=(
    AWS_ACCESS_KEY_ID="leaked-static-key" AWS_SECRET_ACCESS_KEY="leaked-secret"
    AWS_SESSION_TOKEN="leaked-token" AWS_SECURITY_TOKEN="leaked-token"
    AWS_PROFILE="leaked-profile" AWS_DEFAULT_PROFILE="leaked-profile"
    AWS_CREDENTIAL_FILE="/tmp/evil-credentials" AWS_SHARED_CREDENTIALS_FILE="/tmp/evil-credentials"
    AWS_CONFIG_FILE="/tmp/evil-config"
    AWS_WEB_IDENTITY_TOKEN_FILE="/tmp/token" AWS_ROLE_ARN="arn:aws:iam::123456789012:role/evil"
    AWS_CONTAINER_CREDENTIALS_FULL_URI="http://127.0.0.1:9999/creds"
    AWS_CONTAINER_CREDENTIALS_RELATIVE_URI="/creds"
    AWS_EC2_METADATA_DISABLED="true" AWS_EC2_METADATA_SERVICE_ENDPOINT="http://127.0.0.1:9999"
    AWS_EC2_METADATA_SERVICE_ENDPOINT_MODE="IPv6"
    AWS_ENDPOINT_URL="https://example.invalid" AWS_ENDPOINT_URL_EC2="https://example.invalid"
    AWS_ENDPOINT_URL_AUTO_SCALING="https://example.invalid" AWS_ENDPOINT_URL_SSM="https://example.invalid"
    AWS_CA_BUNDLE="/tmp/evil-ca.pem" REQUESTS_CA_BUNDLE="/tmp/evil-ca.pem"
    SSL_CERT_FILE="/tmp/evil-ca.pem" SSL_CERT_DIR="/tmp/evil-ca" BOTO_CONFIG="/tmp/evil-boto"
    ORIGIN_SMOKE_MODE="standalone" SPOT_BOOTSTRAP_PREFIX="/tmp/evil"
)

current_markers=""
last_root=""
last_status=0

# A fresh sandbox for one case: both markers present, the address on the
# On-Demand host, the group at desired 1 with this host InService. $@: switches.
prepare_case() {
    local case_name="$1"
    shift
    last_root="$work_directory/$case_name"
    rm -rf "$last_root"; mkdir -p "$last_root/run/ec-portfolio-demo"
    build_bundle "$last_root/bundle"
    : >"$last_root/run/ec-portfolio-demo/spot-serving-ready"
    : >"$last_root/run/ec-portfolio-demo/spot-continue-accepted"
    current_markers="$last_root/markers"
    : >"$current_markers"
    rm -f "$state_directory"/*.used "$state_directory"/fail-* "$state_directory"/dry-run-* \
        "$state_directory"/associate-* "$state_directory"/imds-*
    printf '%s\n' "$ON_DEMAND" >"$state_directory/holder"
    printf '1\t1\n' >"$state_directory/asg-answer"
    local switch
    for switch in "$@"; do : >"$state_directory/$switch"; done
}

# Drives the steps main() runs after its root check, against the sandbox.
# Extra VAR=value arguments override the inputs.
run_steps() {
    env PATH="$fake_bin:$PATH" \
        MARKER_FILE="$current_markers" STATE_DIR="$state_directory" \
        INSTANCE_UNDER_TEST="$INSTANCE" OTHER_SPOT="$OTHER_SPOT" \
        SPOT_PROMOTION_PREFIX="$last_root" \
        SPOT_PROMOTION_ATTEMPTS=3 SPOT_PROMOTION_INTERVAL_SECONDS=0 \
        EIP_ALLOCATION_ID="$ALLOCATION" INSTANCE_ID="$INSTANCE" AUTOSCALING_GROUP_NAME="$ASG_NAME" \
        AWS_REGION="ap-northeast-1" \
        "${hostile_env[@]}" \
        "$@" \
        bash -c 'source "$1"; validate_inputs; require_accepted_host; resolve_script_directory;
            verify_instance_identity; run_promotion' \
        _ "$last_root/bundle/promote-origin-eip.sh" >"$last_root/output" 2>&1 &&
        last_status=0 || last_status=$?
    return 0
}

run_case() {
    prepare_case "$@"
    run_steps
}

markers() { tr '\n' ' ' <"$current_markers"; }
marker_count() { local n; n="$(grep -cE "^$1( |\$)" "$current_markers" 2>/dev/null || true)"; printf '%s\n' "${n:-0}"; }
step_order() { grep -oE '^(imds-instance-id|smoke|asg-read|holder-read|dry-run|associate|sleep)( |$)' "$current_markers" | tr -d ' ' | tr '\n' ' '; }
promoted() { [[ -e "$last_root/run/ec-portfolio-demo/spot-eip-promoted" ]]; }
failed_reason() { cat "$last_root/run/ec-portfolio-demo/spot-eip-promotion-failed" 2>/dev/null || true; }

# Asserted after every case: nothing outside the three reads and the
# association was called, no AWS error text reached the output, and no child
# saw the caller's identity, endpoint or seam variables.
assert_case_invariants() {
    local contents name
    contents="$(cat "$current_markers")"
    assert_absent "$contents" "aws-unexpected" "Only the allowlisted AWS operations may run ($1)."
    assert_absent "$contents" "curl-unexpected" "Only IMDS may be fetched ($1)."
    for name in "${IDENTITY_ENV[@]}"; do
        if grep -q "^aws-identity $name=" <<<"$contents"; then
            grep -q "^aws-identity $name=<unset>$" <<<"$contents" ||
                fail "The AWS child must not inherit $name ($1)."
        fi
        if grep -q "^smoke-identity $name=" <<<"$contents"; then
            grep -q "^smoke-identity $name=<unset>$" <<<"$contents" ||
                fail "The smoke child must not inherit $name ($1)."
        fi
    done
    if grep -E '^(aws|smoke)-region ' <<<"$contents" | grep -vqx '.*-region ap-northeast-1/ap-northeast-1'; then
        fail "Every child must be given the Region explicitly ($1)."
    fi
    local output
    output="$(cat "$last_root/output")"
    for leaked in "123456789012" "SECRETENCODED" "leaked-static-key" "is not authorized"; do
        assert_absent "$output" "$leaked" "AWS error text and caller secrets must not reach the output ($1)."
    done
}

# --- R1. the success path, in order -----------------------------------------
run_case success
(( last_status == 0 )) || fail "The promotion must succeed. Output: $(cat "$last_root/output")"
[[ "$(step_order)" == "imds-instance-id smoke asg-read holder-read dry-run associate holder-read " ]] ||
    fail "Promotion step order mismatch: $(step_order)"
promoted || fail "A successful promotion must leave the promoted marker."
[[ "$(cat "$last_root/run/ec-portfolio-demo/spot-eip-promoted")" == "$INSTANCE" ]] ||
    fail "The promoted marker must name this instance."
[[ -z "$(failed_reason)" ]] || fail "A successful promotion must not leave the failure marker."
for call in dry-run associate; do
    line="$(grep "^$call " "$current_markers")"
    for expected in "--allocation-id $ALLOCATION" "--instance-id $INSTANCE" "--allow-reassociation" "--region ap-northeast-1"; do
        assert_contains "$line" "$expected" "The $call must carry $expected."
    done
done
assert_contains "$(grep '^dry-run ' "$current_markers")" "--dry-run" "The first association must be a dry run."
assert_absent "$(grep '^associate ' "$current_markers")" "--dry-run" "The real association must not be a dry run."
assert_contains "$(grep '^holder-read ' "$current_markers" | head -1)" "--allocation-ids $ALLOCATION" \
    "The holder must be read for the exact allocation."
assert_contains "$(grep '^asg-read ' "$current_markers")" "--auto-scaling-group-names $ASG_NAME" \
    "The group check must read the exact group."
assert_contains "$(cat "$current_markers")" "smoke-server-name=origin-demo.yoonec.dev" \
    "The smoke check must be pointed at the origin host name."
assert_case_invariants success

# --- R2. already the holder: nothing is associated ---------------------------
prepare_case already-holder
printf '%s\n' "$INSTANCE" >"$state_directory/holder"
run_steps
(( last_status == 0 )) || fail "A host that already holds the address must succeed."
(( $(marker_count dry-run) + $(marker_count associate) == 0 )) ||
    fail "A host that already holds the address must not call associate-address: $(markers)"
promoted || fail "A host that already holds the address must record the promoted marker."
assert_case_invariants already-holder

# --- R3. no accepted host, no call at all ------------------------------------
for marker in spot-serving-ready spot-continue-accepted; do
    prepare_case "missing-$marker"
    rm -f "$last_root/run/ec-portfolio-demo/$marker"
    run_steps
    (( last_status != 0 )) || fail "Without $marker the promotion must fail."
    [[ -z "$(grep -E '^(imds|smoke|asg-read|holder-read|dry-run|associate)' "$current_markers")" ]] ||
        fail "Without $marker nothing may be called: $(markers)"
done

# --- R4. the address only goes to the instance this runs on ------------------
for switch in imds-other-instance fail-imds; do
    run_case "imds-$switch" "$switch"
    (( last_status != 0 )) || fail "$switch must stop the promotion."
    [[ -z "$(grep -E '^(smoke|asg-read|holder-read|dry-run|associate)' "$current_markers")" ]] ||
        fail "$switch must stop the promotion before any AWS call: $(markers)"
done

# --- R5. a host whose origin does not serve is not promoted ------------------
run_case smoke-fails fail-smoke
(( last_status != 0 )) || fail "A failing smoke check must fail the promotion."
(( $(marker_count smoke) == 3 )) || fail "The smoke check must be tried three times: $(markers)"
(( $(marker_count asg-read) + $(marker_count holder-read) + $(marker_count dry-run) + $(marker_count associate) == 0 )) ||
    fail "A failing smoke check must prevent every AWS call: $(markers)"
[[ "$(failed_reason)" == "origin-smoke-failed" ]] || fail "The failure marker must say origin-smoke-failed (got $(failed_reason))."
promoted && fail "A failed promotion must not leave the promoted marker."
assert_case_invariants smoke-fails

run_case smoke-fails-once fail-smoke-once
(( last_status == 0 )) || fail "One failed smoke check must be retried and then promote."
(( $(marker_count associate) == 1 )) || fail "A retried promotion must associate exactly once."

# --- R6. a group that does not want this host is final -----------------------
for answer in "0	0" "0	1" "1	0" "2	0"; do
    prepare_case "group-$(tr '\t' '-' <<<"$answer")"
    printf '%s\n' "$answer" >"$state_directory/asg-answer"
    run_steps
    (( last_status != 0 )) || fail "Group answer '$answer' must stop the promotion."
    (( $(marker_count holder-read) + $(marker_count dry-run) + $(marker_count associate) == 0 )) ||
        fail "Group answer '$answer' must stop before the address is read or moved: $(markers)"
    (( $(marker_count asg-read) == 1 )) || fail "Group answer '$answer' is final and must not be retried."
    [[ "$(failed_reason)" == "group-does-not-want-this-host" ]] ||
        fail "Group answer '$answer' must be recorded as group-does-not-want-this-host (got $(failed_reason))."
done
for answer in "" "None" "one	1"; do
    prepare_case group-unreadable
    printf '%s\n' "$answer" >"$state_directory/asg-answer"
    run_steps
    (( last_status != 0 )) || fail "An unreadable group answer '$answer' must not promote."
    (( $(marker_count dry-run) + $(marker_count associate) == 0 )) ||
        fail "An unreadable group answer '$answer' must not move the address."
done
run_case group-read-once fail-asg-read-once
(( last_status == 0 )) || fail "A transient group read failure must be retried."
(( $(marker_count asg-read) == 2 )) || fail "The group read must be retried once: $(markers)"

# --- R7. the dry run decides --------------------------------------------------
run_case dry-run-unauthorized dry-run-unauthorized
(( last_status != 0 )) || fail "An unauthorized dry run must stop the promotion."
(( $(marker_count associate) == 0 )) || fail "An unauthorized dry run must never be followed by an association."
(( $(marker_count dry-run) == 1 )) || fail "An unauthorized dry run is final and must not be retried."
[[ "$(failed_reason)" == "dry-run-unauthorized" ]] || fail "The failure marker must say dry-run-unauthorized."
assert_case_invariants dry-run-unauthorized

run_case dry-run-succeeds dry-run-succeeds
(( last_status != 0 )) || fail "A dry run that does not answer DryRunOperation must stop the promotion."
(( $(marker_count associate) == 0 )) || fail "Only DryRunOperation may lead to an association."

run_case dry-run-throttled-once dry-run-throttle-once
(( last_status == 0 )) || fail "A throttled dry run must be retried."
(( $(marker_count dry-run) == 2 && $(marker_count associate) == 1 )) ||
    fail "A throttled dry run must be retried once and then associate once: $(markers)"

# --- R8. the association and its verification ---------------------------------
run_case associate-fails-once associate-fail-once
(( last_status == 0 )) || fail "A failed association must be retried."
(( $(marker_count associate) == 2 )) || fail "The association must be retried once: $(markers)"
(( $(marker_count dry-run) == 2 )) || fail "Every attempt must dry-run before it associates."

run_case associate-fails associate-fail
(( last_status != 0 )) || fail "An association that keeps failing must fail the promotion."
(( $(marker_count associate) == 3 )) || fail "The association must be tried three times: $(markers)"
(( $(marker_count sleep) == 2 )) || fail "Three attempts need exactly two waits."
[[ "$(failed_reason)" == "associate-failed" ]] || fail "The failure marker must say associate-failed."
assert_case_invariants associate-fails

run_case associate-unauthorized associate-unauthorized
(( last_status != 0 )) || fail "An unauthorized association must fail the promotion."
(( $(marker_count associate) == 1 )) || fail "An unauthorized association is final and must not be retried."

run_case associate-no-effect associate-no-effect
(( last_status != 0 )) || fail "An association that did not move the address must fail the promotion."
[[ "$(failed_reason)" == "holder-is-not-this-instance" ]] ||
    fail "The failure marker must say holder-is-not-this-instance (got $(failed_reason))."
promoted && fail "An unverified association must not leave the promoted marker."

run_case holder-read-fails fail-holder-read
(( last_status != 0 )) || fail "An unreadable holder must fail the promotion."
(( $(marker_count dry-run) + $(marker_count associate) == 0 )) || fail "An unreadable holder must not move the address."

# --- R9. once promoted since boot, never again ---------------------------------
prepare_case already-promoted
printf '%s\n' "$INSTANCE" >"$last_root/run/ec-portfolio-demo/spot-eip-promoted"
run_steps
(( last_status == 0 )) || fail "A host that already promoted itself must exit 0."
[[ -z "$(grep -E '^(smoke|asg-read|holder-read|dry-run|associate)' "$current_markers")" ]] ||
    fail "A host that already promoted itself must call nothing: $(markers)"

# --- R10. inputs ------------------------------------------------------------------
valid_inputs=(EIP_ALLOCATION_ID="$ALLOCATION" INSTANCE_ID="$INSTANCE" AUTOSCALING_GROUP_NAME="$ASG_NAME")
env -u AWS_REGION -u AWS_DEFAULT_REGION PATH="$fake_bin:$PATH" "${valid_inputs[@]}" \
    bash -c 'source "$1"; validate_inputs' _ "$PROMOTION_SCRIPT" >/dev/null 2>&1 ||
    fail "validate_inputs must accept the valid inputs (positive control)."
for bad_env in "EIP_ALLOCATION_ID=" "EIP_ALLOCATION_ID=eipalloc-XYZ" "EIP_ALLOCATION_ID=$INSTANCE" \
    "EIP_ALLOCATION_ID=$ALLOCATION extra" "INSTANCE_ID=" "INSTANCE_ID=i-XYZ" \
    "AUTOSCALING_GROUP_NAME=" "AUTOSCALING_GROUP_NAME=bad name" "AWS_REGION=us-east-1"; do
    if env -u AWS_REGION -u AWS_DEFAULT_REGION PATH="$fake_bin:$PATH" "${valid_inputs[@]}" "$bad_env" \
        bash -c 'source "$1"; validate_inputs' _ "$PROMOTION_SCRIPT" >/dev/null 2>&1; then
        fail "validate_inputs must reject: $bad_env"
    fi
done

# --- R11. the sandbox prefix cannot be used against a real host ---------------
direct_output="$(env PATH="$fake_bin:$PATH" SPOT_PROMOTION_PREFIX="$work_directory/hijack" \
    "${valid_inputs[@]}" bash "$PROMOTION_SCRIPT" 2>&1)" && direct_status=0 || direct_status=$?
(( direct_status != 0 )) || fail "Executing the script with SPOT_PROMOTION_PREFIX set must fail."
assert_contains "$direct_output" "test seam" "The refusal must say the prefix is a test seam."

printf '[eip-promotion-test] PASS\n'
