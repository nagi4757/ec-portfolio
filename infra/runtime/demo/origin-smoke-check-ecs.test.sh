#!/usr/bin/env bash

# Behaviour tests for the ECS host origin smoke check.
#
# Everything runs against fakes in a sandbox. No AWS call, no Nginx, no real
# listening socket, and the production /etc/letsencrypt is never touched. The
# fakes record what they were asked so the contract is checked by observation
# rather than by grepping the source.

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SMOKE_SCRIPT="$SCRIPT_DIRECTORY/origin-smoke-check-ecs.sh"
readonly HOST="origin-demo.yoonec.dev"
readonly TOKEN="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAbbbb"

work_directory=""

cleanup_tests() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-smoke-ecs-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup_tests EXIT

fail() {
    printf '[origin-smoke-ecs-test] FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "$3 (expected to find: $2)"
}

assert_absent() {
    [[ "$1" != *"$2"* ]] || fail "$3 (unexpectedly found: $2)"
}

work_directory="$(mktemp -d /tmp/ec-portfolio-smoke-ecs-test.XXXXXX)"
fake_bin="$work_directory/bin"
mkdir -p "$fake_bin"

# The fake answers per address family, the way the real ss does. Each case
# describes a host with three files: the combined listing used for the 443/80
# origin contract, and one listing per family used for the task ports.
ss_state="$work_directory/ss-all"
ss_state4="$work_directory/ss-v4"
ss_state6="$work_directory/ss-v6"
cat >"$fake_bin/ss" <<FAKESS
#!/usr/bin/env bash
family=all
port=""
for arg in "\$@"; do
    case "\$arg" in
        -H*4*|*4) [[ "\$arg" == -* ]] && family=v4 ;;
    esac
done
for arg in "\$@"; do
    case "\$arg" in
        -*6*) family=v6 ;;
        -*4*) family=v4 ;;
        "sport = :"*) port="\${arg##*:}" ;;
    esac
done
case "\$family" in
    v4) src="$ss_state4" ;;
    v6) src="$ss_state6" ;;
    *)  src="$ss_state" ;;
esac
if [[ -n "\$port" ]]; then
    grep -E "[.:]\$port " "\$src" 2>/dev/null || true
else
    cat "\$src" 2>/dev/null || true
fi
FAKESS

cat >"$fake_bin/systemctl" <<'FAKESYSTEMCTL'
#!/usr/bin/env bash
[[ "${FAKE_NGINX_ACTIVE:-true}" == "true" ]] && exit 0
exit 3
FAKESYSTEMCTL

cat >"$fake_bin/aws" <<FAKEAWS
#!/usr/bin/env bash
printf '%s\n' "$TOKEN"
FAKEAWS

# Records the request it was given, so header handling can be asserted without
# the token ever being printed by the script under test.
curl_log="$work_directory/curl.log"
cat >"$fake_bin/curl" <<FAKECURL
#!/usr/bin/env bash
mode=none
output=""
config=""
while (( \$# )); do
    case "\$1" in
        --header) [[ "\$2" == *invalid* ]] && mode=invalid; shift 2 ;;
        --config) config="\$2"; mode=valid; shift 2 ;;
        --output) output="\$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf 'request mode=%s\n' "\$mode" >>"$curl_log"
if [[ -n "\$config" ]]; then
    printf 'config-perms=%s\n' "\$(stat -c %a "\$config" 2>/dev/null || stat -f %Lp "\$config")" >>"$curl_log"
fi
case "\$mode" in
    none|invalid) [[ -n "\$output" ]] && printf 'forbidden\n' >"\$output"; printf '403' ;;
    valid) [[ -n "\$output" ]] && printf '{"status":"UP"}\n' >"\$output"; printf '200' ;;
esac
FAKECURL

cat >"$fake_bin/timeout" <<'FAKETIMEOUT'
#!/usr/bin/env bash
while [[ "$1" == --* ]]; do shift; done
shift
exec "$@"
FAKETIMEOUT

# The script creates its secret-holding directory under /run, which is a tmpfs
# on the hosts it runs on and does not exist on every developer machine. The
# fake keeps the production path untouched and hands back a sandbox directory
# with the same permissions, so the 0600 assertion below still means something.
real_mktemp="$(command -v mktemp)"
cat >"$fake_bin/mktemp" <<FAKEMKTEMP
#!/usr/bin/env bash
# The real binary is addressed by absolute path: the fake is first on PATH, so
# a bare "mktemp" here would call itself.
if [[ "\$1" == "-d" ]]; then
    d="\$("$real_mktemp" -d "$work_directory/runtime.XXXXXX")"
    chmod 700 "\$d"
    printf '%s\n' "\$d"
