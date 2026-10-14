#!/usr/bin/env bash

# Contract tests for the Phase 6C-5c measurement load driver
# (ecs-measurement-load.sh).
#
# The driver runs only in the measurement task of the separate measurement ECS
# cluster. Its contract: the fixed target http://127.0.0.1:8080, GET only on four
# public read-only paths, at most LOAD_RATE_PER_SECOND requests in any second,
# a readiness wait before and a readiness check at the start of the load, the
# stop rules (5 consecutive failures, more than 5 % 5xx and errors in a report
# interval), immediate exit on SIGTERM, and output that carries numbers and
# fixed words only.
#
# By default the driver runs under the host's /bin/sh, and under dash when it is
# installed, against a fake wget that records every call. --image also runs it
# inside the Valkey image pinned in ecs_application.tf (BusyBox sh, awk, wget),
# with the measurement task's constraints, against a local HTTP server on the
# host network, and stops it as PID 1. --image needs Docker, python3 and a free
# 127.0.0.1:8080.
#
# No AWS call. Runs under bash 3.2 and bash 5.

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly DRIVER="$SCRIPT_DIRECTORY/ecs-measurement-load.sh"
# Read only for the pinned Valkey image digest (--image).
readonly PINNED_IMAGE_FILE="$SCRIPT_DIRECTORY/../../terraform/demo/ecs_application.tf"
readonly PLANTED="PLANTEDsecretVALUE0123456789"
readonly API_PATHS="/api/public/categories
/api/public/products?page=1&size=12
/api/public/products?sort=priceAsc&page=1&size=12
/api/public/products?sort=nameAsc&page=1&size=12"
# The same list on one line, for awk -v (which takes no newline on macOS).
readonly API_PATH_WORDS="$(tr '\n' ' ' <<<"$API_PATHS")"

with_image="false"
case "${1:-}" in
"") ;;
--image) with_image="true" ;;
*) printf 'usage: %s [--image]\n' "$0" >&2; exit 2 ;;
esac

work_directory=""
server_pid=""

cleanup_tests() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
    fi
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-measurement-load-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup_tests EXIT

fail() {
    printf '[measurement-load-test] FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "$3 (expected to find: $2)"
}

assert_absent() {
    [[ "$1" != *"$2"* ]] || fail "$3 (unexpectedly found: $2)"
}

# value_of <line> <key>: the value of key=value in a driver line.
value_of() {
    printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -n 1
}

work_directory="$(mktemp -d /tmp/ec-portfolio-measurement-load-test.XXXXXX)"
fixture="$work_directory/fixture"
mkdir -p "$fixture/bin"

# ---------------------------------------------------------------------------
# The fake wget. It records each call (time, URL, every argument, the proxy it
# would have used) and answers by mode. Status lines go to stderr the way
# BusyBox wget -S prints them.
#   FAKE_READY: up | down | up-once (UP for the first call, DOWN afterwards)
#   FAKE_API:   ok | 503 | 404 | refused | redirect | every-fourth-fails
# ---------------------------------------------------------------------------

cat >"$fixture/bin/wget" <<'EOF'
#!/bin/sh
url=""
for argument in "$@"; do url="$argument"; done
printf '%s\t%s\t%s\t%s\n' "$(date +%s)" "$url" "$*" "${http_proxy:-}${HTTP_PROXY:-}" >>"$FAKE_WGET_LOG"
case "$url" in
*/actuator/health/readiness)
    mode="${FAKE_READY:-up}"
    if [ "$mode" = up-once ]; then
        if [ -e "$FAKE_STATE_DIR/ready-used" ]; then mode=down; else : >"$FAKE_STATE_DIR/ready-used"; mode=up; fi
    fi
    if [ "$mode" = up ]; then printf '{"status":"UP","groups":["liveness","readiness"]}'; exit 0; fi
    printf 'wget: server returned error: HTTP/1.1 503 Service Unavailable\n' >&2
    exit 1
    ;;
esac
count=0
[ -e "$FAKE_STATE_DIR/api-count" ] && count="$(cat "$FAKE_STATE_DIR/api-count")"
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_STATE_DIR/api-count"
mode="${FAKE_API:-ok}"
if [ "$mode" = every-fourth-fails ]; then
    if [ $((count % 4)) -eq 0 ]; then mode=503; else mode=ok; fi
