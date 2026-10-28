#!/usr/bin/env bash

set -euo pipefail

# Decides, before deploy-frontends asks for its approval, whether a main push
# has anything to give the Store and Admin frontends. One output goes to
# GITHUB_OUTPUT:
#
#   frontend_changed  the frontend release inputs differ between the commit the
#                     frontends were last deployed from and this commit. false
#                     for a push that touches none of them (an access,
#                     infrastructure, API or documentation change): the deploy
#                     job is skipped and publishes nothing.
#
# The baseline is the most recent demo-frontend deployment GitHub recorded as
# successful, not the previous push, so a frontend change whose deployment was
# rejected, failed or cancelled stays pending until a deployment lands. A net
# difference is enough: nothing was deployed after the baseline, so the served
# files are the baseline's build.
#
# When there is no usable baseline (no successful deployment among the latest
# ones, or a baseline outside this commit's history) the push is treated as a
# frontend change and deploys as before. A failed read of the deployments, a
# malformed record or a git failure stops the job instead, so deploy-frontends,
# which needs it, does not run on a guess.
#
# The workflow build environment (Node version, job steps) is not an input: a
# change there that should reach the served files has to come with a change to
# one of the paths below. The approved API URL is one of them, because
# deploy-frontends.sh pins it.

readonly FRONTEND_ENVIRONMENT="demo-frontend"
readonly DEPLOYMENT_SCAN_LIMIT=30

# Everything npm ci and the two workspace builds read, plus the publication
# script that decides object keys and headers.
frontend_release_paths=(
    apps/store-web
    apps/admin-web
    packages
    package.json
    package-lock.json
    tsconfig.base.json
    infra/runtime/demo/deploy-frontends.sh
)

log() {
    printf '[frontend-scope] %s\n' "$*"
}

fail() {
    printf '[frontend-scope] ERROR: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command is not available: $1"
}

require_environment() {
    local variable_name="$1"
    [[ -n "${!variable_name-}" ]] || fail "Required environment variable is missing: $variable_name"
}

# Prints the commit of the most recent deployment to the frontend environment
# that has a success status, or nothing when none of the latest ones has. Only
# GitHub API reads are made.
last_deployed_commit() {
    local listing id sha succeeded

    listing="$(gh api "repos/$GITHUB_REPOSITORY/deployments?environment=$FRONTEND_ENVIRONMENT&per_page=$DEPLOYMENT_SCAN_LIMIT" \
        --jq '.[] | "\(.id) \(.sha)"')" ||
        fail "Unable to list the $FRONTEND_ENVIRONMENT deployments."
    while read -r id sha; do
        [[ -n "$id" ]] || continue
        [[ "$id" =~ ^[0-9]+$ && "$sha" =~ ^[0-9a-f]{40}$ ]] ||
            fail "Unexpected $FRONTEND_ENVIRONMENT deployment record: $id $sha"
        succeeded="$(gh api "repos/$GITHUB_REPOSITORY/deployments/$id/statuses?per_page=100" \
            --jq 'any(.[]; .state == "success")')" ||
            fail "Unable to read the statuses of deployment $id."
        case "$succeeded" in
            true)
                printf '%s' "$sha"
                return 0
                ;;
            false) ;;
            *) fail "Unexpected statuses of deployment $id." ;;
        esac
    done <<<"$listing"
}

# changed_between <from> <to> <path>...: prints true when the paths differ
# between the two commits, false otherwise. A git failure stops the script.
changed_between() {
    local from="$1"
    local to="$2"
    local status=0
    shift 2

    git diff --quiet "$from" "$to" -- "$@" || status=$?
    case "$status" in
        0) printf 'false' ;;
        1) printf 'true' ;;
        *) fail "Unable to compare the frontend release inputs between $from and $to." ;;
    esac
}

main() {
    local deployed frontend_changed variable_name
    local ancestor_status=0

    (( $# == 0 )) || fail "Usage: frontend-release-scope.sh"
    require_command gh
    require_command git
    for variable_name in GITHUB_REPOSITORY RELEASE_SHA GITHUB_OUTPUT; do
        require_environment "$variable_name"
    done
    [[ "$GITHUB_REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || fail "GITHUB_REPOSITORY is not owner/name."
    [[ "$RELEASE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "RELEASE_SHA must be a full lowercase Git SHA."
    [[ -f "$GITHUB_OUTPUT" && -w "$GITHUB_OUTPUT" ]] || fail "GITHUB_OUTPUT is not a writable file."
    git rev-parse --verify --quiet "${RELEASE_SHA}^{commit}" >/dev/null ||
        fail "The release commit $RELEASE_SHA is not present."

    deployed="$(last_deployed_commit)" || exit 1

    if [[ -z "$deployed" ]]; then
        frontend_changed="true"
        log "No successful $FRONTEND_ENVIRONMENT deployment among the latest $DEPLOYMENT_SCAN_LIMIT: the frontends are deployed as before."
    elif ! git rev-parse --verify --quiet "${deployed}^{commit}" >/dev/null; then
        frontend_changed="true"
        log "The last deployed commit $deployed is not in this checkout: the frontends are deployed as before."
    else
        git merge-base --is-ancestor "$deployed" "$RELEASE_SHA" || ancestor_status=$?
        case "$ancestor_status" in
            0)
                frontend_changed="$(changed_between "$deployed" "$RELEASE_SHA" "${frontend_release_paths[@]}")" || exit 1
                ;;
            1)
                frontend_changed="true"
                log "The last deployed commit $deployed is not an ancestor of $RELEASE_SHA: the frontends are deployed as before."
                ;;
            *) fail "Unable to check whether $deployed is an ancestor of $RELEASE_SHA." ;;
        esac
    fi

    log "Last deployed frontend commit ${deployed:-none}, release commit $RELEASE_SHA."
    log "frontend_changed=$frontend_changed"
    [[ "$frontend_changed" == "true" ]] ||
        log "The frontend release inputs are unchanged since the last deployment: deploy-frontends is skipped."
    printf 'frontend_changed=%s\n' "$frontend_changed" >>"$GITHUB_OUTPUT"
}

main "$@"
