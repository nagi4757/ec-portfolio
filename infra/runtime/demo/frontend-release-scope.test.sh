#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCOPE_SCRIPT="$SCRIPT_DIRECTORY/frontend-release-scope.sh"
readonly WORKFLOW_FILE="$SCRIPT_DIRECTORY/../../../.github/workflows/ci.yml"
readonly TEST_REPOSITORY="example/ec-portfolio"
readonly REAL_GIT="$(command -v git)"

work_directory=""

cleanup() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-frontend-scope-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup EXIT

fail() {
    printf '[frontend-scope-test] FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local description="$3"

    printf '%s' "$haystack" | grep -Fq -- "$needle" ||
        fail "$description (expected to find: $needle)"
}

assert_absent() {
    local haystack="$1"
    local needle="$2"
    local description="$3"

    printf '%s' "$haystack" | grep -Fq -- "$needle" &&
        fail "$description (unexpectedly found: $needle)"
    return 0
}

# The gh stub answers the two reads the scope makes from JSON shaped like the
# GitHub API responses and applies the script's own --jq expression with jq, so
# the expressions are exercised too. Anything else is an unexpected call.
install_mocks() {
    local mock_directory="$work_directory/bin"

    mkdir -p "$mock_directory"
    cat >"$mock_directory/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "gh $*" >>"$MOCK_CALL_LOG"

[[ "$#" == 4 && "$1" == "api" && "$3" == "--jq" ]] || { echo "unexpected gh call: $*" >&2; exit 99; }
path="$2"
expression="$4"
prefix="repos/$MOCK_REPOSITORY/deployments"

if [[ "$path" == "$prefix?environment=demo-frontend&per_page=30" ]]; then
    [[ "${MOCK_LIST_FAIL-false}" != "true" ]] || { echo "HTTP 502" >&2; exit 1; }
    jq -r "$expression" "$MOCK_GH_DIRECTORY/deployments.json"
elif [[ "$path" =~ ^repos/[^/]+/[^/]+/deployments/([0-9]+)/statuses\?per_page=100$ && "$path" == "$prefix/"* ]]; then
    id="${BASH_REMATCH[1]}"
    [[ "$id" != "${MOCK_STATUS_FAIL_ID-}" ]] || { echo "HTTP 404" >&2; exit 1; }
    if [[ -f "$MOCK_GH_DIRECTORY/statuses-$id.json" ]]; then
        jq -r "$expression" "$MOCK_GH_DIRECTORY/statuses-$id.json"
    else
        jq -r "$expression" <<<'[]'
    fi
else
    echo "unexpected gh path: $path" >&2
    exit 99
fi
MOCK
    chmod 755 "$mock_directory/gh"
}

# set_deployments "<id> <sha> <state,state,...>"...: newest first, statuses
# newest first, as the API lists them. "-" stands for no status at all.
set_deployments() {
    local entry id sha states state first_deployment first_status statuses_file

    rm -rf -- "$work_directory/gh"
    mkdir -p "$work_directory/gh"
    {
        printf '['
        first_deployment="true"
        for entry in "$@"; do
            read -r id sha states <<<"$entry"
            [[ "$first_deployment" == "true" ]] || printf ','
            first_deployment="false"
            printf '{"id":%s,"sha":"%s","ref":"main","environment":"demo-frontend"}' "$id" "$sha"
        done
        printf ']'
    } >"$work_directory/gh/deployments.json"
    for entry in "$@"; do
        read -r id sha states <<<"$entry"
        statuses_file="$work_directory/gh/statuses-$id.json"
        {
            printf '['
            first_status="true"
            if [[ "$states" != "-" ]]; then
                IFS=',' read -r -a state_list <<<"$states"
                for state in "${state_list[@]}"; do
                    [[ "$first_status" == "true" ]] || printf ','
                    first_status="false"
                    printf '{"state":"%s","environment":"demo-frontend"}' "$state"
                done
            fi
            printf ']'
        } >"$statuses_file"
    done
}

create_repository() {
    local repository="$work_directory/repo"
    local relative_path

    for relative_path in apps/store-web/src/main.ts apps/admin-web/src/main.ts packages/ui/src/index.ts \
        package.json package-lock.json tsconfig.base.json infra/runtime/demo/deploy-frontends.sh \
        infra/runtime/demo/deploy-api.sh infra/terraform/demo/main.tf infra/terraform/access/README.md \
        apps/api/src/main/java/Api.java .github/workflows/ci.yml README.md; do
        mkdir -p "$repository/$(dirname -- "$relative_path")"
        printf 'base %s\n' "$relative_path" >"$repository/$relative_path"
    done
    git -C "$repository" init --quiet
    git -C "$repository" -c user.name=test -c user.email=test@example.invalid add -A
    git -C "$repository" -c user.name=test -c user.email=test@example.invalid commit --quiet -m "base"
    printf '%s' "$repository"
}

