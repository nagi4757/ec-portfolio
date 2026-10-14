#!/usr/bin/env bash

# Contract tests for the Phase 6C-5c S0 memory probe (ecs-memory-probe.sh).
#
# The probe is not part of the production task definition. It is meant for the
# measurement task of a separate measurement ECS cluster; that stack, and the
# contract of its container definition, come with their own change.
#
# The probe runs against a fixture /proc, a fixture cgroup directory and a fake
# wget that serves fixture ECS task metadata. The fixture metadata carries an
# account ID in its ARNs, and the probe's environment carries values shaped like
# credentials and session IDs: none of them may reach the output.
#
# By default the probe runs under the host's /bin/sh, and under dash when it is
# installed (BusyBox ash descends from dash). --image also runs it inside the
# Valkey image pinned in ecs_application.tf, whose digest the measurement task
# reuses (BusyBox sh, awk, wget), the way that task would run it --
# non-root, read-only root filesystem, every capability dropped, no network --
# stops it as PID 1 the way ECS does, and compares the container's own
# /proc/meminfo with the host's. --image needs Docker and pulls that image.
#
# No AWS call. Runs under bash 3.2 and bash 5.

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROBE="$SCRIPT_DIRECTORY/ecs-memory-probe.sh"
# Read only for the pinned Valkey image digest (--image).
readonly PINNED_IMAGE_FILE="$SCRIPT_DIRECTORY/../../terraform/demo/ecs_application.tf"
readonly ACCOUNT="111122223333"
readonly PLANTED="PLANTEDsecretVALUE0123456789"
readonly METADATA_URI="http://169.254.170.2/v4/4f7c2f2c-probe-0001"
readonly API_ID="1a2b3c4d5e6f1a2b3c4d5e6f1a2b3c4d5e6f1a2b3c4d5e6f1a2b3c4d5e6f1a2b"
readonly VALKEY_ID="2b3c4d5e6f1a2b3c4d5e6f1a2b3c4d5e6f1a2b3c4d5e6f1a2b3c4d5e6f1a2b3c"
readonly PROBE_ID="3c4d5e6f1a2b3c4d5e6f1a2b3c4d5e6f1a2b3c4d5e6f1a2b3c4d5e6f1a2b3c4d"

with_image="false"
case "${1:-}" in
"") ;;
--image) with_image="true" ;;
*) printf 'usage: %s [--image]\n' "$0" >&2; exit 2 ;;
esac

work_directory=""

cleanup_tests() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-memory-probe-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup_tests EXIT

fail() {
    printf '[memory-probe-test] FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "$3 (expected to find: $2)"
}

assert_absent() {
    [[ "$1" != *"$2"* ]] || fail "$3 (unexpectedly found: $2)"
}

work_directory="$(mktemp -d /tmp/ec-portfolio-memory-probe-test.XXXXXX)"
fixture="$work_directory/fixture"

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

mkdir -p "$fixture/proc/pressure" "$fixture/proc/self" "$fixture/proc/sys/kernel" \
    "$fixture/cgroup" "$fixture/metadata" "$fixture/bin"

cat >"$fixture/proc/meminfo" <<'EOF'
MemTotal:        3940336 kB
MemFree:         2683352 kB
MemAvailable:    3131868 kB
Buffers:            2168 kB
Cached:           605800 kB
SwapCached:            0 kB
Active:           211680 kB
AnonPages:        442624 kB
Shmem:              1024 kB
Slab:              90000 kB
SReclaimable:      50000 kB
SUnreclaim:        40000 kB
KernelStack:        6000 kB
PageTables:         9000 kB
SwapTotal:             0 kB
SwapFree:              0 kB
Committed_AS:    1500000 kB
EOF
printf 'pswpin 0\npswpout 0\noom_kill 0\npgmajfault 1234\n' >"$fixture/proc/vmstat"
printf 'some avg10=0.00 avg60=0.10 avg300=0.00 total=1200\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=300\n' \
    >"$fixture/proc/pressure/memory"
