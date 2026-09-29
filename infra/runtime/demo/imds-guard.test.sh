#!/usr/bin/env bash

# Behaviour tests for the container IMDS guard.
#
# iptables is replaced by a small stateful model that keeps each chain's rules
# in order and answers -S, -N, -I, -A, -D, -C and -F the way the frontend does.
# curl is replaced by a probe that walks those rules for the calling UID, the
# way the kernel would for a locally generated packet to 169.254.169.254, so
# "UID 10001 is refused" is decided by the rules the script actually wrote, not
# by a switch the test sets.
#
# No real iptables, no network, no root. Runs under bash 3.2 and bash 5.

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly GUARD_SCRIPT="$SCRIPT_DIRECTORY/imds-guard.sh"
readonly GUARD_UNIT="$SCRIPT_DIRECTORY/ec-portfolio-imds-guard.service"

work_directory=""

cleanup_tests() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-imds-guard-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup_tests EXIT

fail() {
    printf '[imds-guard-test] FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "$3 (expected to find: $2)"
}

assert_absent() {
    [[ "$1" != *"$2"* ]] || fail "$3 (unexpectedly found: $2)"
}

work_directory="$(mktemp -d /tmp/ec-portfolio-imds-guard-test.XXXXXX)"
fake_bin="$work_directory/bin"
state="$work_directory/state"
mkdir -p "$fake_bin" "$state"

script_code="$(sed -e 's/[[:space:]]#.*$//' -e 's/^[[:space:]]*#.*$//' "$GUARD_SCRIPT")"

# ---------------------------------------------------------------------------
# Fakes
# ---------------------------------------------------------------------------

# The iptables model. Each chain is a file under $IPT_STATE/chains holding one
# rule per line, exactly as the arguments were given. Mutating calls are logged
# so idempotency can be asserted as "the second run changed nothing".
cat >"$fake_bin/iptables" <<'IPTABLES'
#!/usr/bin/env bash
set -u
chains="$IPT_STATE/chains"
mkdir -p "$chains"
for builtin in INPUT FORWARD OUTPUT; do [[ -e "$chains/$builtin" ]] || : >"$chains/$builtin"; done

if [[ "${1:-}" == "-w" ]]; then
    shift
    [[ "${1:-}" =~ ^[0-9]+$ ]] && shift
fi
op="${1:-}"; chain="${2:-}"
shift 2 || true

is_builtin() { [[ "$1" == INPUT || "$1" == FORWARD || "$1" == OUTPUT ]]; }
exists() { [[ -e "$chains/$1" ]]; }
record() { printf '%s %s %s\n' "$op" "$chain" "$*" >>"$IPT_STATE/mutations"; }

case "$op" in
    -N|-I|-A|-D|-F) [[ -e "$IPT_STATE/fail$op" ]] && exit 1 ;;
esac

case "$op" in
    -S)
        exists "$chain" || { echo "iptables: No chain/target/match by that name." >&2; exit 1; }
        if is_builtin "$chain"; then echo "-P $chain ACCEPT"; else echo "-N $chain"; fi
        while IFS= read -r rule; do
            [[ -n "$rule" ]] && echo "-A $chain $rule"
        done <"$chains/$chain"
        exit 0 ;;
    -N)
        exists "$chain" && { echo "iptables: Chain already exists." >&2; exit 1; }
        record; : >"$chains/$chain"; exit 0 ;;
    -F)
        exists "$chain" || exit 1
        record; : >"$chains/$chain"; exit 0 ;;
    -A)
        exists "$chain" || exit 1
        record "$@"
        [[ -e "$IPT_STATE/ignore-writes" ]] && exit 0
        printf '%s\n' "$*" >>"$chains/$chain"; exit 0 ;;
    -I)
        exists "$chain" || exit 1
        position=1
        if [[ "${1:-}" =~ ^[0-9]+$ ]]; then position="$1"; shift; fi
        record "$position" "$@"
        [[ -e "$IPT_STATE/ignore-writes" ]] && exit 0
        awk -v pos="$position" -v rule="$*" '
            NR == pos { print rule; done = 1 }
            { print }
            END { if (!done) print rule }' "$chains/$chain" >"$chains/$chain.new"
        mv "$chains/$chain.new" "$chains/$chain"; exit 0 ;;
    -D)
        exists "$chain" || exit 1
        record "$@"
        if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
            total="$(grep -c . "$chains/$chain" || true)"
            (( $1 >= 1 && $1 <= total )) || exit 1
            awk -v pos="$1" 'NR != pos' "$chains/$chain" >"$chains/$chain.new"
        else
            grep -qxF -- "$*" "$chains/$chain" || exit 1
            awk -v rule="$*" '!done && $0 == rule { done = 1; next } { print }' \
                "$chains/$chain" >"$chains/$chain.new"
        fi
        mv "$chains/$chain.new" "$chains/$chain"; exit 0 ;;
    -C)
        exists "$chain" || exit 1
        grep -qxF -- "$*" "$chains/$chain"; exit $? ;;