# commit_on <base> <message> <path>...: one commit on top of <base> that changes
# the paths; prints its SHA.
commit_on() {
    local base="$1"
    local message="$2"
    local relative_path
    shift 2

    git -C "$repository" checkout -f --quiet --detach "$base"
    for relative_path in "$@"; do
        mkdir -p "$repository/$(dirname -- "$relative_path")"
        printf '%s %s\n' "$message" "$relative_path" >>"$repository/$relative_path"
    done
    git -C "$repository" -c user.name=test -c user.email=test@example.invalid add -A
    git -C "$repository" -c user.name=test -c user.email=test@example.invalid commit --quiet -m "$message"
    git -C "$repository" rev-parse HEAD
}

run_scope() {
    local release_sha="$1"
    shift

    : >"$MOCK_CALL_LOG"
    : >"$scope_output_file"
    (
        cd "$repository"
        env PATH="$work_directory/bin:$PATH" \
            MOCK_CALL_LOG="$MOCK_CALL_LOG" \
            MOCK_REPOSITORY="$TEST_REPOSITORY" \
            MOCK_GH_DIRECTORY="$work_directory/gh" \
            GITHUB_REPOSITORY="$TEST_REPOSITORY" \
            GITHUB_OUTPUT="$scope_output_file" \
            RELEASE_SHA="$release_sha" \
            "$@" \
            bash "$SCOPE_SCRIPT"
    )
}

assert_reads_only() {
    local description="$1"
    local call

    while IFS= read -r call; do
        [[ -n "$call" ]] || continue
        [[ "$call" == "gh api repos/$TEST_REPOSITORY/deployments"* ]] ||
            fail "$description: the scope may only read the deployments, not: $call"
    done <"$work_directory/calls.log"
}

assert_scope() {
    local description="$1"
    local expected="$2"
    local release_sha="$3"
    shift 3
    local output

    output="$(run_scope "$release_sha" "$@" 2>&1)" || fail "$description must be decided, not fail: $output"
    [[ "$(cat "$scope_output_file")" == "frontend_changed=$expected" ]] ||
        fail "$description: got [$(cat "$scope_output_file")] want [frontend_changed=$expected]"
    assert_reads_only "$description"
}

# Fail-closed: no decision is written, so deploy-frontends, which needs the
# scope job, does not run.
scope_fails() {
    local description="$1"
    local expected_message="$2"
    local release_sha="$3"
    shift 3
    local output

    output="$(run_scope "$release_sha" "$@" 2>&1)" && fail "$description must fail closed."
    assert_contains "$output" "$expected_message" "$description must report its reason."
    [[ ! -s "$scope_output_file" ]] || fail "$description must not write any decision to GITHUB_OUTPUT."
    assert_reads_only "$description"
}

work_directory="$(mktemp -d /tmp/ec-portfolio-frontend-scope-test.XXXXXX)"
readonly MOCK_CALL_LOG="$work_directory/calls.log"
readonly scope_output_file="$work_directory/github-output"
install_mocks
repository="$(create_repository)"
base_sha="$(git -C "$repository" rev-parse HEAD)"

# --- pushes that leave the frontends alone ------------------------------------
set_deployments "101 $base_sha success,in_progress,waiting"

# The shape of the Phase 6C-5c P3-a change: Terraform, its README and the
# workflow file.
p3a_sha="$(commit_on "$base_sha" "p3a" infra/terraform/demo/main.tf .github/workflows/ci.yml README.md)"
assert_scope "A Terraform and workflow change" false "$p3a_sha"
access_sha="$(commit_on "$base_sha" "access" infra/terraform/access/README.md)"
assert_scope "An access change" false "$access_sha"
api_sha="$(commit_on "$base_sha" "api" apps/api/src/main/java/Api.java)"
assert_scope "An API change" false "$api_sha"
runtime_sha="$(commit_on "$base_sha" "runtime" infra/runtime/demo/deploy-api.sh)"
assert_scope "A host runtime change" false "$runtime_sha"
assert_scope "The deployed commit itself" false "$base_sha"
api_list_calls="$(grep -c "deployments?environment=demo-frontend&per_page=30" "$work_directory/calls.log")"
[[ "$api_list_calls" == 1 ]] || fail "The scope must list the deployments exactly once."

# --- pushes that change the frontends -----------------------------------------
for frontend_path in apps/store-web/src/main.ts apps/admin-web/src/main.ts packages/ui/src/index.ts \
    packages/contracts/src/generated.ts package.json package-lock.json tsconfig.base.json \
    infra/runtime/demo/deploy-frontends.sh; do
    variant_sha="$(commit_on "$base_sha" "frontend" "$frontend_path")"
    assert_scope "A change to $frontend_path" true "$variant_sha"
