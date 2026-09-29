#!/usr/bin/env bash

# Behaviour tests for the launch template's user-data loader.
#
# The template is rendered the way templatefile() renders it -- each ${name}
# replaced by a value -- and the result is run for real, with IMDS, S3 and Auto
# Scaling replaced by recording fakes. What is asserted:
#
#   - user data never starts, polls or waits for the ECS agent or the API task;
#   - it runs the bootstrap's pre phase and hands it the lifecycle identity;
#   - it reports ABANDON when anything before the hand-over fails, and nothing
#     at all when the pre phase succeeds, because the post unit owns CONTINUE;
#   - rendered with the longest possible values, it fits the 16 KiB raw
#     user-data limit, the bound the Terraform precondition also enforces.
#
# No AWS, no root. Runs under bash 3.2 and bash 5.

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly LOADER_TEMPLATE="$SCRIPT_DIRECTORY/../../terraform/demo/templates/ecs-spot-user-data.sh.tftpl"
readonly INSTANCE="i-0123456789abcdef0"
readonly ASG_NAME="ec-portfolio-demo-ecs-spot"
readonly HOOK_NAME="ec-portfolio-demo-ecs-spot-launching"
readonly CLUSTER="ec-portfolio-demo"
readonly ORIGIN_BUCKET="ec-portfolio-demo-origin-tls-776c2eab754b36a00164763604"

work_directory=""

cleanup_tests() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-spot-loader-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup_tests EXIT

fail() {
    printf '[spot-loader-test] FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "$3 (expected to find: $2)"
}

assert_absent() {
    [[ "$1" != *"$2"* ]] || fail "$3 (unexpectedly found: $2)"
}

work_directory="$(mktemp -d /tmp/ec-portfolio-spot-loader-test.XXXXXX)"
template="$(cat "$LOADER_TEMPLATE")"

# templatefile() with the eleven variables compute_spot.tf passes. Any ${...}
# left afterwards is a variable the test does not know about, which would be a
# template error in Terraform as well.
#
# The placeholder is held in a variable rather than quoted inline: bash 3.2 and
# bash 5 disagree on quotes inside a double-quoted ${var//pattern/...}, and
# none of $, { or } is a pattern metacharacter, so the variable matches
# literally in both.
render() {
    local text="$template" placeholder index=0 value
    local names="aws_region runtime_bucket runtime_object_key runtime_object_version_id
        runtime_archive_sha256 runtime_directory archive_path ecs_cluster_name
        origin_tls_bucket autoscaling_group_name lifecycle_hook_name"
    local -a values=("$@")
    (( ${#values[@]} == 11 )) || fail "render needs 11 values."
    for placeholder in $names; do
        value="${values[$index]}"
        placeholder="\${$placeholder}"
        text=${text//$placeholder/$value}
        index=$((index + 1))
    done
    [[ "$text" != *'${'* && "$text" != *'%{'* ]] || fail "The template has an interpolation this suite does not render."
    printf '%s\n' "$text"
}

# ---------------------------------------------------------------------------
# 1. Static: user data waits for nothing ECS
# ---------------------------------------------------------------------------

code="$(sed -e 's/^[[:space:]]*#.*$//' <<<"$template")"
for forbidden in "systemctl" "51678" "8080" "readiness" "ecs.service" "wait_for_"; do
    assert_absent "$code" "$forbidden" \
        "User data must not start, poll or wait for the ECS agent or the API task: $forbidden"
done
if grep -qE 'complete_lifecycle_action[[:space:]]+CONTINUE' <<<"$code"; then
    fail "User data must never report CONTINUE; the post-bootstrap unit owns it."
fi
assert_contains "$code" '"$RUNTIME_DIRECTORY/bootstrap-spot-host.sh" pre' \
    "User data must run the bootstrap's pre phase."

# ---------------------------------------------------------------------------
# 2. Size: the longest rendering fits 16 KiB
# ---------------------------------------------------------------------------

# The same placeholders compute_spot.tf uses for its precondition -- a 63-byte
# bucket name and a 1024-byte version ID -- plus the origin bucket at its
# maximum as well, and the real paths and names.
upper_bound="$(render ap-northeast-1 "$(printf '%063d' 0)" runtime/spot-runtime.tar.gz \
    "$(printf '%01024d' 0)" "$(printf '%064d' 0)" /opt/ec-portfolio/runtime/demo \
    /run/ec-portfolio-demo-spot-runtime.tar.gz "$CLUSTER" "$(printf '%063d' 0)" \
    "$ASG_NAME" "$HOOK_NAME")"
upper_bytes="$(printf '%s\n' "$upper_bound" | wc -c | tr -d ' ')"
(( upper_bytes <= 16384 )) ||
    fail "The rendered loader can reach $upper_bytes bytes, above the 16 KiB raw user-data limit."
printf '[spot-loader-test] rendered upper bound: %s of 16384 bytes\n' "$upper_bytes"

# ---------------------------------------------------------------------------
# 3. Behavioural harness
# ---------------------------------------------------------------------------

fake_bin="$work_directory/bin"
state="$work_directory/state"
mkdir -p "$fake_bin" "$state"
real_tar="$(command -v tar)"

make_fake() {
    local name="$1" body="$2"
    cat >"$fake_bin/$name" <<FAKE
#!/usr/bin/env bash
$body
FAKE
    chmod 755 "$fake_bin/$name"
}

# IMDSv2: a token, then the instance ID.
make_fake curl '
[[ -e "$STATE/fail-imds" ]] && exit 22
for arg in "$@"; do
    case "$arg" in
        */api/token) printf "test-token"; exit 0 ;;
        */meta-data/instance-id) printf "%s" "$TEST_INSTANCE_ID"; exit 0 ;;
    esac
done
exit 22'

# S3 and Auto Scaling. get-object writes the prepared archive to its last
# argument; complete-lifecycle-action records its result.
make_fake aws '
printf "aws %s\n" "$*" >>"$STATE/calls"
case "$*" in
    *"s3api get-object"*)
        [[ -e "$STATE/fail-download" ]] && exit 255
        cp "$STATE/archive.tar.gz" "${!#}"; exit 0 ;;
    *"autoscaling complete-lifecycle-action"*)
        result=""; previous=""
        for arg in "$@"; do
            [[ "$previous" == "--lifecycle-action-result" ]] && result="$arg"
            previous="$arg"
        done
        printf "lifecycle-%s\n" "$result" >>"$STATE/calls"; exit 0 ;;