esac
echo "fake iptables: unsupported operation $op" >&2
exit 2
IPTABLES

# The probe walks OUTPUT for the calling UID. A jump to a chain evaluates that
# chain's rules in order: an owner RETURN for this UID returns to OUTPUT, a
# REJECT refuses the connection with curl's exit 7, and falling off the end
# returns as well. Reaching the end of OUTPUT means the packet is accepted.
cat >"$fake_bin/curl" <<'CURL'
#!/usr/bin/env bash
set -u
uid="${FAKE_UID:-0}"
url="" write_out=""
while (( $# > 0 )); do
    case "$1" in
        --write-out) write_out="$2"; shift 2 ;;
        --max-time|--output|-X|-H|--noproxy) shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done
printf 'probe uid=%s url=%s\n' "$uid" "$url" >>"$IPT_STATE/probes"
[[ -e "$IPT_STATE/probe-exit-$uid" ]] && exit "$(cat "$IPT_STATE/probe-exit-$uid")"
[[ "$url" == http://169.254.169.254/* ]] || exit 6

chains="$IPT_STATE/chains"
verdict=accept
walk_chain() {
    local name="$1" rule
    while IFS= read -r rule; do
        [[ -n "$rule" ]] || continue
        case "$rule" in
            *"-d 169.254.169.254/32"*|"-j "*) ;;
            *) continue ;;
        esac
        if [[ "$rule" == *"--uid-owner "* ]]; then
            owner="${rule#*--uid-owner }"; owner="${owner%% *}"
            [[ "$owner" == "$uid" ]] || continue
        fi
        case "$rule" in
            *" -j RETURN"|"-j RETURN") return 0 ;;
            *" -j REJECT"*|"-j REJECT"*) verdict=reject; return 1 ;;
            *" -j ACCEPT"|"-j ACCEPT") verdict=accept; return 1 ;;
            *" -j "*)
                target="${rule##* -j }"
                if [[ -e "$chains/$target" ]]; then
                    walk_chain "$target" || return 1
                fi ;;
        esac
    done <"$chains/$name"
    return 0
}
[[ -e "$chains/OUTPUT" ]] && walk_chain OUTPUT || true
if [[ "$verdict" == reject ]]; then exit 7; fi
[[ -n "$write_out" ]] && printf '200'
exit 0
CURL

# setpriv hands the requested UID to the probe, which is all the owner match
# reads.
cat >"$fake_bin/setpriv" <<'SETPRIV'
#!/usr/bin/env bash
set -u
while (( $# > 0 )); do
    case "$1" in
        --reuid=*) export FAKE_UID="${1#--reuid=}"; shift ;;
        --) shift; break ;;
        *) shift ;;
    esac
done
exec "$@"
SETPRIV

chmod 755 "$fake_bin/iptables" "$fake_bin/curl" "$fake_bin/setpriv"

# Every case starts from a host with nothing but empty built-in chains.
reset_state() {
    rm -rf "$state"
    mkdir -p "$state"
}