done

# A frontend change and its revert after the deployment cancel out: the served
# files are still the deployed commit's build.
store_sha="$(commit_on "$base_sha" "store" apps/store-web/src/main.ts)"
git -C "$repository" -c user.name=test -c user.email=test@example.invalid revert --quiet --no-edit "$store_sha" >/dev/null
reverted_sha="$(git -C "$repository" rev-parse HEAD)"
assert_scope "A frontend change reverted since the deployment" false "$reverted_sha"

# --- the baseline is the last successful deployment, not the previous push ---
infra_after_store_sha="$(commit_on "$store_sha" "infra after store" infra/terraform/demo/main.tf)"
for failed_states in "failure,in_progress,waiting" "error" "waiting" "-"; do
    set_deployments "102 $store_sha $failed_states" "101 $base_sha success,in_progress"
    assert_scope "An infrastructure push after a frontend deployment that ended [$failed_states]" true "$infra_after_store_sha"
done
set_deployments "102 $store_sha success,in_progress,waiting" "101 $base_sha success"
assert_scope "An infrastructure push after the frontend change was deployed" false "$infra_after_store_sha"
set_deployments "102 $store_sha inactive,success,in_progress" "101 $base_sha inactive,success"
assert_scope "A successful deployment later marked inactive" false "$infra_after_store_sha"

# --- no usable baseline: deploy as before ------------------------------------
set_deployments
assert_scope "No deployment at all" true "$p3a_sha"
set_deployments "102 $store_sha failure" "101 $base_sha waiting"
assert_scope "No successful deployment" true "$p3a_sha"
set_deployments "101 0123456789abcdef0123456789abcdef01234567 success"
assert_scope "A deployed commit missing from the checkout" true "$p3a_sha"
set_deployments "101 $api_sha success"
assert_scope "A deployed commit on another line of history" true "$p3a_sha"

# --- fail-closed --------------------------------------------------------------
set_deployments "101 $base_sha success"
scope_fails "A failed deployment listing" "Unable to list the demo-frontend deployments" "$p3a_sha" MOCK_LIST_FAIL=true
scope_fails "A failed status read" "Unable to read the statuses of deployment 101" "$p3a_sha" MOCK_STATUS_FAIL_ID=101
set_deployments "101 $(printf '%s' "$base_sha" | tr 'a-f' 'A-F') success"
scope_fails "An uppercase deployed SHA" "Unexpected demo-frontend deployment record" "$p3a_sha"
set_deployments "101 ${base_sha:0:12} success"
scope_fails "A short deployed SHA" "Unexpected demo-frontend deployment record" "$p3a_sha"
printf '[{"id":"x1","sha":"%s"}]' "$base_sha" >"$work_directory/gh/deployments.json"
scope_fails "A non-numeric deployment id" "Unexpected demo-frontend deployment record" "$p3a_sha"
set_deployments "101 $base_sha success"
printf '{"message":"Not Found"}' >"$work_directory/gh/statuses-101.json"
scope_fails "A status response that is not a list" "Unable to read the statuses of deployment 101" "$p3a_sha"

set_deployments "101 $base_sha success"
scope_fails "A malformed release SHA" "RELEASE_SHA must be a full lowercase Git SHA" "not-a-sha"
scope_fails "A release commit missing from the checkout" "is not present" "0123456789abcdef0123456789abcdef01234567"
scope_fails "A malformed repository" "GITHUB_REPOSITORY is not owner/name" "$p3a_sha" GITHUB_REPOSITORY="example/ec-portfolio/deployments"
output="$(run_scope "$p3a_sha" GITHUB_OUTPUT= 2>&1)" && fail "A missing GITHUB_OUTPUT must fail closed."
assert_contains "$output" "GITHUB_OUTPUT" "A missing GITHUB_OUTPUT must be reported."
output="$(run_scope "$p3a_sha" GITHUB_OUTPUT="$work_directory/no-such-directory/output" 2>&1)" &&
    fail "An unwritable GITHUB_OUTPUT must fail closed."
assert_contains "$output" "GITHUB_OUTPUT is not a writable file" "An unwritable GITHUB_OUTPUT must be refused."
[[ ! -s "$work_directory/calls.log" ]] || fail "An unwritable GITHUB_OUTPUT must be refused before any GitHub read."

