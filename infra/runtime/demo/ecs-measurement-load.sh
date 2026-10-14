#!/bin/sh
# Phase 6C-5c: a read-only load driver, meant to run as a non-essential container
# of the measurement task in the separate measurement ECS cluster, next to the
# API, Valkey and the memory probe. It is not part of the production task
# definition, and it is not in the Spot runtime bundle.
#
# The measurement host is reachable from nowhere: no DNS name or Elastic IP
# points at it, and its security group admits HTTPS only from CloudFront. So the
# load comes from inside the task. The API binds 127.0.0.1:8080 on the host
# network, and the origin token is checked by Nginx, not by the API, so the
# driver calls the API directly and holds no token.
#
#   - Target: http://127.0.0.1:8080, fixed here; no setting changes it.
#   - GET only, on four public read-only endpoints (read-only transactions in
#     the API, served from the database), in turn. No login, no cart, no admin,
#     no write.
#   - At most LOAD_RATE_PER_SECOND requests in any wall-clock second, one at a
#     time, each with a 5-second timeout.
#   - Timeline from its own start: wait for the API's readiness (at most
#     LOAD_READY_TIMEOUT_SECONDS), stay idle until LOAD_START_DELAY_SECONDS,
#     check readiness again, then load for LOAD_DURATION_SECONDS and exit 0.
#   - Stops the load on 5 consecutive failed requests, or when 5xx responses and
#     errors exceed 5 % of a report interval. It never retries.
#
# One line per event and per report interval goes to stdout, which awslogs
# ships to the measurement log group:
#
#   loaddriver v=1 event=report t=<s since start> win_s=60 req=.. s2xx=.. s4xx=.. s5xx=.. err=.. total_req=.. total_2xx=..
#
# Every printed value is a number or a fixed word. Response bodies, headers and
# the environment are never printed, and nothing is written to disk (the root
# filesystem is read-only).
#
# Settings (environment; integer; out-of-range values fall back to the default):
#   LOAD_RATE_PER_SECOND          requests per second, default 2 (1..5)
#   LOAD_START_DELAY_SECONDS      idle time before the load, default 1800 (0..7200)
#   LOAD_DURATION_SECONDS         length of the load, default 1200 (1..7200)
#   LOAD_READY_TIMEOUT_SECONDS    readiness wait, default 900 (1..3600)
# Test seams (the task definition sets neither): LOAD_REPORT_INTERVAL_SECONDS
# (default 60, 1..600) and LOAD_READY_POLL_SECONDS (default 5, 1..60).
#
# POSIX sh, awk and wget only: the image is BusyBox.
set -u

TARGET="http://127.0.0.1:8080"
USER_AGENT="ec-portfolio-measurement-load"

# A proxy from the environment would send the requests elsewhere.
unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY all_proxy ALL_PROXY

# bounded <value> <default> <min> <max>
bounded() {
    case "$1" in '' | *[!0-9]*) echo "$2"; return ;; esac
    if [ "${#1}" -gt 5 ] || [ "$1" -lt "$3" ] || [ "$1" -gt "$4" ]; then echo "$2"; else echo "$1"; fi
}
RATE="$(bounded "${LOAD_RATE_PER_SECOND:-}" 2 1 5)"
START_DELAY="$(bounded "${LOAD_START_DELAY_SECONDS:-}" 1800 0 7200)"
DURATION="$(bounded "${LOAD_DURATION_SECONDS:-}" 1200 1 7200)"
READY_TIMEOUT="$(bounded "${LOAD_READY_TIMEOUT_SECONDS:-}" 900 1 3600)"
REPORT_INTERVAL="$(bounded "${LOAD_REPORT_INTERVAL_SECONDS:-}" 60 1 600)"
READY_POLL="$(bounded "${LOAD_READY_POLL_SECONDS:-}" 5 1 60)"
PLANNED=$((RATE * DURATION))

# The per-second budget is checked several times a second when sleep takes a
# fraction, once a second otherwise.
TICK=1
if sleep 0.2 2>/dev/null; then TICK=0.2; fi

path_for() {
    case "$1" in
    0) echo "/api/public/categories" ;;
    1) echo "/api/public/products?page=1&size=12" ;;
    2) echo "/api/public/products?sort=priceAsc&page=1&size=12" ;;
    *) echo "/api/public/products?sort=nameAsc&page=1&size=12" ;;
    esac
}

# The HTTP status of one GET, or 0 when there is none (refused, timed out).
# wget -S prints the status lines to stderr; the last one is the final answer.
status_of() {
    wget -S -T 5 -U "$USER_AGENT" -O /dev/null "$TARGET$1" 2>&1 |
        awk '$1 ~ /^HTTP\/[0-9.]+$/ && $2 ~ /^[1-5][0-9][0-9]$/ { code = $2 } END { print (code == "" ? 0 : code) }'
}