# Runs one guard function in a fresh shell with the fakes first on PATH.
guard() {
    env PATH="$fake_bin:$PATH" IPT_STATE="$state" \
        bash -c 'source "$1"; shift; "$@"' _ "$GUARD_SCRIPT" "$@"
}

chain_file() {
    cat "$state/chains/$1" 2>/dev/null || true
}

mutations() {
    cat "$state/mutations" 2>/dev/null || true
}

probe_as() {
    local uid="$1"
    env PATH="$fake_bin:$PATH" IPT_STATE="$state" FAKE_UID="$uid" \
        curl --disable --noproxy '*' --silent --output /dev/null --max-time 3 -X PUT \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
        http://169.254.169.254/latest/api/token && printf '0' || printf '%s' "$?"
}

readonly EXPECTED_RETURN="-d 169.254.169.254/32 -m owner --uid-owner 0 -j RETURN"
readonly EXPECTED_REJECT="-d 169.254.169.254/32 -j REJECT --reject-with icmp-port-unreachable"
readonly EXPECTED_JUMP="-d 169.254.169.254/32 -j EC_PORTFOLIO_IMDS"

assert_expected_rules() {
    local context="$1" chain output
    chain="$(chain_file EC_PORTFOLIO_IMDS)"
    [[ "$chain" == "$EXPECTED_RETURN"$'\n'"$EXPECTED_REJECT" ]] ||
        fail "$context: the guard chain must be exactly the root RETURN then the REJECT. Got:
$chain"
    output="$(chain_file OUTPUT)"
    [[ "$(printf '%s\n' "$output" | head -n 1)" == "$EXPECTED_JUMP" ]] ||
        fail "$context: the IMDS jump must be the first rule of OUTPUT. Got:
$output"
    [[ "$(printf '%s\n' "$output" | grep -cxF -- "$EXPECTED_JUMP" || true)" == "1" ]] ||
        fail "$context: OUTPUT must hold exactly one jump to the guard chain."
}

# ---------------------------------------------------------------------------
# 1. Static contract
# ---------------------------------------------------------------------------

# The destination is IMDS and nothing else; no policy, table, inbound chain or
# wide network is ever touched.
for forbidden in "0.0.0.0/0" " -P " " -t " "INPUT" "FORWARD" "DROP" "ip6tables" "nft "; do
    assert_absent "$script_code" "$forbidden" \
        "The guard must not reach beyond IMDS on locally generated traffic: '$forbidden'"
done
assert_contains "$script_code" 'readonly IMDS_DESTINATION="169.254.169.254/32"' \
    "The guard must name the IMDS address exactly."
assert_contains "$script_code" 'readonly ALLOWED_UID="0"' \
    "Root must be the only UID the guard lets through."
assert_contains "$script_code" 'readonly PROBE_UIDS="10001 999"' \
    "verify must probe the proven API and Valkey UIDs."
assert_contains "$script_code" '(( EUID == 0 )) || fail' \
    "main must refuse to run unprivileged."
assert_contains "$script_code" 'if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then' \
    "Sourcing the script must not touch iptables."

# The UIDs are part of the contract, so their evidence must stay next to them.
assert_contains "$(cat "$GUARD_SCRIPT")" 'apps/api/Dockerfile ends with `USER 10001:10001`' \
    "The API UID must cite where it was proven."
assert_contains "$(cat "$GUARD_SCRIPT")" 'adduser -S -G valkey -u 999' \
    "The Valkey UID must cite where it was proven."
assert_contains "$(cat "$SCRIPT_DIRECTORY/../../../apps/api/Dockerfile")" "USER 10001:10001" \
    "The API image must still run as UID 10001, or the probe UID is stale."

# ---------------------------------------------------------------------------
# 2. The unit: before ecs.service, required by it, no network wait, fail loud
# ---------------------------------------------------------------------------