esac
exit 0'

make_fake timeout '
while [[ "$1" == --* ]]; do shift; done
shift
exec "$@"'

make_fake install '
dirs=""
while [ $# -gt 0 ]; do
    case "$1" in
        -d) shift ;;
        -o|-g|-m) shift 2 ;;
        *) dirs="$dirs $1"; shift ;;
    esac
done
mkdir -p $dirs'

# The loader uses GNU long options; map them onto the short ones every tar
# accepts, so the suite runs on the BSD tar of a developer machine too.
cat >"$fake_bin/tar" <<TAR
#!/usr/bin/env bash
args=()
while (( \$# > 0 )); do
    case "\$1" in
        --extract) args+=(-x); shift ;;
        --gzip) args+=(-z); shift ;;
        --no-same-owner) args+=(--no-same-owner); shift ;;
        --file) args+=(-f "\$2"); shift 2 ;;
        --directory) args+=(-C "\$2"); shift 2 ;;
        *) args+=("\$1"); shift ;;
    esac
done
exec "$real_tar" "\${args[@]}"
TAR
chmod 755 "$fake_bin/tar"

# The bundle the loader downloads: a stand-in bootstrap that records how it was
# called, and every other listed file. Its content is irrelevant here; the
# archive checksum the loader demands is computed from it.
build_archive() {
    local staging="$work_directory/staging" name
    rm -rf "$staging"; mkdir -p "$staging"
    cat >"$staging/bootstrap-spot-host.sh" <<'STUB'
#!/usr/bin/env bash
{
    printf 'bootstrap-args %s\n' "$*"
    for name in ECS_CLUSTER_NAME ORIGIN_TLS_BUCKET AUTOSCALING_GROUP_NAME LIFECYCLE_HOOK_NAME \
        INSTANCE_ID AWS_REGION AWS_DEFAULT_REGION SPOT_BOOTSTRAP_PREFIX; do
        printf 'bootstrap-env %s=%s\n' "$name" "${!name-<unset>}"
    done
} >>"$STATE/calls"
[[ -e "$STATE/fail-pre" ]] && exit 1
exit 0
STUB
    for name in $(sed -n 's/^readonly BUNDLE_EXECUTABLES="\(.*\)"$/\1/p; s/^readonly BUNDLE_DATA_FILES="\(.*\)"$/\1/p' "$LOADER_TEMPLATE"); do
        [[ "$name" == bootstrap-spot-host.sh ]] && continue
        [[ -e "$state/omit-$name" ]] && continue
        : >"$staging/$name"
    done
    chmod 0400 "$staging"/*
    ( cd "$staging" && "$real_tar" -czf "$state/archive.tar.gz" -- * )
}

# Renders the loader for the sandbox and runs it. $@: switch files.
run_loader() {
    rm -rf "$state"; mkdir -p "$state"
    local switch
    for switch in "$@"; do : >"$state/$switch"; done
    build_archive
    local digest
    digest="$(sha256sum -- "$state/archive.tar.gz" | awk '{ print $1 }')"
    [[ -e "$state/wrong-sha" ]] && digest="$(printf '%064d' 1)"

    runtime="$work_directory/opt/ec-portfolio/runtime/demo"
    rm -rf "$work_directory/opt"
    render ap-northeast-1 ec-portfolio-demo-runtime-artifacts-test runtime/spot-runtime.tar.gz \
        test-version-id "$digest" "$runtime" "$work_directory/run-archive.tar.gz" \
        "$CLUSTER" "$ORIGIN_BUCKET" "$ASG_NAME" "$HOOK_NAME" >"$work_directory/loader.sh"

    # A hostile seam in the environment: the loader must not pass it on.
    env PATH="$fake_bin:$PATH" STATE="$state" TEST_INSTANCE_ID="$INSTANCE" \
        SPOT_BOOTSTRAP_PREFIX="/tmp/hijack" \
        bash "$work_directory/loader.sh" >"$state/output" 2>&1 && loader_status=0 || loader_status=$?
    calls="$(cat "$state/calls" 2>/dev/null || true)"
}

lifecycle_count() {
    grep -c "^lifecycle-$1\$" <<<"$calls" || true
}

loader_status=0
calls=""

# --- L1. success: the pre phase runs, and the loader reports nothing --------
run_loader
(( loader_status == 0 )) || fail "The loader must exit 0 when the pre phase succeeds. Output: $(cat "$state/output")"
assert_contains "$calls" "bootstrap-args pre" "The loader must run the bootstrap's pre phase."
for expected in "ECS_CLUSTER_NAME=$CLUSTER" "ORIGIN_TLS_BUCKET=$ORIGIN_BUCKET" \
    "AUTOSCALING_GROUP_NAME=$ASG_NAME" "LIFECYCLE_HOOK_NAME=$HOOK_NAME" \
    "INSTANCE_ID=$INSTANCE" "AWS_REGION=ap-northeast-1" "AWS_DEFAULT_REGION=ap-northeast-1" \
    "SPOT_BOOTSTRAP_PREFIX=<unset>"; do
    assert_contains "$calls" "bootstrap-env $expected" "The pre phase must receive $expected."
done
if grep -q "complete-lifecycle-action" <<<"$calls"; then
    fail "The loader must not report anything when the pre phase succeeds: $calls"
fi
assert_contains "$calls" "--version-id test-version-id" "The download must be version-pinned."

# The loader's mode step: scripts executable, data files not.
for name in $(sed -n 's/^readonly BUNDLE_EXECUTABLES="\(.*\)"$/\1/p' "$LOADER_TEMPLATE"); do
    [[ -x "$runtime/$name" ]] || fail "The loader must make $name executable."
done
for name in $(sed -n 's/^readonly BUNDLE_DATA_FILES="\(.*\)"$/\1/p' "$LOADER_TEMPLATE"); do
    [[ -f "$runtime/$name" && ! -x "$runtime/$name" ]] || fail "The loader must set $name as a data file."
done

# --- L2. a failed pre phase is abandoned, exactly once ----------------------
run_loader fail-pre
(( loader_status != 0 )) || fail "A failed pre phase must fail the loader."
(( $(lifecycle_count ABANDON) == 1 )) || fail "A failed pre phase must report ABANDON exactly once: $calls"
(( $(lifecycle_count CONTINUE) == 0 )) || fail "The loader must never report CONTINUE."
assert_contains "$calls" "--instance-id $INSTANCE" "ABANDON must name this instance."

# --- L3. the failures before the pre phase are abandoned too ---------------
for failure in wrong-sha fail-download omit-imds-guard.sh omit-ec-portfolio-spot-post-bootstrap.service; do
    run_loader "$failure"
    (( loader_status != 0 )) || fail "The loader must fail on $failure."
    (( $(lifecycle_count ABANDON) == 1 )) || fail "$failure must report ABANDON exactly once: $calls"
    if grep -q "bootstrap-args" <<<"$calls"; then
        fail "$failure must stop the loader before it runs the bootstrap."
    fi
done

# --- L4. without an instance ID nothing can be reported --------------------
run_loader fail-imds
(( loader_status != 0 )) || fail "The loader must fail when IMDS is unreachable."
if grep -q "complete-lifecycle-action" <<<"$calls"; then
    fail "Without an instance ID the loader must leave the hook to its ABANDON default."
fi

printf '[spot-loader-test] PASS\n'