ready() {
    body="$(wget -q -T 3 -U "$USER_AGENT" -O - "$TARGET/actuator/health/readiness" 2>/dev/null)" || return 1
    case "$(printf '%s' "$body" | tr -d ' \t\r\n')" in *'"status":"UP"'*) return 0 ;; esac
    return 1
}

started="$(date +%s)"
elapsed() { echo $(($(date +%s) - started)); }

total_req=0
total_2xx=0

sleeper=""
pause() {
    sleep "$1" &
    sleeper=$!
    wait "$sleeper"
    sleeper=""
}

stop() {
    [ -n "$sleeper" ] && kill "$sleeper" 2>/dev/null
    printf 'loaddriver v=1 event=stopped t=%s total_req=%s total_2xx=%s\n' "$(elapsed)" "$total_req" "$total_2xx"
    exit 0
}

finish() {
    printf 'loaddriver v=1 event=%s t=%s total_req=%s total_2xx=%s planned=%s\n' \
        "$1" "$(elapsed)" "$total_req" "$total_2xx" "$PLANNED"
    exit 0
}

# ECS stops a container with SIGTERM. As PID 1 the shell would ignore it; the
# trap, and sleeping in the background, make the stop immediate between requests.
trap stop TERM INT

printf 'loaddriver v=1 event=config rate=%s start_delay_s=%s duration_s=%s ready_timeout_s=%s report_s=%s tick=%s planned=%s\n' \
    "$RATE" "$START_DELAY" "$DURATION" "$READY_TIMEOUT" "$REPORT_INTERVAL" "$TICK" "$PLANNED"

until ready; do
    [ "$(elapsed)" -ge "$READY_TIMEOUT" ] && finish never-ready
    pause "$READY_POLL"
done
printf 'loaddriver v=1 event=ready t=%s\n' "$(elapsed)"

while [ "$(elapsed)" -lt "$START_DELAY" ]; do
    pause 1
done
ready || finish not-ready-at-start
load_started="$(date +%s)"
printf 'loaddriver v=1 event=started t=%s\n' "$(elapsed)"

next_path=0
bucket=""
in_bucket=0
consecutive_failures=0
window_started="$load_started"
win_req=0
win_2xx=0
win_4xx=0
win_5xx=0
win_err=0

print_report() {
    printf 'loaddriver v=1 event=report t=%s win_s=%s req=%s s2xx=%s s4xx=%s s5xx=%s err=%s total_req=%s total_2xx=%s\n' \
        "$(elapsed)" "$(($(date +%s) - window_started))" "$win_req" "$win_2xx" "$win_4xx" "$win_5xx" "$win_err" \
        "$total_req" "$total_2xx"
}

# Closes a report interval: prints it, stops the load when 5xx responses and
# errors exceed 5 % of it, and starts the next one.
report() {
    print_report
    if [ "$win_req" -gt 0 ] && [ $(((win_5xx + win_err) * 100)) -gt $((win_req * 5)) ]; then
        finish aborted-error-rate
    fi
    window_started="$(date +%s)"
    win_req=0
    win_2xx=0
    win_4xx=0
    win_5xx=0
    win_err=0
}

request_once() {
    code="$(status_of "$(path_for "$next_path")")"
    next_path=$(((next_path + 1) % 4))
    win_req=$((win_req + 1))
    total_req=$((total_req + 1))
    case "$code" in
    2??) win_2xx=$((win_2xx + 1)); total_2xx=$((total_2xx + 1)); consecutive_failures=0 ;;
    4??) win_4xx=$((win_4xx + 1)); consecutive_failures=$((consecutive_failures + 1)) ;;
    5??) win_5xx=$((win_5xx + 1)); consecutive_failures=$((consecutive_failures + 1)) ;;
    *) win_err=$((win_err + 1)); consecutive_failures=$((consecutive_failures + 1)) ;;
    esac
    if [ "$consecutive_failures" -ge 5 ]; then
        print_report
        finish aborted-consecutive-failures
    fi
}

# Each request is counted in the wall-clock second it starts in, and a second
# never starts more than RATE of them.
while [ $(($(date +%s) - load_started)) -lt "$DURATION" ]; do
    now="$(date +%s)"
    if [ "$now" != "$bucket" ]; then
        bucket="$now"
        in_bucket=0
    fi
    if [ "$in_bucket" -lt "$RATE" ]; then
        in_bucket=$((in_bucket + 1))
        request_once
    else
        pause "$TICK"
    fi
    [ $(($(date +%s) - window_started)) -ge "$REPORT_INTERVAL" ] && report
done

report
finish done
