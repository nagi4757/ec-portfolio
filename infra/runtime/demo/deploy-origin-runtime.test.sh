#!/usr/bin/env bash

# Behaviour tests for deploy-origin-runtime.sh.
#
# The source side runs against a throwaway git repository with a local bare
# remote, so the origin/main check works offline. The host side is proved by
# rendering the real SSM command list and executing it against a sandbox in
# place of /opt/ec-portfolio/runtime/demo/origin: install, chown and mv are thin
# stubs that drop the root-only parts, everything else is the real payload. aws
# is a stub; no request leaves the machine.

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly DEPLOY_SCRIPT="$SCRIPT_DIRECTORY/deploy-origin-runtime.sh"
readonly REMOTE_ROOT="/opt/ec-portfolio/runtime/demo/origin"

work_directory=""

cleanup_tests() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-origin-deploy-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup_tests EXIT

fail() {
    printf '[origin-deploy-test] FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "$3 (expected to find: $2)"
}

mode_of() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

work_directory="$(mktemp -d /tmp/ec-portfolio-origin-deploy-test.XXXXXX)"
readonly STUB_BIN="$work_directory/bin"
mkdir -p "$STUB_BIN"

# --- stubs for the root-only host operations ----------------------------------
cat >"$STUB_BIN/sha256sum" <<'STUB'
#!/usr/bin/env bash
exec shasum -a 256 "$@"
STUB
cat >"$STUB_BIN/chown" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
cat >"$STUB_BIN/install" <<'STUB'
#!/usr/bin/env bash
arguments=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o | -g) shift 2 ;;
        *) arguments+=("$1"); shift ;;
    esac
done
exec /usr/bin/install "${arguments[@]}"
STUB
# GNU mv -T renames a directory onto a path that does not exist or is an empty
# directory, and refuses a directory with content. BSD mv has no -T.
cat >"$STUB_BIN/mv" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "-T" ]]; then
    if [[ -e "$3" || -L "$3" ]]; then
        if [[ -d "$3" && ! -L "$3" && -z "$(ls -A "$3")" ]]; then
            rmdir "$3"
        else
            echo "mv: cannot move '$2' to '$3': Directory not empty" >&2
            exit 1
        fi
    fi
    exec /bin/mv "$2" "$3"