fi
case "$mode" in
ok) printf '  HTTP/1.1 200 \n  Content-Type: application/json\n' >&2; exit 0 ;;
redirect) printf '  HTTP/1.1 302 Found\n  Location: /x\n  HTTP/1.1 200 OK\n' >&2; exit 0 ;;
503) printf '  HTTP/1.1 503 Service Unavailable\nwget: server returned error: HTTP/1.1 503 Service Unavailable\n' >&2; exit 1 ;;
404) printf '  HTTP/1.1 404 Not Found\nwget: server returned error: HTTP/1.1 404 Not Found\n' >&2; exit 1 ;;
refused) printf "wget: can't connect to remote host (127.0.0.1): Connection refused\n" >&2; exit 1 ;;
esac
exit 1
EOF
chmod 755 "$fixture/bin/wget"

# run_driver <shell> <output> [VAR=value ...]: a short run against the fake wget.
# The environment also carries values shaped like credentials, a proxy and
# target overrides: none may be used or printed.
run_driver() {
    local shell="$1" output="$2"
    shift 2
    rm -rf "$output.state"
    mkdir -p "$output.state"
    : >"$output.wget"
    env -i PATH="$fixture/bin:/usr/bin:/bin:/usr/sbin:/sbin" HOME=/nonexistent \
        FAKE_WGET_LOG="$output.wget" FAKE_STATE_DIR="$output.state" \
        LOAD_RATE_PER_SECOND=2 LOAD_START_DELAY_SECONDS=1 LOAD_DURATION_SECONDS=3 \
        LOAD_READY_TIMEOUT_SECONDS=5 LOAD_REPORT_INTERVAL_SECONDS=1 LOAD_READY_POLL_SECONDS=1 \
        AWS_SECRET_ACCESS_KEY="$PLANTED" AWS_SESSION_TOKEN="$PLANTED" ORIGIN_VERIFY_TOKEN="$PLANTED" \
        LOAD_TARGET="http://198.51.100.7:8080" TARGET="http://198.51.100.7:8080" API_URL="http://198.51.100.7" \
        http_proxy="http://198.51.100.9:3128" HTTP_PROXY="http://198.51.100.9:3128" \
        "$@" "$shell" "$DRIVER" >"$output" 2>"$output.stderr"
}

# Every line is "loaddriver v=1" and key=value tokens over a fixed character set,
# stderr is empty and nothing planted reaches the output.
assert_clean_output() {
    local output="$1" label="$2" content
    content="$(cat "$output")"
    [[ ! -s "$output.stderr" ]] || fail "$label: stderr is not empty: $(head -3 "$output.stderr")"
    awk '{ if ($1 != "loaddriver" || $2 != "v=1") exit 1; for (i = 2; i <= NF; i++) if ($i !~ /^[a-z0-9_]+=[A-Za-z0-9_.-]+$/) exit 1 }' "$output" ||
        fail "$label: a line outside the driver format: $(head -3 "$output")"
    for planted in "$PLANTED" "198.51.100" "http" "127.0.0.1" "api/public" "status"; do
        assert_absent "$content" "$planted" "$label: a request, response or environment value reached the output"
    done
}

# Every recorded call is a GET of the fixed target: the readiness path or one of
# the four public paths, with the driver's user agent, no method, header or body
# option, and no proxy left in the environment.
assert_requests_contract() {
    local output="$1" label="$2"
    awk -F '\t' -v paths="$API_PATH_WORDS" '
        BEGIN { n = split(paths, p, " "); for (i = 1; i <= n; i++) allowed["http://127.0.0.1:8080" p[i]] = 1
                allowed["http://127.0.0.1:8080/actuator/health/readiness"] = 1 }
        !($2 in allowed) { print "unexpected URL: " $2; bad = 1 }
        $3 !~ /-U ec-portfolio-measurement-load / { print "no user agent: " $3; bad = 1 }
        $3 ~ /--post|--method|--header|--body|-X |--spider/ { print "not a plain GET: " $3; bad = 1 }
        $4 != "" { print "a proxy reached wget"; bad = 1 }
        END { exit bad }
    ' "$output.wget" >"$output.contract" || fail "$label: request contract: $(head -3 "$output.contract")"
}