unit="$(cat "$GUARD_UNIT")"
unit_code="$(sed -e 's/^[[:space:]]*#.*$//' <<<"$unit")"
for line in "Type=oneshot" "RemainAfterExit=yes" "Before=ecs.service" \
    "RequiredBy=ecs.service" "WantedBy=multi-user.target" \
    "ExecStart=/usr/local/sbin/ec-portfolio-imds-guard apply"; do
    grep -qxF -- "$line" <<<"$unit_code" ||
        fail "The guard unit must contain the line: $line"
done
# A '-' prefix would let a failed apply succeed the unit and so start the agent.
assert_absent "$unit_code" "ExecStart=-" "The guard's ExecStart must not ignore failure."
# Waiting on the network or on cloud-init would reintroduce an ordering the
# guard has no need for, and cloud-final is where the pre phase starts it.
for forbidden in "network-online.target" "cloud-final" "After=ecs.service" "Wants=ecs.service"; do
    assert_absent "$unit_code" "$forbidden" \
        "The guard unit must not be ordered against $forbidden."
done
# The install path the unit runs is the one the bootstrap installs to.
assert_contains "$(cat "$SCRIPT_DIRECTORY/bootstrap-spot-host.sh")" \
    'IMDS_GUARD_TARGET="${BOOTSTRAP_PREFIX}/usr/local/sbin/ec-portfolio-imds-guard"' \
    "The bootstrap must install the guard where the unit runs it."

# ---------------------------------------------------------------------------
# 3. apply on a fresh host
# ---------------------------------------------------------------------------

reset_state
guard apply_rules >"$work_directory/apply.out" 2>&1 ||
    fail "apply must succeed on a fresh host. Output: $(cat "$work_directory/apply.out")"
assert_expected_rules "fresh apply"
[[ -z "$(chain_file INPUT)$(chain_file FORWARD)" ]] ||
    fail "apply must not write to INPUT or FORWARD."

# ---------------------------------------------------------------------------
# 4. Idempotency: a second run only reads
# ---------------------------------------------------------------------------

before="$(chain_file OUTPUT)|$(chain_file EC_PORTFOLIO_IMDS)"
: >"$state/mutations"
guard apply_rules >"$work_directory/apply2.out" 2>&1 ||
    fail "A second apply must succeed. Output: $(cat "$work_directory/apply2.out")"
[[ -z "$(mutations)" ]] ||
    fail "A second apply must not change anything. Mutations:
$(mutations)"
[[ "$(chain_file OUTPUT)|$(chain_file EC_PORTFOLIO_IMDS)" == "$before" ]] ||
    fail "A second apply must leave the rules exactly as they were."

# ---------------------------------------------------------------------------
# 5. UID semantics: root allowed, the container UIDs and any other refused
# ---------------------------------------------------------------------------

[[ "$(probe_as 0)" == "0" ]] || fail "UID 0 must still reach IMDS through the guard."
for uid in 10001 999 1 65534; do
    [[ "$(probe_as "$uid")" == "7" ]] ||
        fail "UID $uid must be refused with a failed connection (curl exit 7)."
done

# The positive control for the model itself: with no rules at all, a
# non-root UID does reach IMDS. Without it, "refused" above could be the
# probe's default rather than the rules' effect.
reset_state
[[ "$(probe_as 10001)" == "0" ]] ||
    fail "Without the guard the probe must let UID 10001 through, or the model proves nothing."

# ---------------------------------------------------------------------------
# 6. verify: proven effect, fail closed on anything less
# ---------------------------------------------------------------------------

reset_state
guard apply_rules >/dev/null 2>&1
guard verify_effect >"$work_directory/verify.out" 2>&1 ||
    fail "verify must pass once the guard is applied. Output: $(cat "$work_directory/verify.out")"
for uid in 0 10001 999; do
    grep -q "^probe uid=$uid " "$state/probes" ||
        fail "verify must probe UID $uid."
done
assert_absent "$(cat "$work_directory/verify.out")" "200" \
    "verify must not print what IMDS returned."

