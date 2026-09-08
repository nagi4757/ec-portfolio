#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEPLOY_SCRIPT="$SCRIPT_DIRECTORY/deploy-frontends.sh"
readonly TEST_RELEASE_SHA="0123456789abcdef0123456789abcdef01234567"

test_directory=""

fail() {
    printf '[frontend-deploy-test] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local exit_code=$?
    trap - EXIT

    if [[ -n "$test_directory" && "$test_directory" == /tmp/ec-portfolio-frontend-deploy-test.* ]]; then
        rm -rf -- "$test_directory"
    fi

    exit "$exit_code"
}

trap cleanup EXIT

assert_contains() {
    local pattern="$1"
    local file="$2"
    grep -Fq -- "$pattern" "$file" || fail "Expected pattern was not found: $pattern"
}

first_line_number() {
    local pattern="$1"
    local file="$2"
    grep -Fn -m 1 -- "$pattern" "$file" | cut -d: -f1
}

create_fixture() {
    local distribution_directory="$1"
    local application_name="$2"

    mkdir -p "$distribution_directory/assets"
    printf 'console.log("%s", "https://d1q0vfmnxby7vo.cloudfront.net");\n' "$application_name" \
        >"$distribution_directory/assets/index-AbCdEf12.js"
    printf 'body { color: #123456; }\n' >"$distribution_directory/assets/index-ZyXwVu98.css"
    printf '<svg xmlns="http://www.w3.org/2000/svg"></svg>\n' >"$distribution_directory/vite.svg"
    printf '<!doctype html><script src="/assets/index-AbCdEf12.js"></script><link href="/assets/index-ZyXwVu98.css" rel="stylesheet">\n' \
        >"$distribution_directory/index.html"
}

write_fake_aws() {
    local fake_aws="$test_directory/bin/aws"

    mkdir -p "$test_directory/bin" "$test_directory/storage"
    cat >"$fake_aws" <<'FAKE_AWS'
#!/usr/bin/env bash
set -euo pipefail

service="${1-}"
operation="${2-}"
shift 2

bucket=""
key=""
body=""
cache_control=""
content_type=""
metadata=""
if_none_match=""
target_file=""

while (( $# > 0 )); do
    case "$1" in
        --region | --bucket | --key | --body | --cache-control | --content-type | --metadata | --if-none-match | --query | --output)
            option="$1"
            value="${2-}"
            shift 2
            case "$option" in
                --bucket) bucket="$value" ;;
                --key) key="$value" ;;
                --body) body="$value" ;;
                --cache-control) cache_control="$value" ;;
                --content-type) content_type="$value" ;;
                --metadata) metadata="$value" ;;
                --if-none-match) if_none_match="$value" ;;
            esac
            ;;
        *)
            target_file="$1"
            shift
            ;;
    esac
done

[[ "$service" == "s3api" ]] || exit 64
object_file="$MOCK_AWS_STORAGE/$bucket/$key"
metadata_file="$object_file.metadata"
printf '%s|%s|%s|%s|%s\n' "$operation" "$bucket" "$key" "$cache_control" "$content_type" >>"$MOCK_AWS_CALLS"

case "$operation" in
    put-object)
        if [[ "$if_none_match" == "*" && -f "$object_file" ]]; then
            printf 'An error occurred (PreconditionFailed) when calling PutObject: 412\n' >&2
            exit 255
        fi
        mkdir -p "${object_file%/*}"
        cp "$body" "$object_file"
        checksum="${metadata#sha256=}"
        checksum="${checksum%%,*}"
        printf '%s\t%s\t%s\n' "$checksum" "$cache_control" "$content_type" >"$metadata_file"
        ;;
    head-object)
        [[ -f "$object_file" && -f "$metadata_file" ]] || exit 254
        cat "$metadata_file"
        ;;
    get-object)
        [[ -f "$object_file" ]] || exit 254
        mkdir -p "${target_file%/*}"
        cp "$object_file" "$target_file"
        ;;
    *)
        exit 64
        ;;
esac
FAKE_AWS
    chmod 0755 "$fake_aws"
}

run_deploy() {
    PATH="$test_directory/bin:$PATH" \
        MOCK_AWS_STORAGE="$test_directory/storage" \
        MOCK_AWS_CALLS="$test_directory/aws.calls" \
        AWS_REGION="ap-northeast-1" \
        VITE_API_BASE_URL="https://d1q0vfmnxby7vo.cloudfront.net" \
        RELEASE_SHA="$TEST_RELEASE_SHA" \
        STORE_BUCKET_NAME="ec-portfolio-demo-store-test1234" \
        ADMIN_BUCKET_NAME="ec-portfolio-demo-admin-test5678" \
        STORE_DIST_DIR="$test_directory/store" \
        ADMIN_DIST_DIR="$test_directory/admin" \
        "$DEPLOY_SCRIPT" deploy
}

run_validate() {
    AWS_REGION="ap-northeast-1" \
        VITE_API_BASE_URL="https://d1q0vfmnxby7vo.cloudfront.net" \
        RELEASE_SHA="$TEST_RELEASE_SHA" \
        STORE_BUCKET_NAME="ec-portfolio-demo-store-test1234" \
        ADMIN_BUCKET_NAME="ec-portfolio-demo-admin-test5678" \
        STORE_DIST_DIR="$test_directory/store" \
        ADMIN_DIST_DIR="$test_directory/admin" \
        "$DEPLOY_SCRIPT" validate
}