printf 'cpu  1000 0 500 80000 200 0 50 300 0 0\ncpu0 500 0 250 40000 100 0 25 150 0 0\n' >"$fixture/proc/stat"
printf '420.13 800.00\n' >"$fixture/proc/uptime"
printf 'processor\t: 0\nmodel name\t: AMD EPYC\n\nprocessor\t: 1\nmodel name\t: AMD EPYC\n' >"$fixture/proc/cpuinfo"
printf '6.1.155-176.282.amzn2023.x86_64\n' >"$fixture/proc/sys/kernel/osrelease"
cat >"$fixture/proc/self/mountinfo" <<'EOF'
1074 980 0:62 / / ro,relatime master:1 - overlay overlay rw,lowerdir=/x
1075 1074 0:65 / /proc rw,nosuid,nodev,noexec,relatime - proc proc rw
1080 1074 0:66 / /sys ro,nosuid,nodev,noexec,relatime - sysfs sysfs ro
1081 1080 0:30 / /sys/fs/cgroup ro,nosuid,nodev,noexec,relatime - cgroup2 cgroup rw
EOF
printf 'cpu memory pids\n' >"$fixture/cgroup/cgroup.controllers"
printf '2097152\n' >"$fixture/cgroup/memory.current"
printf '4194304\n' >"$fixture/cgroup/memory.peak"
printf 'low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\n' >"$fixture/cgroup/memory.events"

# ECS task metadata v4, shaped like the documented /task response: ARNs with the
# account ID, labels, log options. A name that is not a container name pattern
# and a container with null stats are included on purpose.
cat >"$fixture/metadata/task.json" <<EOF
{"Cluster":"arn:aws:ecs:ap-northeast-1:$ACCOUNT:cluster/ec-portfolio-demo","TaskARN":"arn:aws:ecs:ap-northeast-1:$ACCOUNT:task/ec-portfolio-demo/0123456789abcdef","Family":"ec-portfolio-demo-api","Revision":"4",
 "Containers":[
  {"DockerId":"$VALKEY_ID","Name":"valkey","DockerName":"ecs-ec-portfolio-demo-api-4-valkey-aaaa","Image":"valkey/valkey@sha256:16625369","Labels":{"com.amazonaws.ecs.task-arn":"arn:aws:ecs:ap-northeast-1:$ACCOUNT:task/ec-portfolio-demo/0123456789abcdef"},"LogOptions":{"awslogs-group":"/ec-portfolio/demo/ecs/api","awslogs-stream":"valkey/valkey/0123456789abcdef"},"ContainerARN":"arn:aws:ecs:ap-northeast-1:$ACCOUNT:container/x"},
  {"DockerId":"$API_ID","Name":"api","DockerName":"ecs-ec-portfolio-demo-api-4-api-bbbb","Labels":{"note":"$PLANTED"},"Networks":[{"NetworkMode":"host","IPv4Addresses":["10.0.1.25"]}]},
  {"DockerId":"$PROBE_ID","Name":"memory-probe","DockerName":"ecs-ec-portfolio-demo-api-4-memory-probe-cccc"},
  {"DockerId":"4d5e6f1a2b3c4d5e6f1a2b3c4d5e6f1a2b3c4d5e6f1a2b3c4d5e6f1a2b3c4d5e","Name":"bad name;rm"}
 ]}
EOF
cat >"$fixture/metadata/stats.json" <<EOF
{
 "$API_ID": {"read":"2026-10-15T01:00:00.1Z","name":"/ecs-ec-portfolio-demo-api-4-api-bbbb","id":"$API_ID",
   "memory_stats":{"usage":419430400,"stats":{"anon":314572800,"file":102760448,"inactive_file":52428800,"active_file":50331648,"shmem":0,"slab":4194304,"kernel_stack":655360,"sock":0,"pgfault":12345},"limit":4034904064},
   "cpu_stats":{"cpu_usage":{"total_usage":123456789}}},
 "$VALKEY_ID": {"name":"/ecs-ec-portfolio-demo-api-4-valkey-aaaa","id":"$VALKEY_ID",
   "memory_stats":{"usage":13631488,"stats":{"anon":3145728,"file":10485760,"inactive_file":8388608},"limit":4034904064}},
 "$PROBE_ID": null,
 "4d5e6f1a2b3c4d5e6f1a2b3c4d5e6f1a2b3c4d5e6f1a2b3c4d5e6f1a2b3c4d5e": {"memory_stats":{"usage":1048576}}
}
EOF