api_requests() {
    awk -F '\t' '$2 !~ /readiness$/' "$1.wget" | wc -l | tr -d ' '
}

# The driver starts at most <rate> requests in each second of its own clock. The
# fake wget stamps a request a few milliseconds later, on its own clock, so a
# request started at the very end of a second can land in the next one: one
# more than <rate> is tolerated there, never two, and the total over the whole
# load stays within <rate> per second.
assert_rate_bound() {
    local output="$1" rate="$2" label="$3" busiest first final total
    busiest="$(awk -F '\t' '$2 !~ /readiness$/ { n[$1]++ } END { m = 0; for (s in n) if (n[s] > m) m = n[s]; print m }' "$output.wget")"
    ((busiest <= rate + 1)) || fail "$label: $busiest requests in one second, more than $rate"
    first="$(awk -F '\t' '$2 !~ /readiness$/ { print $1; exit }' "$output.wget")"
    final="$(awk -F '\t' '$2 !~ /readiness$/ { t = $1 } END { print t }' "$output.wget")"
    total="$(api_requests "$output")"
    ((total <= rate * (final - first + 1))) || fail "$label: $total requests over $((final - first + 1)) s at $rate/s"
}

shells=(/bin/sh)
[[ -x /bin/dash ]] && shells+=(/bin/dash)
command -v dash >/dev/null 2>&1 && [[ "$(command -v dash)" != /bin/dash ]] && shells+=("$(command -v dash)")

# ---------------------------------------------------------------------------
# Static contract: the driver script
# ---------------------------------------------------------------------------

driver_code="$(sed -e 's/^[[:space:]]*#.*$//' "$DRIVER")"
for forbidden in "printenv" "env " "set -x" "/environ" "169.254" "curl" "nc " "tee " "rm " "mkdir" ">>" \
    "--post" "--method" "--header" "LOAD_TARGET" "API_URL" "eval "; do
    assert_absent "$driver_code" "$forbidden" "the driver must stay a read-only GET client of the fixed target"
