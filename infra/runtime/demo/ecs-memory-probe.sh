#!/bin/sh
# Phase 6C-5c S0: a read-only memory probe, meant to run as a non-essential
# container of the measurement task in a separate measurement ECS cluster, next
# to the same API and Valkey containers. It is not part of the production task
# definition. Every interval it writes one line to stdout, which the awslogs
# driver ships to the task's log group:
#
#   memprobe v=1 seq=<n> t=<UTC> elapsed_s=<since start> host_uptime_s=... MemTotal_kB=... ...
#
# It reads only:
#   - /proc/meminfo, /proc/vmstat, /proc/pressure/memory, /proc/stat and
#     /proc/uptime. The kernel does not namespace these, so inside the container
#     they show the whole host -- unless something such as lxcfs is mounted over
#     /proc/meminfo, which the start line reports (meminfo_mount=) so a reader
#     can tell. Whether that holds on the ECS-optimized AMI is checked during the
#     Spot rehearsal, not assumed here.
#   - /sys/fs/cgroup/memory.*: this container's own cgroup (Docker's private
#     cgroup namespace on cgroup v2), i.e. the probe's own footprint.
#   - ${ECS_CONTAINER_METADATA_URI_V4}/task and /task/stats: the task's container
#     names and their Docker memory stats, served by the ECS agent on the
#     link-local metadata address 169.254.170.2. That is not IMDS: the IMDS
#     guard rejects this non-root UID at 169.254.169.254, and nothing here goes
#     there. Any other metadata URI is ignored.
#
# Nothing is written to disk (the root filesystem is read-only) and no
# environment variable is printed. Every printed value is reduced to a fixed
# character set first -- numbers to [0-9.], container names to [A-Za-z0-9_-] --
# so a credential, token or session ID cannot reach the log. The metadata
# documents carry ARNs (and so the account ID); only container names and memory
# counters are taken from them.
#
# Settings (environment; integer seconds; out-of-range values fall back to the default):
#   MEMORY_PROBE_INTERVAL_SECONDS       steady interval, default 30 (5..3600)
#   MEMORY_PROBE_FAST_INTERVAL_SECONDS  interval inside the start window, default 5 (1..60)
#   MEMORY_PROBE_FAST_WINDOW_SECONDS    start window that covers the cold start, default 900 (0..7200)
# Test seams (the task definition sets none of them): MEMORY_PROBE_PROC_ROOT,
# MEMORY_PROBE_CGROUP_ROOT and MEMORY_PROBE_MAX_SAMPLES (stop after that many lines).
#
# POSIX sh and awk only: the image is BusyBox (ash, awk, wget).
set -u

PROC="${MEMORY_PROBE_PROC_ROOT:-/proc}"
CGROUP="${MEMORY_PROBE_CGROUP_ROOT:-/sys/fs/cgroup}"

# bounded <value> <default> <min> <max>
bounded() {
    case "$1" in '' | *[!0-9]*) echo "$2"; return ;; esac
    if [ "${#1}" -gt 5 ] || [ "$1" -lt "$3" ] || [ "$1" -gt "$4" ]; then echo "$2"; else echo "$1"; fi
}
INTERVAL="$(bounded "${MEMORY_PROBE_INTERVAL_SECONDS:-}" 30 5 3600)"
FAST_INTERVAL="$(bounded "${MEMORY_PROBE_FAST_INTERVAL_SECONDS:-}" 5 1 60)"
FAST_WINDOW="$(bounded "${MEMORY_PROBE_FAST_WINDOW_SECONDS:-}" 900 0 7200)"
MAX_SAMPLES="$(bounded "${MEMORY_PROBE_MAX_SAMPLES:-}" 0 0 99999)"

# Only the ECS agent's link-local v4 endpoint, with a plain container ID path.
METADATA="${ECS_CONTAINER_METADATA_URI_V4:-}"
case "$METADATA" in
http://169.254.170.2/v4/*)
    case "${METADATA#http://169.254.170.2/v4/}" in '' | *[!A-Za-z0-9-]*) METADATA="" ;; esac
    ;;
*) METADATA="" ;;
esac

num() { case "$1" in '' | *[!0-9.]*) echo "-" ;; *) echo "$1" ;; esac; }
name() { case "$1" in '' | *[!A-Za-z0-9_.-]*) echo "-" ;; *) echo "$1" ;; esac; }

# " MemTotal_kB=... MemAvailable_kB=..." in a fixed order; "-" for a missing key.
meminfo() {
    awk '
        BEGIN { n = split("MemTotal MemFree MemAvailable Buffers Cached SwapCached AnonPages Shmem Slab SReclaimable SUnreclaim KernelStack PageTables SwapTotal SwapFree Committed_AS", k, " ") }
        { sub(/:$/, "", $1); if ($2 ~ /^[0-9]+$/) v[$1] = $2 }
        END { for (i = 1; i <= n; i++) printf " %s_kB=%s", k[i], ((k[i] in v) ? v[k[i]] : "-") }
    ' "$PROC/meminfo" 2>/dev/null
}