run_rollback() {
    PATH="$test_directory/bin:$PATH" \
        MOCK_AWS_STORAGE="$test_directory/storage" \
        MOCK_AWS_CALLS="$test_directory/aws.calls" \
        AWS_REGION="ap-northeast-1" \
        VITE_API_BASE_URL="https://d1q0vfmnxby7vo.cloudfront.net" \
        RELEASE_SHA="$TEST_RELEASE_SHA" \
        STORE_BUCKET_NAME="ec-portfolio-demo-store-test1234" \
        ADMIN_BUCKET_NAME="ec-portfolio-demo-admin-test5678" \
        "$DEPLOY_SCRIPT" rollback
}

main() {
    local admin_asset_line
    local admin_index_line
    local admin_non_hashed_line
    local store_asset_line
    local store_index_line
    local store_non_hashed_line

    bash -n "$DEPLOY_SCRIPT"
    ! grep -Eq '(^|[[:space:]])(aws[[:space:]]+cloudfront|aws[[:space:]]+s3[[:space:]]+sync|delete-object)([[:space:]]|$)' "$DEPLOY_SCRIPT" ||
        fail "Deployment script contains a forbidden delete, sync, or CloudFront operation."

    test_directory="$(mktemp -d /tmp/ec-portfolio-frontend-deploy-test.XXXXXX)"
    : >"$test_directory/aws.calls"
    create_fixture "$test_directory/store" store
    create_fixture "$test_directory/admin" admin
    write_fake_aws

    run_validate >/dev/null
    run_deploy >/dev/null
    assert_contains "put-object|ec-portfolio-demo-store-test1234|_releases/$TEST_RELEASE_SHA/manifest.sha256|no-cache|text/plain; charset=utf-8" "$test_directory/aws.calls"
    assert_contains "put-object|ec-portfolio-demo-admin-test5678|_releases/$TEST_RELEASE_SHA/manifest.sha256|no-cache|text/plain; charset=utf-8" "$test_directory/aws.calls"
    assert_contains "put-object|ec-portfolio-demo-store-test1234|assets/index-AbCdEf12.js|$ASSET_CACHE_CONTROL|text/javascript; charset=utf-8" "$test_directory/aws.calls"
    assert_contains "put-object|ec-portfolio-demo-admin-test5678|assets/index-ZyXwVu98.css|$ASSET_CACHE_CONTROL|text/css; charset=utf-8" "$test_directory/aws.calls"
    assert_contains "put-object|ec-portfolio-demo-store-test1234|index.html|no-cache|text/html; charset=utf-8" "$test_directory/aws.calls"
    assert_contains "put-object|ec-portfolio-demo-admin-test5678|index.html|no-cache|text/html; charset=utf-8" "$test_directory/aws.calls"

    store_asset_line="$(first_line_number 'put-object|ec-portfolio-demo-store-test1234|assets/' "$test_directory/aws.calls")"
    admin_asset_line="$(first_line_number 'put-object|ec-portfolio-demo-admin-test5678|assets/' "$test_directory/aws.calls")"
    store_non_hashed_line="$(first_line_number 'put-object|ec-portfolio-demo-store-test1234|vite.svg|' "$test_directory/aws.calls")"
    admin_non_hashed_line="$(first_line_number 'put-object|ec-portfolio-demo-admin-test5678|vite.svg|' "$test_directory/aws.calls")"
    store_index_line="$(first_line_number 'put-object|ec-portfolio-demo-store-test1234|index.html|' "$test_directory/aws.calls")"
    admin_index_line="$(first_line_number 'put-object|ec-portfolio-demo-admin-test5678|index.html|' "$test_directory/aws.calls")"
    (( store_asset_line < store_non_hashed_line && admin_asset_line < admin_non_hashed_line )) ||
        fail "Assets were not published before non-hashed files."
    (( store_non_hashed_line < store_index_line && admin_non_hashed_line < admin_index_line )) ||
        fail "index.html was not published last."

    run_deploy >/dev/null
    run_rollback >/dev/null

    printf 'console.log("different", "https://d1q0vfmnxby7vo.cloudfront.net");\n' \
        >"$test_directory/store/assets/index-AbCdEf12.js"
    if run_deploy >"$test_directory/collision.stdout" 2>"$test_directory/collision.stderr"; then
        fail "A checksum collision did not fail the deployment."
    fi
    assert_contains "Checksum collision detected" "$test_directory/collision.stderr"

    printf 'source map\n' >"$test_directory/admin/assets/index-AbCdEf12.js.map"
    if run_deploy >"$test_directory/source-map.stdout" 2>"$test_directory/source-map.stderr"; then
        fail "A source map did not fail artifact validation."
    fi
    assert_contains "Source maps are forbidden" "$test_directory/source-map.stderr"

    rm -f -- "$test_directory/admin/assets/index-AbCdEf12.js.map"
    printf 'unexpected artifact\n' >"$test_directory/admin/unexpected.bin"
    if run_deploy >"$test_directory/unexpected.stdout" 2>"$test_directory/unexpected.stderr"; then
        fail "An unexpected artifact did not fail validation."
    fi
    assert_contains "Unexpected non-hashed artifact" "$test_directory/unexpected.stderr"

    printf '[frontend-deploy-test] PASS\n'
}

readonly ASSET_CACHE_CONTROL="public,max-age=31536000,immutable"

main "$@"