# The fake BusyBox wget: serves the fixture by URL path, records the URL when a
# log is given, and fails when told to.
cat >"$fixture/bin/wget" <<'EOF'
#!/bin/sh
url=""
for argument in "$@"; do url="$argument"; done
[ -n "${FAKE_WGET_LOG:-}" ] && printf '%s\n' "$url" >>"$FAKE_WGET_LOG"
[ "${FAKE_METADATA_MODE:-}" = fail ] && exit 1
case "$url" in
*/task) cat "$FAKE_METADATA_DIR/task.json" ;;
*/task/stats)
    if [ "${FAKE_METADATA_MODE:-}" = no-stats ]; then printf '{}\n'; else cat "$FAKE_METADATA_DIR/stats.json"; fi
    ;;
*) exit 8 ;;
esac
EOF
chmod 755 "$fixture/bin/wget"
chmod -R a+rX "$fixture"

# run_probe <shell> <output> [VAR=value ...]: two samples, one second apart, against the fixture.
run_probe() {
    local shell="$1" output="$2"
    shift 2
    env -i PATH="$fixture/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME=/nonexistent \
        MEMORY_PROBE_PROC_ROOT="$fixture/proc" MEMORY_PROBE_CGROUP_ROOT="$fixture/cgroup" \
        MEMORY_PROBE_MAX_SAMPLES=2 MEMORY_PROBE_FAST_INTERVAL_SECONDS=1 \
        ECS_CONTAINER_METADATA_URI_V4="$METADATA_URI" FAKE_METADATA_DIR="$fixture/metadata" \
        AWS_CONTAINER_CREDENTIALS_RELATIVE_URI="/v2/credentials/$PLANTED" AWS_SECRET_ACCESS_KEY="$PLANTED" \
        AWS_SESSION_TOKEN="$PLANTED" SSM_SESSION_ID="operator-$PLANTED" \
        "$@" "$shell" "$PROBE" >"$output" 2>"$output.stderr"
}

# Every output token is key=value over a fixed character set; nothing planted leaks.
assert_clean_output() {
    local output="$1" label="$2" content
    content="$(cat "$output")"
    [[ ! -s "$output.stderr" ]] || fail "$label: stderr is not empty: $(head -3 "$output.stderr")"
    awk '{ if ($1 != "memprobe") exit 1; for (i = 2; i <= NF; i++) if ($i !~ /^[A-Za-z0-9_.-]+=[A-Za-z0-9_.:-]+$/) exit 1 }' "$output" ||
        fail "$label: a token outside key=value over [A-Za-z0-9_.:-]: $(head -2 "$output")"
    for planted in "$ACCOUNT" "$PLANTED" "4f7c2f2c" "$API_ID" "$VALKEY_ID" "$PROBE_ID" "arn:" "TaskARN" "ec-portfolio-demo" \
        "awslogs" "10.0.1.25" "bad" "credentials" "169.254"; do
        assert_absent "$content" "$planted" "$label: a metadata or environment value reached the output"
    done
}