fi
exec /bin/mv "$@"
STUB
chmod 755 "$STUB_BIN"/*

# --- fixture repository ---------------------------------------------------------
readonly REMOTE_REPOSITORY="$work_directory/remote.git"
readonly CLONE="$work_directory/clone"
git init -q --bare "$REMOTE_REPOSITORY"
git init -q "$CLONE"
git -C "$CLONE" config user.email test@example.invalid
git -C "$CLONE" config user.name test
git -C "$CLONE" checkout -q -b main
mkdir -p "$CLONE/infra/runtime/demo"
printf '#!/usr/bin/env bash\necho configure\n' >"$CLONE/infra/runtime/demo/configure-origin.sh"
printf '#!/usr/bin/env bash\necho smoke\n' >"$CLONE/infra/runtime/demo/origin-smoke-check.sh"
git -C "$CLONE" add -A && git -C "$CLONE" commit -q -m "without the rotation check"
readonly INCOMPLETE_SHA="$(git -C "$CLONE" rev-parse HEAD)"
printf '#!/usr/bin/env bash\necho rotation\n' >"$CLONE/infra/runtime/demo/origin-token-rotation-check.sh"
git -C "$CLONE" add -A && git -C "$CLONE" commit -q -m "release"
readonly RELEASE_SHA="$(git -C "$CLONE" rev-parse HEAD)"
git -C "$CLONE" remote add origin "$REMOTE_REPOSITORY"
git -C "$CLONE" push -q origin main

# Runs a snippet with the deploy script's functions, bound to the fixture.
with_script() {
    local sha="$1" snippet="$2"
    bash -c 'set -euo pipefail; source "$1"; repository_root="$2"; SOURCE_SHA="$3"; eval "$4"' \
        _ "$DEPLOY_SCRIPT" "$CLONE" "$sha" "$snippet"
}

render_payload() {
    local sha="$1" sandbox="$2"
    with_script "$sha" 'collect_artifacts; build_origin_install_commands' |
        jq -r '.[]' | sed "s|$REMOTE_ROOT|$sandbox/origin|g"
}

run_payload() {
    payload_status=0
    payload_output="$(PATH="$STUB_BIN:$PATH" bash "$1" 2>&1)" || payload_status=$?
}

# --- 1. the source must be exactly origin/main ----------------------------------
with_script "$RELEASE_SHA" verify_source_sha >/dev/null 2>&1 || fail "origin/main itself must be accepted."
status=0
output="$(with_script "$INCOMPLETE_SHA" verify_source_sha 2>&1)" || status=$?
((status != 0)) || fail "A commit that is not origin/main must be refused."
assert_contains "$output" "is not origin/main" "The refusal must say why."
status=0
with_script "abc123" verify_source_sha >/dev/null 2>&1 || status=$?
((status != 0)) || fail "An abbreviated SHA must be refused."
status=0
output="$(with_script "$INCOMPLETE_SHA" collect_artifacts 2>&1)" || status=$?
((status != 0)) || fail "A release missing an artifact must be refused."
assert_contains "$output" "origin-token-rotation-check.sh does not exist" "The missing artifact must be named."

# --- 2. a fresh install publishes the complete release, privately ---------------
sandbox="$work_directory/host-1"
mkdir -p "$sandbox"
render_payload "$RELEASE_SHA" "$sandbox" >"$work_directory/payload.sh"
run_payload "$work_directory/payload.sh"
((payload_status == 0)) || fail "A fresh install must succeed: $payload_output"
release="$sandbox/origin/$RELEASE_SHA"
for name in configure-origin.sh origin-smoke-check.sh origin-token-rotation-check.sh; do
    cmp -s "$release/$name" "$CLONE/infra/runtime/demo/$name" || fail "$name must be the committed content."
    [[ "$(mode_of "$release/$name")" == "700" ]] || fail "$name must be readable and executable by root only."
done
[[ "$(mode_of "$release")" == "700" ]] || fail "The release directory must be private to root."
[[ -z "$(find "$sandbox/origin" -maxdepth 1 -name '.staging.*')" ]] || fail "No staging directory may be left behind."
assert_contains "$payload_output" "Installed release $RELEASE_SHA" "The install must be reported."

# --- 3. installing the same release again verifies and changes nothing ----------
before="$(ls -l "$release")"
run_payload "$work_directory/payload.sh"
((payload_status == 0)) || fail "Re-installing the verified release must succeed: $payload_output"
assert_contains "$payload_output" "already installed and verified; nothing changed" "The no-op must be reported."
[[ "$(ls -l "$release")" == "$before" ]] || fail "An installed release must not be modified."

# --- 4. an installed release that differs is never overwritten ------------------
printf 'tampered\n' >>"$release/configure-origin.sh"
run_payload "$work_directory/payload.sh"
((payload_status != 0)) || fail "A modified installed release must stop the install."
assert_contains "$payload_output" "refusing to overwrite" "The refusal must say why."
grep -q '^tampered$' "$release/configure-origin.sh" || fail "The existing file must be left exactly as found."

sandbox="$work_directory/host-2"
mkdir -p "$sandbox/origin/$RELEASE_SHA"
touch "$sandbox/origin/$RELEASE_SHA/unexpected"
render_payload "$RELEASE_SHA" "$sandbox" >"$work_directory/payload-2.sh"
run_payload "$work_directory/payload-2.sh"
((payload_status != 0)) || fail "A release directory with other content must stop the install."
assert_contains "$payload_output" "does not hold exactly the reviewed files" "The refusal must say why."

sandbox="$work_directory/host-3"
mkdir -p "$sandbox/origin" "$work_directory/elsewhere"
ln -s "$work_directory/elsewhere" "$sandbox/origin/$RELEASE_SHA"
render_payload "$RELEASE_SHA" "$sandbox" >"$work_directory/payload-3.sh"
run_payload "$work_directory/payload-3.sh"
((payload_status != 0)) || fail "A symlinked release path must stop the install."
[[ -z "$(ls -A "$work_directory/elsewhere")" ]] || fail "Nothing may be written through a symlink."

# --- 5. a payload that does not match its checksum installs nothing -------------
sandbox="$work_directory/host-4"
mkdir -p "$sandbox"
render_payload "$RELEASE_SHA" "$sandbox" |
    sed "s|^payload_1='.*'$|payload_1='$(printf 'not the reviewed file\n' | base64 | tr -d '\n')'|" \
        >"$work_directory/payload-4.sh"
run_payload "$work_directory/payload-4.sh"
((payload_status != 0)) || fail "A tampered payload must be refused."
assert_contains "$payload_output" "origin-smoke-check.sh checksum mismatch; nothing was installed" \
    "The tampered artifact must be named."
[[ ! -e "$sandbox/origin" ]] || fail "Nothing may be created on the host before every checksum passes."

# --- 6. deploy: Online gate, one instance, and the command outcome --------------
cat >"$STUB_BIN/aws" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$AWS_LOG"
case "$*" in
    *"describe-instance-information"*) cat "$AWS_FIXTURES/ping" ;;
    *"send-command"*) echo "command-0001" ;;
    *"get-command-invocation"*) cat "$AWS_FIXTURES/invocation" ;;
esac
STUB
chmod 755 "$STUB_BIN/aws"
export AWS_LOG="$work_directory/aws.log" AWS_FIXTURES="$work_directory/aws"
mkdir -p "$AWS_FIXTURES"

run_deploy() {
    : >"$AWS_LOG"
    deploy_status=0
    deploy_output="$(PATH="$STUB_BIN:$PATH" EC2_INSTANCE_ID="i-0123456789abcdef0" ORIGIN_DEPLOY_POLL_INTERVAL_SECONDS=0 \
        bash -c 'set -euo pipefail; source "$1"; repository_root="$2"; SOURCE_SHA="$3"; collect_artifacts; deploy' \
        _ "$DEPLOY_SCRIPT" "$CLONE" "$RELEASE_SHA" 2>&1)" || deploy_status=$?
}

printf 'ConnectionLost\n' >"$AWS_FIXTURES/ping"
run_deploy
((deploy_status != 0)) || fail "A host that is not Online must fail the install."
[[ "$(cat "$AWS_LOG")" != *send-command* ]] || fail "Nothing may be sent to a host that is not Online."

printf 'Online\n' >"$AWS_FIXTURES/ping"
printf '{"Status":"Success","StandardOutputContent":"Installed release x"}\n' >"$AWS_FIXTURES/invocation"
run_deploy
((deploy_status == 0)) || fail "A successful command must succeed: $deploy_output"
send_call="$(grep send-command "$AWS_LOG")"
assert_contains "$send_call" "--instance-ids i-0123456789abcdef0" "The command must target exactly one instance."
assert_contains "$send_call" "--document-name AWS-RunShellScript" "The command must use AWS-RunShellScript."

printf '{"Status":"Failed","StandardErrorContent":"refusing to overwrite"}\n' >"$AWS_FIXTURES/invocation"
run_deploy
((deploy_status != 0)) || fail "A failed host command must fail the install."
assert_contains "$deploy_output" "refusing to overwrite" "The host error must be shown."

# --- 7. static contract --------------------------------------------------------------
payload="$(cat "$work_directory/payload.sh")"
for forbidden in "get-parameter" "with-decryption" "TF_VAR_" "rm -rf -- \"\$target\""; do
    [[ "$payload" != *"$forbidden"* ]] || fail "The payload must not contain: $forbidden"
done
script_contents="$(cat "$DEPLOY_SCRIPT")"
assert_contains "$script_contents" 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' "main must only run when executed."

printf '[origin-deploy-test] PASS\n'