# A git failure is neither "changed" nor "unchanged".
git_mock_directory="$work_directory/git-mock"
mkdir -p "$git_mock_directory"
printf '#!/usr/bin/env bash\nif [[ "${1-}" == diff ]]; then echo "fatal: simulated diff failure" >&2; exit 128; fi\nexec "%s" "$@"\n' "$REAL_GIT" >"$git_mock_directory/git"
chmod 755 "$git_mock_directory/git"
scope_fails "A git diff failure" "Unable to compare the frontend release inputs" "$p3a_sha" PATH="$git_mock_directory:$work_directory/bin:$PATH"
printf '#!/usr/bin/env bash\nif [[ "${1-}" == merge-base ]]; then echo "fatal: simulated merge-base failure" >&2; exit 128; fi\nexec "%s" "$@"\n' "$REAL_GIT" >"$git_mock_directory/git"
scope_fails "A git merge-base failure" "Unable to check whether" "$p3a_sha" PATH="$git_mock_directory:$work_directory/bin:$PATH"

# --- static contract: GitHub reads only, no AWS ------------------------------
for forbidden in "aws " "--method" "--input" "--field" "--raw-field" "secrets."; do
    assert_absent "$(cat "$SCOPE_SCRIPT")" "$forbidden" "The scope script must not reference"
done
gh_calls="$(grep -E '(^|[^a-z_])gh ' "$SCOPE_SCRIPT" | grep -v '^ *#' || true)"
[[ "$(printf '%s\n' "$gh_calls" | grep -c .)" == 2 ]] || fail "The scope script must make exactly its two gh reads."
while IFS= read -r gh_call; do
    [[ "$gh_call" =~ ^[[:space:]]*(listing|succeeded)=\"\$\(gh\ api\ \"repos/\$GITHUB_REPOSITORY/deployments[?/] ]] ||
        fail "Every gh call must be a deployments read: $gh_call"
done <<<"$gh_calls"

# --- the workflow skips deploy-frontends only on this scope ------------------
job_block() {
    awk -v job="  ${1}:" '
        $0 == job { inside = 1; print; next }
        inside && /^  [a-z]/ { exit }
        inside { print }
    ' "$WORKFLOW_FILE"
}
read_job_needs() {
    printf '%s\n' "$(job_block "$1")" | awk '
        /^    needs:/ { collecting = 1; next }
        collecting && /^      - / { sub(/^      - /, ""); print; next }
        collecting { exit }
    '
}

scope_job="$(job_block frontend-release-scope)"
frontend_job="$(job_block deploy-frontends)"
tests_job="$(job_block runtime-tests)"
[[ -n "$scope_job" && -n "$frontend_job" && -n "$tests_job" ]] || fail "Could not read the jobs from $WORKFLOW_FILE"

[[ "$(printf '%s\n' "$scope_job" | grep '^    if:')" == "    if: github.event_name == 'push' && github.ref == 'refs/heads/main'" ]] ||
    fail "frontend-release-scope must run for every push to main."
assert_contains "$scope_job" "run: infra/runtime/demo/frontend-release-scope.sh" "frontend-release-scope must run the scope script."
assert_contains "$scope_job" "frontend_changed: \${{ steps.scope.outputs.frontend_changed }}" "frontend-release-scope must export frontend_changed."
assert_contains "$scope_job" "fetch-depth: 0" "frontend-release-scope needs the history back to the deployed commit."
assert_contains "$scope_job" "RELEASE_SHA: \${{ github.sha }}" "frontend-release-scope must decide for the pushed commit."
assert_contains "$scope_job" "deployments: read" "frontend-release-scope must be able to read the deployments."
for forbidden in "environment:" "id-token" "aws-actions" "secrets." "write"; do
    assert_absent "$scope_job" "$forbidden" "frontend-release-scope must hold no deployment environment, credential or write permission"
done

frontend_needs="$(read_job_needs deploy-frontends)"
for required_need in backend frontend docker deploy-api frontend-release-scope; do
    printf '%s\n' "$frontend_needs" | grep -qx -- "$required_need" ||
        fail "deploy-frontends must keep needing $required_need."
done
[[ "$(printf '%s\n' "$frontend_job" | grep -c '^    if:')" == 1 ]] || fail "deploy-frontends must keep exactly one job-level if."
[[ "$(printf '%s\n' "$frontend_job" | grep '^    if:')" == \
    "    if: github.event_name == 'push' && github.ref == 'refs/heads/main' && needs.frontend-release-scope.outputs.frontend_changed == 'true'" ]] ||
    fail "deploy-frontends must run for a push to main exactly when the frontend scope says the frontends changed."
assert_contains "$frontend_job" "run: infra/runtime/demo/deploy-frontends.sh deploy" "deploy-frontends must still deploy."
assert_contains "$tests_job" "infra/runtime/demo/frontend-release-scope.test.sh" "runtime-tests must run this suite on every pull request."

printf '[frontend-scope-test] PASS\n'