check_contract_output() {
    local output="$1" label="$2" lines start sample
    assert_clean_output "$output" "$label"
    lines="$(wc -l <"$output" | tr -d ' ')"
    [[ "$lines" == 3 ]] || fail "$label: expected a start line and two samples, got $lines lines"
    start="$(sed -n 1p "$output")"
    assert_contains "$start" "memprobe v=1 event=start kernel=6.1.155-176.282.amzn2023.x86_64 nproc=2 uid=" "$label: start line"
    assert_contains "$start" " meminfo_mount=none cgroup=v2 psi=available metadata=configured interval_s=30 fast_interval_s=1 fast_window_s=900" "$label: start line settings"
    sample="$(sed -n 2p "$output")"
    assert_contains "$sample" "memprobe v=1 seq=1 t=" "$label: first sample"
    assert_contains "$sample" " host_uptime_s=420.13 MemTotal_kB=3940336 MemFree_kB=2683352 MemAvailable_kB=3131868 " "$label: meminfo"
    assert_contains "$sample" " SwapTotal_kB=0 SwapFree_kB=0 Committed_AS_kB=1500000 " "$label: swap"
    assert_contains "$sample" " vm_oom_kill=0 vm_pswpin=0 vm_pswpout=0 vm_pgmajfault=1234 " "$label: vmstat"
    assert_contains "$sample" " psi_some_avg10=0.00 psi_some_avg60=0.10 psi_some_total=1200 psi_full_avg10=0.00 psi_full_avg60=0.00 psi_full_total=300 " "$label: PSI"
    assert_contains "$sample" " cpu_total_ticks=82050 cpu_idle_ticks=80200 cpu_steal_ticks=300 " "$label: CPU ticks"
    assert_contains "$sample" " self_cg_current_kB=2048 self_cg_peak_kB=4096 self_cg_oom_kill=0 " "$label: own cgroup"
    assert_contains "$sample" " metadata=ok c_api_active_file_kB=49152 c_api_anon_kB=307200 c_api_file_kB=100352 c_api_inactive_file_kB=51200 c_api_kernel_stack_kB=640 c_api_limit_kB=3940336 c_api_shmem_kB=0 c_api_slab_kB=4096 c_api_sock_kB=0 c_api_usage_kB=409600 c_valkey_anon_kB=3072 c_valkey_file_kB=10240 c_valkey_inactive_file_kB=8192 c_valkey_limit_kB=3940336 c_valkey_usage_kB=13312" "$label: task memory"
    assert_absent "$sample" "pgfault" "$label: only the listed counters"
    assert_contains "$(sed -n 3p "$output")" "memprobe v=1 seq=2 t=" "$label: second sample"
}

shells=(/bin/sh)
[[ -x /bin/dash ]] && shells+=(/bin/dash)
command -v dash >/dev/null 2>&1 && [[ "$(command -v dash)" != /bin/dash ]] && shells+=("$(command -v dash)")

# ---------------------------------------------------------------------------
# Static contract: the probe script
# ---------------------------------------------------------------------------

probe_code="$(sed -e 's/^[[:space:]]*#.*$//' "$PROBE")"
for forbidden in "printenv" "env " "set -x" "/environ" "169.254.169.254" ">>" "tee " "rm " "mkdir" "curl" "nc "; do
    assert_absent "$probe_code" "$forbidden" "the probe must stay read-only and must not print its environment"