done
[[ "$(sed -e 's/^[[:space:]]*#.*$//' -e 's#2>/dev/null##g' -e 's#>/dev/null##g' -e 's#2>&1##g' -e 's#>&2##g' "$DRIVER" |
    grep -cE '>[[:space:]]*["$/]' || true)" == 0 ]] || fail "the driver writes to a file"
[[ "$(grep -c '^TARGET="http://127.0.0.1:8080"$' "$DRIVER")" == 1 ]] || fail "the target must be the one fixed loopback URL"
[[ "$(grep -oE 'LOAD_[A-Z_]+' <<<"$driver_code" | sort -u | tr '\n' ' ')" == \
    "LOAD_DURATION_SECONDS LOAD_RATE_PER_SECOND LOAD_READY_POLL_SECONDS LOAD_READY_TIMEOUT_SECONDS LOAD_REPORT_INTERVAL_SECONDS LOAD_START_DELAY_SECONDS " ]] ||
    fail "the driver reads a setting outside its documented list"
assert_contains "$driver_code" "trap stop TERM INT" "the driver handles SIGTERM as PID 1"
while IFS= read -r path; do
    assert_contains "$driver_code" "echo \"$path\"" "the driver must use the four reviewed paths"
done <<<"$API_PATHS"
[[ "$(grep -c 'echo "/api/' "$DRIVER")" == 4 ]] || fail "the driver must use exactly four API paths"

# ---------------------------------------------------------------------------
# Behaviour under the host's POSIX shells
# ---------------------------------------------------------------------------

for shell in "${shells[@]}"; do
    label="$(basename "$shell")"
    output="$work_directory/$label.out"

    # A full short run: ready, idle until the start delay, 3 seconds of load.
    started="$(date +%s)"
    run_driver "$shell" "$output"
    elapsed=$(($(date +%s) - started))
    assert_clean_output "$output" "$label"
    assert_requests_contract "$output" "$label"
    assert_rate_bound "$output" 2 "$label"
    ((elapsed <= 10)) || fail "$label: a 1 s delay and 3 s of load took ${elapsed}s"
    config="$(sed -n 1p "$output")"
    assert_contains "$config" "loaddriver v=1 event=config rate=2 start_delay_s=1 duration_s=3 ready_timeout_s=5 report_s=1 tick=" "$label: config line"
    assert_contains "$config" " planned=6" "$label: planned requests"
    assert_contains "$(sed -n 2p "$output")" "loaddriver v=1 event=ready t=" "$label: ready line"
    assert_contains "$(sed -n 3p "$output")" "loaddriver v=1 event=started t=" "$label: started line"
    last="$(tail -n 1 "$output")"
    assert_contains "$last" "loaddriver v=1 event=done " "$label: the load completes"
    total="$(value_of "$last" total_req)"
    ((total >= 2 && total <= 8)) || fail "$label: total_req=$total outside 2..8 for 3 s at 2/s"
    [[ "$(value_of "$last" total_2xx)" == "$total" ]] || fail "$label: every request should be 2xx"
    [[ "$total" == "$(api_requests "$output")" ]] || fail "$label: total_req differs from the requests made"
    grep -q 'event=report .* req=[1-9]' "$output" || fail "$label: no report line with requests"
    [[ "$(awk -F '\t' '$2 !~ /readiness$/ { print $2 }' "$output.wget" | head -n 4)" == \
        "$(sed 's#^#http://127.0.0.1:8080#' <<<"$API_PATHS")" ]] ||
        fail "$label: the four paths are not used in turn"

    # A redirect is followed to its final status.
    run_driver "$shell" "$output.redirect" FAKE_API=redirect LOAD_DURATION_SECONDS=1
    assert_contains "$(tail -n 1 "$output.redirect")" "event=done" "$label: redirect"
    [[ "$(value_of "$(tail -n 1 "$output.redirect")" total_2xx)" == "$(value_of "$(tail -n 1 "$output.redirect")" total_req)" ]] ||
        fail "$label: the final status after a redirect is the one counted"

    # 5xx: stopped after exactly 5 consecutive failures, never retried.
    run_driver "$shell" "$output.503" FAKE_API=503 LOAD_DURATION_SECONDS=10 LOAD_REPORT_INTERVAL_SECONDS=10
    assert_clean_output "$output.503" "$label: 503"
    assert_contains "$(tail -n 1 "$output.503")" "loaddriver v=1 event=aborted-consecutive-failures " "$label: 503 stops the load"
    [[ "$(api_requests "$output.503")" == 5 ]] || fail "$label: 503 must stop after 5 requests, made $(api_requests "$output.503")"
    grep -q 'event=report .* s5xx=' "$output.503" || fail "$label: 503 report line"

    # 4xx counts as a failure as well: a wrong path is not a load.
    run_driver "$shell" "$output.404" FAKE_API=404 LOAD_DURATION_SECONDS=10 LOAD_REPORT_INTERVAL_SECONDS=10
    assert_contains "$(tail -n 1 "$output.404")" "event=aborted-consecutive-failures" "$label: 404 stops the load"
    grep -q 'event=report .* s4xx=[1-9]' "$output.404" || fail "$label: 404 counted as 4xx"

    # Refused connections are errors.
    run_driver "$shell" "$output.refused" FAKE_API=refused LOAD_DURATION_SECONDS=10 LOAD_REPORT_INTERVAL_SECONDS=10
    assert_contains "$(tail -n 1 "$output.refused")" "event=aborted-consecutive-failures" "$label: refused stops the load"
    grep -q 'event=report .* err=[1-9]' "$output.refused" || fail "$label: refused counted as an error"

    # Sporadic 5xx above 5 % of an interval stops the load, without 5 in a row.
    run_driver "$shell" "$output.rate" FAKE_API=every-fourth-fails LOAD_DURATION_SECONDS=10
    assert_contains "$(tail -n 1 "$output.rate")" "loaddriver v=1 event=aborted-error-rate " "$label: error rate stops the load"
    (($(api_requests "$output.rate") < 20)) || fail "$label: the error-rate stop came too late"

    # Never ready: no API request at all.
    run_driver "$shell" "$output.never" FAKE_READY=down LOAD_READY_TIMEOUT_SECONDS=2
    assert_contains "$(tail -n 1 "$output.never")" "loaddriver v=1 event=never-ready " "$label: never ready"
    [[ "$(api_requests "$output.never")" == 0 ]] || fail "$label: requests sent to an API that never became ready"
    assert_clean_output "$output.never" "$label: never ready"

    # Ready, then not ready when the load would start: no API request.
    run_driver "$shell" "$output.lost" FAKE_READY=up-once
    assert_contains "$(tail -n 1 "$output.lost")" "loaddriver v=1 event=not-ready-at-start " "$label: not ready at start"
    [[ "$(api_requests "$output.lost")" == 0 ]] || fail "$label: requests sent after readiness was lost"

    # Out-of-range settings fall back to the defaults; the rate is capped at 5.
    run_driver "$shell" "$output.bounds" FAKE_READY=down LOAD_READY_TIMEOUT_SECONDS=1 \
        LOAD_RATE_PER_SECOND=50 LOAD_START_DELAY_SECONDS=abc LOAD_DURATION_SECONDS=0 LOAD_REPORT_INTERVAL_SECONDS=99999999999
    assert_contains "$(sed -n 1p "$output.bounds")" " rate=2 start_delay_s=1800 duration_s=1200 ready_timeout_s=1 report_s=60 " \
        "$label: out-of-range settings fall back"
    assert_contains "$(sed -n 1p "$output.bounds")" " planned=2400" "$label: planned requests at the defaults"
    run_driver "$shell" "$output.max" LOAD_RATE_PER_SECOND=5 LOAD_START_DELAY_SECONDS=0 LOAD_DURATION_SECONDS=2
    assert_rate_bound "$output.max" 5 "$label: rate 5"
    assert_contains "$(tail -n 1 "$output.max")" "event=done" "$label: rate 5 completes"
done

# SIGTERM while idle: the stop is immediate, not a stopTimeout later.
for shell in "${shells[@]}"; do
    output="$work_directory/$(basename "$shell").stop"
    mkdir -p "$output.state"
    env -i PATH="$fixture/bin:/usr/bin:/bin" FAKE_WGET_LOG="$output.wget" FAKE_STATE_DIR="$output.state" \
        LOAD_START_DELAY_SECONDS=60 LOAD_READY_POLL_SECONDS=1 "$shell" "$DRIVER" >"$output" 2>&1 &
    driver_pid=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'event=ready' "$output" 2>/dev/null && break; sleep 0.3; done
    grep -q 'event=ready' "$output" || fail "$shell: the driver did not become ready"
    started="$(date +%s)"
    kill -TERM "$driver_pid"
    wait "$driver_pid" || fail "$shell: the driver must exit 0 on SIGTERM"
    (($(date +%s) - started <= 2)) || fail "$shell: SIGTERM did not stop the driver promptly"
    assert_contains "$(tail -n 1 "$output")" "loaddriver v=1 event=stopped " "$shell: stop line"
done

# ---------------------------------------------------------------------------
# Inside the pinned image (--image)
# ---------------------------------------------------------------------------

if [[ "$with_image" == "true" ]]; then
    command -v docker >/dev/null 2>&1 || fail "--image needs Docker"
    command -v python3 >/dev/null 2>&1 || fail "--image needs python3"
    image="$(sed -n 's/^  ecs_valkey_image *= *"\(valkey\/valkey@sha256:[0-9a-f]\{64\}\)"$/\1/p' "$PINNED_IMAGE_FILE")"
    [[ -n "$image" ]] || fail "no pinned ecs_valkey_image in ecs_application.tf"
    docker pull --quiet "$image" >/dev/null

    # A local HTTP server on 127.0.0.1:8080 of the host network, which the
    # container shares, as the measurement task shares the host's. It logs the
    # method, path and user agent of every request and answers by its mode.
    cat >"$work_directory/server.py" <<'EOF'
import http.server, sys
mode, log = sys.argv[1], sys.argv[2]
class Handler(http.server.BaseHTTPRequestHandler):
    def respond(self):
        with open(log, "a") as f:
            f.write(f"{self.command}\t{self.path}\t{self.headers.get('User-Agent', '')}\n")
        if self.path == "/actuator/health/readiness":
            code, body = 200, b'{"status":"UP"}'
        else:
            code, body = (200, b'{"items":[]}') if mode == "ok" else (503, b'{"status":503}')
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
    do_GET = respond
    do_POST = respond
    def log_message(self, *args):
        pass
http.server.HTTPServer(("127.0.0.1", 8080), Handler).serve_forever()
EOF

    start_server() {
        : >"$work_directory/server-$1.log"
        python3 "$work_directory/server.py" "$1" "$work_directory/server-$1.log" &
        server_pid=$!
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            python3 -c 'import socket; socket.create_connection(("127.0.0.1", 8080), 1).close()' 2>/dev/null && return 0
            sleep 0.3
        done
        fail "the test HTTP server did not start on 127.0.0.1:8080"
    }

    stop_server() {
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
        server_pid=""
    }

    # The measurement task's constraints: non-root, read-only root, no
    # capabilities, no new privileges; the host network, as in the task.
    in_image=(docker run --network host --read-only --user 65534:65534 --cap-drop ALL --security-opt no-new-privileges
        -v "$DRIVER:/driver/ecs-measurement-load.sh:ro" --entrypoint /bin/sh
        -e LOAD_READY_TIMEOUT_SECONDS=10 -e LOAD_READY_POLL_SECONDS=1 -e LOAD_REPORT_INTERVAL_SECONDS=1
        -e AWS_SECRET_ACCESS_KEY="$PLANTED" -e http_proxy="http://198.51.100.9:3128")

    start_server ok
    output="$work_directory/image.out"
    "${in_image[@]}" --rm -e LOAD_START_DELAY_SECONDS=0 -e LOAD_DURATION_SECONDS=3 \
        "$image" /driver/ecs-measurement-load.sh >"$output" 2>"$output.stderr"
    stop_server
    assert_clean_output "$output" "image"
    assert_contains "$(sed -n 1p "$output")" " tick=0.2 " "image: BusyBox sleep takes a fraction"
    last="$(tail -n 1 "$output")"
    assert_contains "$last" "loaddriver v=1 event=done " "image: the load completes against a real server"
    total="$(value_of "$last" total_req)"
    ((total >= 2)) || fail "image: total_req=$total"
    [[ "$(value_of "$last" total_2xx)" == "$total" ]] || fail "image: BusyBox wget 200s must count as 2xx"
    awk -F '\t' -v paths="$API_PATH_WORDS" '
        BEGIN { n = split(paths, p, " "); for (i = 1; i <= n; i++) allowed[p[i]] = 1; allowed["/actuator/health/readiness"] = 1 }
        $1 != "GET" || !($2 in allowed) || $3 != "ec-portfolio-measurement-load" { print; bad = 1 }
        END { exit bad }
    ' "$work_directory/server-ok.log" || fail "image: a request other than a GET of a reviewed path"

    start_server 503
    output="$work_directory/image-503.out"
    "${in_image[@]}" --rm -e LOAD_START_DELAY_SECONDS=0 -e LOAD_DURATION_SECONDS=10 -e LOAD_REPORT_INTERVAL_SECONDS=10 \
        "$image" /driver/ecs-measurement-load.sh >"$output" 2>"$output.stderr"
    stop_server
    assert_clean_output "$output" "image 503"
    assert_contains "$(tail -n 1 "$output")" "event=aborted-consecutive-failures" "image: BusyBox wget 503s stop the load"
    grep -q 'event=report .* s5xx=5 ' "$output" || fail "image: BusyBox wget 503s must count as 5xx"

    # PID 1 and docker stop, the way ECS stops a container.
    start_server ok
    name="measurement-load-test-$$"
    "${in_image[@]}" -d --name "$name" -e LOAD_START_DELAY_SECONDS=60 "$image" /driver/ecs-measurement-load.sh >/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do docker logs "$name" 2>&1 | grep -q 'event=ready' && break; sleep 0.5; done
    started="$(date +%s)"
    docker stop -t 20 "$name" >/dev/null
    stopped_after=$(($(date +%s) - started))
    stop_output="$(docker logs "$name" 2>&1)"
    exit_code="$(docker inspect -f '{{.State.ExitCode}}' "$name")"
    docker rm "$name" >/dev/null
    stop_server
    ((stopped_after <= 5)) || fail "image: PID 1 ignored SIGTERM (docker stop took ${stopped_after}s)"
    [[ "$exit_code" == 0 ]] || fail "image: exit code $exit_code after SIGTERM"
    assert_contains "$stop_output" "loaddriver v=1 event=stopped " "image: stop line"
fi

printf '[measurement-load-test] PASS (shells: %s%s)\n' "${shells[*]}" "$([[ "$with_image" == "true" ]] && printf ', image' || true)"