# No rules: verify refuses before probing anything.
reset_state
if guard verify_effect >/dev/null 2>&1; then
    fail "verify must fail when the guard has not been applied."
fi
[[ ! -e "$state/probes" ]] || fail "verify must not probe IMDS before checking the rules."

# A guard that also blocks root is a broken host, not a stricter one.
reset_state
guard apply_rules >/dev/null 2>&1
awk 'NR != 1' "$state/chains/EC_PORTFOLIO_IMDS" >"$state/tmp" && mv "$state/tmp" "$state/chains/EC_PORTFOLIO_IMDS"
if guard verify_effect >/dev/null 2>&1; then
    fail "verify must fail when root is refused as well."
fi

# A failure that is not a refused connection is not evidence of the block.
for code in 28 6 127 0; do
    reset_state
    guard apply_rules >/dev/null 2>&1
    printf '%s' "$code" >"$state/probe-exit-10001"
    if guard verify_effect >/dev/null 2>&1; then
        fail "verify must not accept curl exit $code as proof that UID 10001 is refused."
    fi
done

# Root unable to reach IMDS at all.
reset_state
guard apply_rules >/dev/null 2>&1
printf '28' >"$state/probe-exit-0"
if guard verify_effect >/dev/null 2>&1; then
    fail "verify must fail when root cannot obtain a token."
fi

# ---------------------------------------------------------------------------
# 7. Repair: drift is corrected without ever letting a non-root UID through
# ---------------------------------------------------------------------------

# Wrong order in the chain.
reset_state
mkdir -p "$state/chains"
: >"$state/chains/INPUT"; : >"$state/chains/FORWARD"
printf '%s\n%s\n' "$EXPECTED_REJECT" "$EXPECTED_RETURN" >"$state/chains/EC_PORTFOLIO_IMDS"
printf '%s\n' "$EXPECTED_JUMP" >"$state/chains/OUTPUT"
guard apply_rules >/dev/null 2>&1 || fail "apply must repair a chain in the wrong order."
assert_expected_rules "wrong-order repair"

# A stray rule that would let everyone through.
reset_state
mkdir -p "$state/chains"
: >"$state/chains/INPUT"; : >"$state/chains/FORWARD"
printf '%s\n%s\n%s\n' "-d 169.254.169.254/32 -j RETURN" "$EXPECTED_RETURN" "$EXPECTED_REJECT" \
    >"$state/chains/EC_PORTFOLIO_IMDS"
printf '%s\n' "$EXPECTED_JUMP" >"$state/chains/OUTPUT"
guard apply_rules >/dev/null 2>&1 || fail "apply must repair a chain with a stray rule."
assert_expected_rules "stray-rule repair"
[[ "$(probe_as 10001)" == "7" ]] || fail "After repair UID 10001 must be refused."

# A rule above the jump that accepts IMDS traffic, and a duplicate jump.
reset_state
mkdir -p "$state/chains"
: >"$state/chains/INPUT"; : >"$state/chains/FORWARD"
: >"$state/chains/EC_PORTFOLIO_IMDS"
printf '%s\n%s\n%s\n' "-d 169.254.169.254/32 -j ACCEPT" "$EXPECTED_JUMP" "$EXPECTED_JUMP" \
    >"$state/chains/OUTPUT"
[[ "$(probe_as 10001)" == "0" ]] || fail "The drift fixture must actually let UID 10001 through."
guard apply_rules >/dev/null 2>&1 || fail "apply must move the jump above an earlier rule."
assert_expected_rules "jump-position repair"
[[ "$(probe_as 10001)" == "7" ]] || fail "After repair UID 10001 must be refused."
grep -qxF -- "-d 169.254.169.254/32 -j ACCEPT" "$state/chains/OUTPUT" ||
    fail "apply must leave rules it does not own in place."