vmstat() {
    awk '
        BEGIN { n = split("oom_kill pswpin pswpout pgmajfault", k, " ") }
        $2 ~ /^[0-9]+$/ { v[$1] = $2 }
        END { for (i = 1; i <= n; i++) printf " vm_%s=%s", k[i], ((k[i] in v) ? v[k[i]] : "-") }
    ' "$PROC/vmstat" 2>/dev/null
}

# " psi_some_avg10=... psi_full_total=..." or " psi=unavailable" (PSI off in the kernel).
psi() {
    [ -r "$PROC/pressure/memory" ] || { printf ' psi=unavailable'; return; }
    awk '
        $1 == "some" || $1 == "full" {
            for (i = 2; i <= NF; i++) {
                split($i, kv, "=")
                if ((kv[1] == "avg10" || kv[1] == "avg60" || kv[1] == "total") && kv[2] ~ /^[0-9.]+$/) printf " psi_%s_%s=%s", $1, kv[1], kv[2]
            }
        }
    ' "$PROC/pressure/memory" 2>/dev/null
}

# Cumulative ticks of the first /proc/stat line: total (user..steal), idle (+ iowait), steal.
# Steal is where a T3 host held at its CPU credit baseline shows up.
cpu() {
    awk '
        $1 == "cpu" {
            t = 0; for (i = 2; i <= 9 && i <= NF; i++) t += $i
            printf " cpu_total_ticks=%d cpu_idle_ticks=%d cpu_steal_ticks=%d", t, $5 + $6, (NF >= 9 ? $9 : 0)
            exit
        }
    ' "$PROC/stat" 2>/dev/null
}

# This container's own cgroup, in kB.
self_cgroup() {
    current="$(cat "$CGROUP/memory.current" 2>/dev/null)"
    peak="$(cat "$CGROUP/memory.peak" 2>/dev/null)"
    oom_kill="$(awk '$1 == "oom_kill" { print $2 }' "$CGROUP/memory.events" 2>/dev/null)"
    case "$current" in '' | *[!0-9]*) current="-" ;; *) current=$((current / 1024)) ;; esac
    case "$peak" in '' | *[!0-9]*) peak="-" ;; *) peak=$((peak / 1024)) ;; esac
    printf ' self_cg_current_kB=%s self_cg_peak_kB=%s self_cg_oom_kill=%s' "$current" "$peak" "$(num "$oom_kill")"
}

# Flattens a JSON document to "<tag>\t<dot.path>\t<scalar>" lines. Arrays are indexed from 0.
# Strings keep their escapes; nothing is unescaped or evaluated.
json_flatten() {
    awk -v tag="$1" '
        function path(   p, k) { p = ""; for (k = 1; k <= d; k++) p = p (k > 1 ? "." : "") (t[k] == "o" ? key[k] : idx[k]); return p }
        { s = s $0 "\n" }
        END {
            n = length(s); i = 1; d = 0
            while (i <= n) {
                c = substr(s, i, 1)
                if (c == "{") { d++; t[d] = "o"; key[d] = ""; expect_key[d] = 1; i++ }
                else if (c == "[") { d++; t[d] = "a"; idx[d] = 0; i++ }
                else if (c == "}" || c == "]") { if (d > 0) d--; i++ }
                else if (c == ",") { if (t[d] == "a") idx[d]++; else expect_key[d] = 1; i++ }
                else if (c == ":") { expect_key[d] = 0; i++ }
                else if (c == "\"") {
                    j = i + 1
                    while (j <= n) { ch = substr(s, j, 1); if (ch == "\\") j += 2; else if (ch == "\"") break; else j++ }
                    v = substr(s, i + 1, j - i - 1); i = j + 1
                    if (d > 0 && t[d] == "o" && expect_key[d]) key[d] = v
                    else print tag "\t" path() "\t" v
                }
                else if (index(" \t\r\n", c) > 0) i++
                else {
                    j = i
                    while (j <= n && index(",}] \t\r\n", substr(s, j, 1)) == 0) j++
                    print tag "\t" path() "\t" substr(s, i, j - i); i = j
                }
            }
        }
    '
}

fetch() { wget -q -T 2 -O - "$METADATA/$1" 2>/dev/null; }