else
    "$real_mktemp" "\$@"
fi
FAKEMKTEMP

# Only the fakes this suite wrote are made executable. Symlinks to the real
# tools are left alone: chmod on a symlink is not portable.
chmod 755 "$fake_bin/ss" "$fake_bin/systemctl" "$fake_bin/aws" "$fake_bin/curl" "$fake_bin/timeout" "$fake_bin/mktemp"

for tool in bash env grep rm sed awk sort cat stat id dirname sudo sleep; do
    tool_path="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$tool_path" ]] && ln -sf "$tool_path" "$fake_bin/$tool"
done

# Sources the script and runs its real checks. main() refuses to run
# unprivileged, which is the production contract and is asserted separately, so
# the suite drives run_smoke_checks directly instead of trying to fake root.
#
# $1 combined listing, $2 IPv4 listing, $3 IPv6 listing, rest: extra environment
run_smoke() {
    local fixture="$1" fixture4="$2" fixture6="$3"
    shift 3
    printf '%s' "$fixture" >"$ss_state"
    printf '%s' "$fixture4" >"$ss_state4"
    printf '%s' "$fixture6" >"$ss_state6"
    : >"$curl_log"
    env "$@" PATH="$fake_bin:$PATH" ORIGIN_SERVER_NAME="$HOST" \
        bash -c 'source "$1"; validate_inputs; run_smoke_checks' _ "$SMOKE_SCRIPT" 2>&1
}

# A host that satisfies every part of the contract: both task ports on loopback
# IPv4 only, plus the origin listener on 443.
readonly HEALTHY_ALL='LISTEN 0 4096 127.0.0.1:8080 0.0.0.0:*
LISTEN 0 4096 127.0.0.1:6379 0.0.0.0:*
LISTEN 0 511 0.0.0.0:443 0.0.0.0:*
'
readonly HEALTHY_V4='LISTEN 0 4096 127.0.0.1:8080 0.0.0.0:*
LISTEN 0 4096 127.0.0.1:6379 0.0.0.0:*
'
readonly HEALTHY_V6=''

# --- 1. the healthy ECS host passes -----------------------------------------
output="$(run_smoke "$HEALTHY_ALL" "$HEALTHY_V4" "$HEALTHY_V6")" ||
    fail "A healthy ECS host must pass the smoke check. Output: $output"
assert_contains "$output" "readiness are healthy" \
    "A passing run must report the healthy origin."

# --- 2. all three verification requests are made ----------------------------
log_contents="$(cat "$curl_log")"
assert_contains "$log_contents" "request mode=none" "The no-header request must be made."
assert_contains "$log_contents" "request mode=invalid" "The invalid-header request must be made."
assert_contains "$log_contents" "request mode=valid" "The verified request must be made."

# --- 3. the token never reaches stdout or stderr ----------------------------
assert_absent "$output" "$TOKEN" \
    "The origin verification token must never be printed."
assert_contains "$log_contents" "config-perms=600" \
    "The curl secret config must be readable only by its owner."

# --- 4/5/6. the per-port privacy contract -----------------------------------
# Each port is checked by address family rather than by searching one listing
# for a rendering of a wildcard. ss prints an IPv6 wildcard as "*", "[::]" or
# ":::" depending on version and flags, so every one of those shapes is
# replayed here and must fail regardless of how it is written.
for port_spec in "8080:API" "6379:Valkey"; do
    port="${port_spec%%:*}"
    label="${port_spec#*:}"
    other_port=$([[ "$port" == 8080 ]] && echo 6379 || echo 8080)

    # missing entirely
    v4_missing="LISTEN 0 4096 127.0.0.1:$other_port 0.0.0.0:*
"
    if run_smoke "$HEALTHY_ALL" "$v4_missing" "" >/dev/null 2>&1; then
        fail "A host with no IPv4 listener on $port must fail ($label)."
    fi

    # IPv4 wildcard
    v4_wildcard="LISTEN 0 4096 0.0.0.0:$port 0.0.0.0:*