# The order of a repair: the REJECT goes in before the RETURN, and the jump is
# inserted before any duplicate is deleted. Read from the mutation log.
reset_state
guard apply_rules >/dev/null 2>&1
inserts="$(grep -E '^-I EC_PORTFOLIO_IMDS 1 ' "$state/mutations" || true)"
[[ "$(printf '%s\n' "$inserts" | sed -n 1p)" == *" -j REJECT "* &&
    "$(printf '%s\n' "$inserts" | sed -n 2p)" == *"--uid-owner 0 -j RETURN" ]] ||
    fail "The REJECT must be written before the root RETURN is put above it. Log: $(mutations)"

# The same for OUTPUT: with a duplicate jump present, the new first jump is
# inserted before any duplicate is deleted.
reset_state
mkdir -p "$state/chains"
: >"$state/chains/INPUT"; : >"$state/chains/FORWARD"
printf '%s\n%s\n' "$EXPECTED_RETURN" "$EXPECTED_REJECT" >"$state/chains/EC_PORTFOLIO_IMDS"
printf '%s\n%s\n' "-d 10.0.0.0/8 -j RETURN" "$EXPECTED_JUMP" >"$state/chains/OUTPUT"
guard apply_rules >/dev/null 2>&1 || fail "apply must move a jump that is not first."
jump_ops="$(grep -E '^-(I|D) OUTPUT ' "$state/mutations" | cut -c1-2 | tr '\n' ' ')"
[[ "$jump_ops" == "-I -D " ]] ||
    fail "The jump must be inserted at the top before the old one is deleted (saw: $jump_ops)."
assert_expected_rules "jump-move repair"

# ---------------------------------------------------------------------------
# 8. Fail closed on every write failure and on an unverifiable result
# ---------------------------------------------------------------------------

for op in N I D; do
    reset_state
    if [[ "$op" == "D" ]]; then
        mkdir -p "$state/chains"
        : >"$state/chains/INPUT"; : >"$state/chains/FORWARD"
        printf '%s\n%s\n%s\n' "$EXPECTED_RETURN" "$EXPECTED_REJECT" "-j RETURN" >"$state/chains/EC_PORTFOLIO_IMDS"
        printf '%s\n' "$EXPECTED_JUMP" >"$state/chains/OUTPUT"
    fi
    : >"$state/fail-$op"
    if guard apply_rules >/dev/null 2>&1; then
        fail "apply must fail when iptables $op fails."
    fi
done

# Writes that report success but do not land.
reset_state
: >"$state/ignore-writes"
if guard apply_rules >/dev/null 2>&1; then
    fail "apply must fail when the rules are not in place afterwards."
fi

# No iptables at all.
reset_state
empty_bin="$work_directory/empty-bin"
mkdir -p "$empty_bin"
for tool in bash env grep head awk sed cat printf mkdir rm mv; do
    tool_path="$(command -v "$tool" 2>/dev/null || true)"
    [[ -n "$tool_path" ]] && ln -sf "$tool_path" "$empty_bin/$tool"
done
if env PATH="$empty_bin" IPT_STATE="$state" \
    bash -c 'source "$1"; apply_rules' _ "$GUARD_SCRIPT" >/dev/null 2>&1; then
    fail "apply must fail when iptables is not available."
fi
if env PATH="$empty_bin" bash -c 'source "$1"; require_command iptables' _ "$GUARD_SCRIPT" >/dev/null 2>&1; then
    fail "require_command must refuse a missing iptables."
fi

# ---------------------------------------------------------------------------
# 9. Configuration: invalid probe UIDs are refused
# ---------------------------------------------------------------------------

for bad in "" " " "0" "10001 0" "-1" "abc" "01" "1.5" "4294967295" "99999999999" "10001;999"; do
    if guard validate_probe_uids "$bad" >/dev/null 2>&1; then
        fail "validate_probe_uids must refuse '$bad'."
    fi
done
for good in "10001 999" "10001" "4294967294"; do
    guard validate_probe_uids "$good" >/dev/null 2>&1 ||
        fail "validate_probe_uids must accept '$good'."
done
guard validate_configuration >/dev/null 2>&1 ||
    fail "The shipped configuration must be valid."

printf '[imds-guard-test] PASS\n'