done
[[ "$(sed -e 's/^[[:space:]]*#.*$//' -e 's#2>/dev/null##g' -e 's#>/dev/null##g' "$PROBE" | grep -cE '>[[:space:]]*["$/]' || true)" == 0 ]] ||
    fail "the probe writes to a file"
assert_contains "$probe_code" 'http://169.254.170.2/v4/*)' "the probe accepts only the ECS agent metadata endpoint"
assert_contains "$probe_code" "trap stop TERM INT" "the probe handles SIGTERM as PID 1"

# ---------------------------------------------------------------------------
# Behaviour under the host's POSIX shells
# ---------------------------------------------------------------------------

for shell in "${shells[@]}"; do
    label="$(basename "$shell")"
    output="$work_directory/$label.out"

    started="$(date +%s)"
    run_probe "$shell" "$output" FAKE_WGET_LOG="$work_directory/$label.wget"
    elapsed=$(($(date +%s) - started))
    check_contract_output "$output" "$label"
    ((elapsed <= 4)) || fail "$label: two samples one second apart took ${elapsed}s"
    [[ "$(sort -u "$work_directory/$label.wget")" == "$METADATA_URI/task
$METADATA_URI/task/stats" ]] || fail "$label: the probe fetched something other than /task and /task/stats"

    run_probe "$shell" "$output.absent" ECS_CONTAINER_METADATA_URI_V4=
    assert_contains "$(sed -n 1p "$output.absent")" " metadata=absent " "$label: no endpoint"
    assert_contains "$(sed -n 2p "$output.absent")" " metadata=absent" "$label: no endpoint, sample"
    assert_clean_output "$output.absent" "$label: no endpoint"

    for uri in "http://198.51.100.7/v4/abc" "http://169.254.169.254/latest/meta-data" "http://169.254.170.2/v4/abc?x=1" \
        "http://169.254.170.2/v4/" "https://169.254.170.2/v4/abc"; do
        run_probe "$shell" "$output.other" ECS_CONTAINER_METADATA_URI_V4="$uri" FAKE_WGET_LOG="$work_directory/$label.other.wget"
        assert_contains "$(sed -n 2p "$output.other")" " metadata=absent" "$label: $uri must be ignored"
        [[ ! -e "$work_directory/$label.other.wget" ]] || fail "$label: $uri was fetched"
    done

    run_probe "$shell" "$output.fail" FAKE_METADATA_MODE=fail
    assert_contains "$(sed -n 2p "$output.fail")" " metadata=unavailable" "$label: metadata failure"
    [[ "$(wc -l <"$output.fail" | tr -d ' ')" == 3 ]] || fail "$label: a metadata failure must not stop the probe"
    assert_clean_output "$output.fail" "$label: metadata failure"

    run_probe "$shell" "$output.empty" FAKE_METADATA_MODE=no-stats
    assert_contains "$(sed -n 2p "$output.empty")" " metadata=empty" "$label: no stats"

    run_probe "$shell" "$output.bounds" MEMORY_PROBE_INTERVAL_SECONDS=abc MEMORY_PROBE_FAST_INTERVAL_SECONDS=0 \
        MEMORY_PROBE_FAST_WINDOW_SECONDS=99999999999999999999 MEMORY_PROBE_MAX_SAMPLES=1
    assert_contains "$(sed -n 1p "$output.bounds")" " interval_s=30 fast_interval_s=5 fast_window_s=900" "$label: out-of-range settings fall back"
    [[ "$(wc -l <"$output.bounds" | tr -d ' ')" == 2 ]] || fail "$label: MEMORY_PROBE_MAX_SAMPLES=1"
done

# Degraded host views, under the first shell: PSI off, keys missing, lxcfs over /proc/meminfo.
degraded="$work_directory/degraded"
cp -R "$fixture" "$degraded"
rm "$degraded/proc/pressure/memory" "$degraded/cgroup/memory.peak"
printf 'MemTotal: 3940336 kB\n' >"$degraded/proc/meminfo"
printf '2000 1074 0:70 / /proc/meminfo rw,nosuid,nodev,relatime - fuse.lxcfs lxcfs rw\n' >>"$degraded/proc/self/mountinfo"
# Values that are not numbers or names never pass through as they are.
printf 'abc$(id);x 800.00\n' >"$degraded/proc/uptime"
printf '6.1;rm -rf /\n' >"$degraded/proc/sys/kernel/osrelease"
run_probe /bin/sh "$work_directory/degraded.out" MEMORY_PROBE_PROC_ROOT="$degraded/proc" MEMORY_PROBE_CGROUP_ROOT="$degraded/cgroup"
assert_contains "$(sed -n 1p "$work_directory/degraded.out")" " meminfo_mount=fuse.lxcfs cgroup=v2 psi=unavailable " "lxcfs and PSI-off are reported"
assert_contains "$(sed -n 1p "$work_directory/degraded.out")" "event=start kernel=- " "a kernel string outside the name set prints -"
assert_contains "$(sed -n 2p "$work_directory/degraded.out")" " host_uptime_s=- " "a non-numeric uptime prints -"
assert_contains "$(sed -n 2p "$work_directory/degraded.out")" " MemTotal_kB=3940336 MemFree_kB=- MemAvailable_kB=- " "missing keys print -"
assert_contains "$(sed -n 2p "$work_directory/degraded.out")" " psi=unavailable " "PSI off in a sample"
assert_contains "$(sed -n 2p "$work_directory/degraded.out")" " self_cg_peak_kB=- " "no memory.peak"
assert_clean_output "$work_directory/degraded.out" "degraded"

# SIGTERM while sleeping: the stop is immediate, not a stopTimeout later.
for shell in "${shells[@]}"; do
    output="$work_directory/$(basename "$shell").stop"
    env -i PATH="$fixture/bin:/usr/bin:/bin" MEMORY_PROBE_PROC_ROOT="$fixture/proc" MEMORY_PROBE_CGROUP_ROOT="$fixture/cgroup" \
        MEMORY_PROBE_FAST_INTERVAL_SECONDS=60 "$shell" "$PROBE" >"$output" 2>&1 &
    probe_pid=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q ' seq=1 ' "$output" 2>/dev/null && break; sleep 0.2; done
    started="$(date +%s)"
    kill -TERM "$probe_pid"
    wait "$probe_pid" || fail "$shell: the probe must exit 0 on SIGTERM"
    (($(date +%s) - started <= 2)) || fail "$shell: SIGTERM did not stop the probe promptly"
    assert_contains "$(tail -1 "$output")" "memprobe v=1 event=stop seq=1" "$shell: stop line"
done

# ---------------------------------------------------------------------------
# Inside the pinned image (--image)
# ---------------------------------------------------------------------------

if [[ "$with_image" == "true" ]]; then
    command -v docker >/dev/null 2>&1 || fail "--image needs Docker"
    image="$(sed -n 's/^  ecs_valkey_image *= *"\(valkey\/valkey@sha256:[0-9a-f]\{64\}\)"$/\1/p' "$PINNED_IMAGE_FILE")"
    [[ -n "$image" ]] || fail "no pinned ecs_valkey_image in ecs_application.tf"
    docker pull --quiet "$image" >/dev/null
    # The measurement task's constraints: non-root, read-only root, no capabilities, no new privileges.
    in_image=(docker run --network none --read-only --user 65534:65534 --cap-drop ALL --security-opt no-new-privileges
        -v "$fixture:/fixture:ro" -v "$PROBE:/probe/ecs-memory-probe.sh:ro" --entrypoint /bin/sh)
    fixture_env=(-e PATH=/fixture/bin:/usr/bin:/bin:/usr/sbin:/sbin -e MEMORY_PROBE_PROC_ROOT=/fixture/proc
        -e MEMORY_PROBE_CGROUP_ROOT=/fixture/cgroup -e FAKE_METADATA_DIR=/fixture/metadata
        -e ECS_CONTAINER_METADATA_URI_V4="$METADATA_URI" -e AWS_SECRET_ACCESS_KEY="$PLANTED" -e AWS_SESSION_TOKEN="$PLANTED")

    output="$work_directory/image.out"
    "${in_image[@]}" --rm "${fixture_env[@]}" -e MEMORY_PROBE_MAX_SAMPLES=2 -e MEMORY_PROBE_FAST_INTERVAL_SECONDS=1 \
        "$image" /probe/ecs-memory-probe.sh >"$output" 2>"$output.stderr"
    check_contract_output "$output" "image"
    assert_contains "$(sed -n 1p "$output")" " uid=65534 " "image: runs as 65534"

    # PID 1 and docker stop, the way ECS stops a container: SIGTERM, then SIGKILL after the timeout.
    name="memory-probe-test-$$"
    "${in_image[@]}" -d --name "$name" "${fixture_env[@]}" -e MEMORY_PROBE_FAST_INTERVAL_SECONDS=60 \
        "$image" /probe/ecs-memory-probe.sh >/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do docker logs "$name" 2>&1 | grep -q ' seq=1 ' && break; sleep 0.5; done
    started="$(date +%s)"
    docker stop -t 20 "$name" >/dev/null
    stopped_after=$(($(date +%s) - started))
    stop_output="$(docker logs "$name" 2>&1)"
    exit_code="$(docker inspect -f '{{.State.ExitCode}}' "$name")"
    docker rm "$name" >/dev/null
    ((stopped_after <= 5)) || fail "image: PID 1 ignored SIGTERM (docker stop took ${stopped_after}s)"
    [[ "$exit_code" == 0 ]] || fail "image: exit code $exit_code after SIGTERM"
    assert_contains "$stop_output" "memprobe v=1 event=stop seq=1" "image: stop line"

    # The S0 premise on this Docker host: the container's /proc/meminfo is the host's.
    output="$work_directory/image-host.out"
    "${in_image[@]}" --rm -e MEMORY_PROBE_MAX_SAMPLES=1 "$image" /probe/ecs-memory-probe.sh >"$output" 2>"$output.stderr"
    assert_clean_output "$output" "image (host /proc)"
    assert_contains "$(sed -n 1p "$output")" " meminfo_mount=none " "image: /proc/meminfo is the kernel's file"
    if [[ -r /proc/meminfo ]]; then
        host_total="$(awk '$1 == "MemTotal:" { print $2 }' /proc/meminfo)"
        assert_contains "$(sed -n 2p "$output")" " MemTotal_kB=$host_total " "image: MemTotal inside the container equals the host's"
    fi
fi

printf '[memory-probe-test] PASS (shells: %s%s)\n' "${shells[*]}" "$([[ "$with_image" == "true" ]] && printf ', image' || true)"