LISTEN 0 4096 127.0.0.1:$other_port 0.0.0.0:*
"
    if run_smoke "$HEALTHY_ALL" "$v4_wildcard" "" >/dev/null 2>&1; then
        fail "An IPv4 wildcard listener on $port must fail ($label)."
    fi

    # routable IPv4 address, not a wildcard and not loopback
    v4_routable="LISTEN 0 4096 10.20.0.15:$port 0.0.0.0:*
LISTEN 0 4096 127.0.0.1:$other_port 0.0.0.0:*
"
    if run_smoke "$HEALTHY_ALL" "$v4_routable" "" >/dev/null 2>&1; then
        fail "A non-loopback IPv4 listener on $port must fail ($label)."
    fi

    # loopback plus a second binding
    v4_extra="LISTEN 0 4096 127.0.0.1:$port 0.0.0.0:*
LISTEN 0 4096 10.20.0.15:$port 0.0.0.0:*
LISTEN 0 4096 127.0.0.1:$other_port 0.0.0.0:*
"
    if run_smoke "$HEALTHY_ALL" "$v4_extra" "" >/dev/null 2>&1; then
        fail "A second IPv4 binding on $port must fail ($label)."
    fi

    # IPv6 listeners, in each rendering ss is known to produce
    for v6_render in "[::]" "*" ":::"; do
        v6="LISTEN 0 4096 ${v6_render}:$port [::]:*
"
        if run_smoke "$HEALTHY_ALL" "$HEALTHY_V4" "$v6" >/dev/null 2>&1; then
            fail "An IPv6 listener on $port rendered as '$v6_render' must fail ($label)."
        fi
    done

    # IPv6 loopback is still an IPv6 listener and is still refused.
    v6_loopback="LISTEN 0 4096 [::1]:$port [::]:*
"
    if run_smoke "$HEALTHY_ALL" "$HEALTHY_V4" "$v6_loopback" >/dev/null 2>&1; then
        fail "An IPv6 loopback listener on $port must fail ($label)."
    fi
done

# --- 7. the origin listener contract is unchanged ---------------------------
no_443='LISTEN 0 4096 127.0.0.1:8080 0.0.0.0:*
LISTEN 0 4096 127.0.0.1:6379 0.0.0.0:*
'
if run_smoke "$no_443" "$HEALTHY_V4" "" >/dev/null 2>&1; then
    fail "A host with no TCP 443 listener must fail."
fi

with_80="$HEALTHY_ALL"'LISTEN 0 511 0.0.0.0:80 0.0.0.0:*
'
if run_smoke "$with_80" "$HEALTHY_V4" "" >/dev/null 2>&1; then
    fail "A TCP 80 listener must fail the origin contract."
fi

# --- 8. Nginx must be active ------------------------------------------------
if run_smoke "$HEALTHY_ALL" "$HEALTHY_V4" "" FAKE_NGINX_ACTIVE=false >/dev/null 2>&1; then
    fail "An inactive Nginx must fail the smoke check."
fi

# --- 9. the token must not be accepted from the environment -----------------
if run_smoke "$HEALTHY_ALL" "$HEALTHY_V4" "" ORIGIN_VERIFY_TOKEN="$TOKEN" >/dev/null 2>&1; then
    fail "Supplying the token through the environment must be refused."
fi

# --- 10. static contract: no Docker inspection on this path -----------------
# The standalone check asserts container names and port bindings; this one must
# not, or it would fail on every ECS host for the wrong reason.
script_contents="$(cat "$SMOKE_SCRIPT")"
# Comments are stripped first. The header explains why this file does not use
# the standalone checks, and naming them there must not read as using them.
script_code="$(sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*#.*$//' <<<"$script_contents")"
for forbidden in "docker inspect" "docker port" "ec-portfolio-demo-api" "ec-portfolio-demo-valkey"; do
    assert_absent "$script_code" "$forbidden" \
        "The ECS smoke check must not depend on: $forbidden"
done
assert_absent "$script_code" "certbot" \
    "The smoke check must never invoke certbot."

# --- 11. the script still refuses to run unprivileged -----------------------
# run_smoke_checks is reachable from the suite; the entry point is not.
assert_contains "$script_contents" 'if (( EUID != 0 )); then' \
    "main() must still refuse to run without root."
assert_contains "$script_contents" 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' \
    "Sourcing the script must not run a check."

printf '[origin-smoke-ecs-test] PASS\n'