# " metadata=ok c_<container>_<counter>_kB=..." from the task's Docker stats, or " metadata=<why not>".
task_memory() {
    [ -n "$METADATA" ] || { printf ' metadata=absent'; return; }
    task_doc="$(fetch task)" || { printf ' metadata=unavailable'; return; }
    stats_doc="$(fetch task/stats)" || { printf ' metadata=unavailable'; return; }
    {
        printf '%s\n' "$task_doc" | json_flatten T
        printf '%s\n' "$stats_doc" | json_flatten S
    } | awk -F '\t' '
        BEGIN { m = split("anon file inactive_file active_file shmem slab kernel_stack sock rss cache total_inactive_file", c, " "); for (i = 1; i <= m; i++) counter[c[i]] = 1 }
        $1 == "T" && $2 ~ /^Containers\.[0-9]+\.(DockerId|Name)$/ { split($2, p, "."); if (p[3] == "DockerId") id[p[2]] = $3; else nm[p[2]] = $3; next }
        $1 == "S" {
            if (!names_done) { for (k in id) if (id[k] ~ /^[0-9a-f]+$/ && nm[k] ~ /^[A-Za-z0-9_-]+$/) container[id[k]] = nm[k]; names_done = 1 }
            n = split($2, p, ".")
            if (n < 3 || p[2] != "memory_stats" || !(p[1] in container) || $3 !~ /^[0-9]+$/) next
            if (n == 3 && (p[3] == "usage" || p[3] == "limit")) out[container[p[1]] "_" p[3]] = $3
            else if (n == 4 && p[3] == "stats" && (p[4] in counter)) out[container[p[1]] "_" p[4]] = $3
        }
        END { for (k in out) printf "c_%s_kB=%d\n", k, int(out[k] / 1024) }
    ' | sort | awk '{ line = line " " $0 } END { if (line == "") printf " metadata=empty"; else printf " metadata=ok%s", line }'
}

# Is /proc/meminfo its own mount (lxcfs or similar)? "none" when it is the kernel's procfs file.
meminfo_mount() {
    awk '
        $5 == "/proc/meminfo" { for (i = 7; i <= NF; i++) if ($i == "-") { print $(i + 1); found = 1; exit } }
        END { if (!found) print "none" }
    ' "$PROC/self/mountinfo" 2>/dev/null
}

start_line() {
    kernel="$(cat "$PROC/sys/kernel/osrelease" 2>/dev/null)"
    cpus="$(awk '/^processor[ \t]*:/ { n++ } END { print n + 0 }' "$PROC/cpuinfo" 2>/dev/null)"
    cgroup_kind="none"
    [ -r "$CGROUP/cgroup.controllers" ] && cgroup_kind="v2"
    [ "$cgroup_kind" = none ] && [ -r "$CGROUP/memory/memory.usage_in_bytes" ] && cgroup_kind="v1"
    pressure="available"
    [ -r "$PROC/pressure/memory" ] || pressure="unavailable"
    meta="configured"
    [ -n "$METADATA" ] || meta="absent"
    printf 'memprobe v=1 event=start kernel=%s nproc=%s uid=%s meminfo_mount=%s cgroup=%s psi=%s metadata=%s interval_s=%s fast_interval_s=%s fast_window_s=%s\n' \
        "$(name "$kernel")" "$(num "$cpus")" "$(num "$(id -u)")" "$(name "$(meminfo_mount)")" "$cgroup_kind" "$pressure" "$meta" \
        "$INTERVAL" "$FAST_INTERVAL" "$FAST_WINDOW"
}

sleeper=""
stop() {
    [ -n "$sleeper" ] && kill "$sleeper" 2>/dev/null
    printf 'memprobe v=1 event=stop seq=%s\n' "$seq"
    exit 0
}

seq=0
# ECS stops a container with SIGTERM. As PID 1 the shell would ignore it and hold the task's stop
# for stopTimeout; the trap, and sleeping in the background, make the stop immediate.
trap stop TERM INT
start_line
started="$(date +%s)"
while :; do
    seq=$((seq + 1))
    now="$(date +%s)"
    elapsed=$((now - started))
    uptime="$(awk '{ print $1; exit }' "$PROC/uptime" 2>/dev/null)"
    printf 'memprobe v=1 seq=%s t=%s elapsed_s=%s host_uptime_s=%s%s%s%s%s%s%s\n' \
        "$seq" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$elapsed" "$(num "$uptime")" \
        "$(meminfo)" "$(vmstat)" "$(psi)" "$(cpu)" "$(self_cgroup)" "$(task_memory)"
    [ "$MAX_SAMPLES" -gt 0 ] && [ "$seq" -ge "$MAX_SAMPLES" ] && exit 0
    if [ "$elapsed" -lt "$FAST_WINDOW" ]; then pause="$FAST_INTERVAL"; else pause="$INTERVAL"; fi
    sleep "$pause" &
    sleeper=$!
    wait "$sleeper"
    sleeper=""
done
