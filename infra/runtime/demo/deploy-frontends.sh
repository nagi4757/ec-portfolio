#!/usr/bin/env bash

set -euo pipefail

readonly ASSET_CACHE_CONTROL="public,max-age=31536000,immutable"
readonly SHELL_CACHE_CONTROL="no-cache"
readonly RELEASES_PREFIX="_releases"
readonly EXPECTED_REGION="ap-northeast-1"
readonly EXPECTED_API_BASE_URL="https://d1q0vfmnxby7vo.cloudfront.net"

runtime_directory=""

log() {
    printf '[frontend-deploy] %s\n' "$*"
}

fail() {
    printf '[frontend-deploy] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    local exit_code=$?
    trap - EXIT

    if [[ -n "$runtime_directory" && "$runtime_directory" == /tmp/ec-portfolio-frontend-deploy.* ]]; then
        rm -rf -- "$runtime_directory"
    fi

    exit "$exit_code"
}

trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command is not available: $1"
}

require_environment() {
    local variable_name="$1"
    [[ -n "${!variable_name-}" ]] || fail "Required environment variable is missing: $variable_name"
}

validate_bucket_name() {
    local application="$1"
    local bucket_name="$2"

    [[ "$bucket_name" =~ ^ec-portfolio-demo-${application}-[a-z0-9]+$ ]] ||
        fail "$application bucket name does not match the Demo frontend contract."
}

validate_relative_path() {
    local relative_path="$1"
    local base_name="${relative_path##*/}"

    [[ "$relative_path" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] ||
        fail "Artifact path contains unsupported characters: $relative_path"
    [[ "$relative_path" != */../* && "$relative_path" != ../* && "$relative_path" != */.. ]] ||
        fail "Artifact path traversal is forbidden: $relative_path"
    [[ "$base_name" != .* ]] || fail "Hidden artifacts are forbidden: $relative_path"
    [[ "$relative_path" != *.map ]] || fail "Source maps are forbidden: $relative_path"

    case "$relative_path" in
        index.html)
            ;;
        assets/*)
            [[ "$base_name" =~ -[A-Za-z0-9_-]{8,}[.][A-Za-z0-9]+$ ]] ||
                fail "Asset filename is not content-hashed: $relative_path"
            ;;
        */*)
            fail "Unexpected non-asset nested artifact: $relative_path"
            ;;
        *)
            case "$relative_path" in
                *.avif | *.ico | *.jpeg | *.jpg | *.json | *.png | *.svg | *.txt | *.webmanifest | *.webp | *.xml)
                    ;;
                *)
                    fail "Unexpected non-hashed artifact: $relative_path"
                    ;;
            esac
            ;;
    esac
}

content_type_for() {
    local relative_path="$1"

    case "$relative_path" in
        *.html) printf 'text/html; charset=utf-8' ;;
        *.css) printf 'text/css; charset=utf-8' ;;
        *.js | *.mjs) printf 'text/javascript; charset=utf-8' ;;
        *.json | *.webmanifest) printf 'application/json; charset=utf-8' ;;
        *.svg) printf 'image/svg+xml' ;;
        *.ico) printf 'image/x-icon' ;;
        *.png) printf 'image/png' ;;
        *.jpg | *.jpeg) printf 'image/jpeg' ;;
        *.webp) printf 'image/webp' ;;
        *.avif) printf 'image/avif' ;;
        *.woff) printf 'font/woff' ;;
        *.woff2) printf 'font/woff2' ;;
        *.txt) printf 'text/plain; charset=utf-8' ;;
        *.xml) printf 'application/xml; charset=utf-8' ;;
        *) fail "Content-Type is not defined for artifact: $relative_path" ;;
    esac
}

cache_control_for() {
    local relative_path="$1"

    case "$relative_path" in
        assets/*) printf '%s' "$ASSET_CACHE_CONTROL" ;;
        *) printf '%s' "$SHELL_CACHE_CONTROL" ;;
    esac
}

artifact_category() {
    local relative_path="$1"

    case "$relative_path" in
        assets/*) printf 'asset' ;;
        index.html) printf 'index' ;;
        *) printf 'non-hashed' ;;
    esac
}

sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

create_manifest() {
    local distribution_directory="$1"
    local manifest_file="$2"
    local file_list="$runtime_directory/artifacts.$$.list"
    local relative_path

    [[ -d "$distribution_directory" ]] || fail "Distribution directory is missing: $distribution_directory"
    [[ -f "$distribution_directory/index.html" ]] || fail "index.html is missing: $distribution_directory"
    [[ -d "$distribution_directory/assets" ]] || fail "assets directory is missing: $distribution_directory"

    if find "$distribution_directory" -type l -print -quit | grep -q .; then
        fail "Symbolic links are forbidden in frontend artifacts: $distribution_directory"
    fi

    (
        cd "$distribution_directory"
        find . -type f -print | sed 's#^./##' | LC_ALL=C sort
    ) >"$file_list"

    [[ -s "$file_list" ]] || fail "No frontend artifacts were found: $distribution_directory"
    : >"$manifest_file"

    while IFS= read -r relative_path; do
        validate_relative_path "$relative_path"
        printf '%s  %s\n' "$(sha256_file "$distribution_directory/$relative_path")" "$relative_path" >>"$manifest_file"
    done <"$file_list"

    grep -q '  index.html$' "$manifest_file" || fail "index.html is missing from the release manifest."
    grep -q '  assets/' "$manifest_file" || fail "No content-hashed asset is present in the release manifest."

    grep -R -Fq -- "$EXPECTED_API_BASE_URL" "$distribution_directory/assets" ||
        fail "Production API base URL is missing from the frontend bundle: $distribution_directory"
    if grep -R -Eq 'demo[.]example[.]invalid|https?://127[.]0[.]0[.]1:8080' "$distribution_directory"; then
        fail "Frontend bundle contains a forbidden placeholder or loopback API URL: $distribution_directory"
    fi

    grep -Eo '/assets/[A-Za-z0-9._/-]+' "$distribution_directory/index.html" |
        sed 's#^/##' | LC_ALL=C sort -u >"$runtime_directory/index-assets.$$.list"
    [[ -s "$runtime_directory/index-assets.$$.list" ]] ||
        fail "index.html does not reference any content-hashed asset."
    while IFS= read -r relative_path; do
        grep -Fq "  $relative_path" "$manifest_file" ||
            fail "index.html references an artifact missing from the manifest: $relative_path"
    done <"$runtime_directory/index-assets.$$.list"
}

verify_manifest() {
    local manifest_file="$1"
    local checksum
    local relative_path

    [[ -s "$manifest_file" ]] || fail "Release manifest is missing or empty."

    while IFS= read -r line; do
        checksum="${line%%  *}"
        relative_path="${line#*  }"
        [[ "$line" != "$relative_path" && "$checksum" =~ ^[0-9a-f]{64}$ ]] ||
            fail "Release manifest contains an invalid checksum entry."
        validate_relative_path "$relative_path"
    done <"$manifest_file"

    [[ "$(grep -c '  index.html$' "$manifest_file")" -eq 1 ]] ||
        fail "Release manifest must contain index.html exactly once."
}

verify_remote_object() {
    local bucket_name="$1"
    local object_key="$2"
    local expected_checksum="$3"
    local expected_cache_control="$4"
    local expected_content_type="$5"
    local head_output
    local remote_checksum
    local remote_cache_control
    local remote_content_type
    local downloaded_file

    head_output="$(
        AWS_PAGER="" aws s3api head-object \
            --region "$AWS_REGION" \
            --bucket "$bucket_name" \
            --key "$object_key" \
            --query '[Metadata.sha256,CacheControl,ContentType]' \
            --output text
    )" || fail "Unable to read uploaded object metadata: s3://$bucket_name/$object_key"

    IFS=$'\t' read -r remote_checksum remote_cache_control remote_content_type <<<"$head_output"
    [[ "$remote_cache_control" == "$expected_cache_control" ]] ||
        fail "Cache-Control mismatch for s3://$bucket_name/$object_key"
    [[ "$remote_content_type" == "$expected_content_type" ]] ||
        fail "Content-Type mismatch for s3://$bucket_name/$object_key"

    if [[ "$remote_checksum" == "$expected_checksum" ]]; then
        return 0
    fi

    downloaded_file="$runtime_directory/remote.$$.artifact"
    AWS_PAGER="" aws s3api get-object \
        --region "$AWS_REGION" \
        --bucket "$bucket_name" \
        --key "$object_key" \
        "$downloaded_file" >/dev/null ||
        fail "Unable to verify existing object content: s3://$bucket_name/$object_key"
    [[ "$(sha256_file "$downloaded_file")" == "$expected_checksum" ]] ||
        fail "Checksum collision detected for s3://$bucket_name/$object_key"
    rm -f -- "$downloaded_file"
}

put_immutable_object() {
    local bucket_name="$1"
    local object_key="$2"
    local source_file="$3"
    local checksum="$4"
    local cache_control="$5"
    local content_type="$6"
    local error_file="$runtime_directory/aws-put.$$.error"

    if AWS_PAGER="" aws s3api put-object \
        --region "$AWS_REGION" \
        --bucket "$bucket_name" \
        --key "$object_key" \
        --body "$source_file" \
        --content-type "$content_type" \
        --cache-control "$cache_control" \
        --metadata "sha256=$checksum,release-sha=$RELEASE_SHA" \
        --if-none-match '*' >/dev/null 2>"$error_file"; then
        return 0
    fi

    if ! grep -Eq 'PreconditionFailed|412' "$error_file"; then
        fail "Immutable object upload failed: s3://$bucket_name/$object_key"
    fi

    verify_remote_object "$bucket_name" "$object_key" "$checksum" "$cache_control" "$content_type"
}

put_mutable_object() {
    local bucket_name="$1"
    local object_key="$2"
    local source_file="$3"
    local checksum="$4"
    local cache_control="$5"
    local content_type="$6"

    AWS_PAGER="" aws s3api put-object \
        --region "$AWS_REGION" \
        --bucket "$bucket_name" \
        --key "$object_key" \
        --body "$source_file" \
        --content-type "$content_type" \
        --cache-control "$cache_control" \
        --metadata "sha256=$checksum,release-sha=$RELEASE_SHA" >/dev/null ||
        fail "Object upload failed: s3://$bucket_name/$object_key"
}

snapshot_release() {
    local application="$1"
    local bucket_name="$2"
    local distribution_directory="$3"
    local manifest_file="$4"
    local checksum
    local relative_path
    local cache_control
    local content_type
    local manifest_checksum

    log "Creating immutable $application release snapshot $RELEASE_SHA."
    while IFS= read -r line; do
        checksum="${line%%  *}"
        relative_path="${line#*  }"
        cache_control="$(cache_control_for "$relative_path")"
        content_type="$(content_type_for "$relative_path")"
        put_immutable_object \
            "$bucket_name" \
            "$RELEASES_PREFIX/$RELEASE_SHA/$relative_path" \
            "$distribution_directory/$relative_path" \
            "$checksum" \
            "$cache_control" \
            "$content_type"
    done <"$manifest_file"

    manifest_checksum="$(sha256_file "$manifest_file")"
    put_immutable_object \
        "$bucket_name" \
        "$RELEASES_PREFIX/$RELEASE_SHA/manifest.sha256" \
        "$manifest_file" \
        "$manifest_checksum" \
        "$SHELL_CACHE_CONTROL" \
        "text/plain; charset=utf-8"
}

publish_category() {
    local application="$1"
    local bucket_name="$2"
    local distribution_directory="$3"
    local manifest_file="$4"
    local selected_category="$5"
    local checksum
    local relative_path
    local cache_control
    local content_type

    log "Publishing $application $selected_category artifacts."
    while IFS= read -r line; do
        checksum="${line%%  *}"
        relative_path="${line#*  }"
        [[ "$(artifact_category "$relative_path")" == "$selected_category" ]] || continue
        cache_control="$(cache_control_for "$relative_path")"
        content_type="$(content_type_for "$relative_path")"

        if [[ "$selected_category" == "asset" ]]; then
            put_immutable_object \
                "$bucket_name" "$relative_path" "$distribution_directory/$relative_path" \
                "$checksum" "$cache_control" "$content_type"
        else
            put_mutable_object \
                "$bucket_name" "$relative_path" "$distribution_directory/$relative_path" \
                "$checksum" "$cache_control" "$content_type"
        fi
    done <"$manifest_file"
}

verify_published_release() {
    local application="$1"
    local bucket_name="$2"
    local manifest_file="$3"
    local checksum
    local relative_path

    log "Verifying $application published object metadata and checksums."
    while IFS= read -r line; do
        checksum="${line%%  *}"
        relative_path="${line#*  }"
        verify_remote_object \
            "$bucket_name" \
            "$relative_path" \
            "$checksum" \
            "$(cache_control_for "$relative_path")" \
            "$(content_type_for "$relative_path")"
    done <"$manifest_file"
}

download_release_snapshot() {
    local application="$1"
    local bucket_name="$2"
    local distribution_directory="$3"
    local manifest_file="$4"
    local checksum
    local relative_path
    local target_file

    mkdir -p "$distribution_directory"
    AWS_PAGER="" aws s3api get-object \
        --region "$AWS_REGION" \
        --bucket "$bucket_name" \
        --key "$RELEASES_PREFIX/$RELEASE_SHA/manifest.sha256" \
        "$manifest_file" >/dev/null ||
        fail "Unable to download the $application rollback manifest for $RELEASE_SHA."
    verify_manifest "$manifest_file"

    while IFS= read -r line; do
        checksum="${line%%  *}"
        relative_path="${line#*  }"
        target_file="$distribution_directory/$relative_path"
        mkdir -p "${target_file%/*}"
        AWS_PAGER="" aws s3api get-object \
            --region "$AWS_REGION" \
            --bucket "$bucket_name" \
            --key "$RELEASES_PREFIX/$RELEASE_SHA/$relative_path" \
            "$target_file" >/dev/null ||
            fail "Unable to download rollback artifact: $application/$relative_path"
        [[ "$(sha256_file "$target_file")" == "$checksum" ]] ||
            fail "Rollback snapshot checksum mismatch: $application/$relative_path"
    done <"$manifest_file"
}

validate_inputs() {
    local variable_name

    (( $# == 1 )) || fail "Usage: deploy-frontends.sh validate|deploy|rollback"
    [[ "$1" == "validate" || "$1" == "deploy" || "$1" == "rollback" ]] ||
        fail "Usage: deploy-frontends.sh validate|deploy|rollback"

    for variable_name in AWS_REGION RELEASE_SHA STORE_BUCKET_NAME ADMIN_BUCKET_NAME VITE_API_BASE_URL; do
        require_environment "$variable_name"
    done

    [[ "$AWS_REGION" == "$EXPECTED_REGION" ]] || fail "AWS_REGION must be $EXPECTED_REGION."
    [[ "$VITE_API_BASE_URL" == "$EXPECTED_API_BASE_URL" ]] ||
        fail "VITE_API_BASE_URL does not match the approved production API endpoint."
    [[ "$RELEASE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "RELEASE_SHA must be a full lowercase Git SHA."
    validate_bucket_name store "$STORE_BUCKET_NAME"
    validate_bucket_name admin "$ADMIN_BUCKET_NAME"

    if [[ "$1" == "validate" || "$1" == "deploy" ]]; then
        require_environment STORE_DIST_DIR
        require_environment ADMIN_DIST_DIR
    fi
}

main() {
    local mode="${1-}"
    local command_name
    local store_distribution_directory
    local admin_distribution_directory
    local store_manifest
    local admin_manifest

    validate_inputs "$@"
    for command_name in awk find grep mkdir mktemp rm sed shasum sort; do
        require_command "$command_name"
    done
    if [[ "$mode" != "validate" ]]; then
        require_command aws
    fi

    umask 077
    runtime_directory="$(mktemp -d /tmp/ec-portfolio-frontend-deploy.XXXXXX)"
    store_manifest="$runtime_directory/store.manifest.sha256"
    admin_manifest="$runtime_directory/admin.manifest.sha256"

    if [[ "$mode" == "validate" || "$mode" == "deploy" ]]; then
        store_distribution_directory="$STORE_DIST_DIR"
        admin_distribution_directory="$ADMIN_DIST_DIR"
        create_manifest "$store_distribution_directory" "$store_manifest"
        create_manifest "$admin_distribution_directory" "$admin_manifest"
        if [[ "$mode" == "validate" ]]; then
            log "Store and Admin artifacts satisfy the deployment contract for $RELEASE_SHA."
            return 0
        fi
        snapshot_release store "$STORE_BUCKET_NAME" "$store_distribution_directory" "$store_manifest"
        snapshot_release admin "$ADMIN_BUCKET_NAME" "$admin_distribution_directory" "$admin_manifest"
    else
        store_distribution_directory="$runtime_directory/store"
        admin_distribution_directory="$runtime_directory/admin"
        download_release_snapshot store "$STORE_BUCKET_NAME" "$store_distribution_directory" "$store_manifest"
        download_release_snapshot admin "$ADMIN_BUCKET_NAME" "$admin_distribution_directory" "$admin_manifest"
    fi

    publish_category store "$STORE_BUCKET_NAME" "$store_distribution_directory" "$store_manifest" asset
    publish_category admin "$ADMIN_BUCKET_NAME" "$admin_distribution_directory" "$admin_manifest" asset
    publish_category store "$STORE_BUCKET_NAME" "$store_distribution_directory" "$store_manifest" non-hashed
    publish_category admin "$ADMIN_BUCKET_NAME" "$admin_distribution_directory" "$admin_manifest" non-hashed
    publish_category store "$STORE_BUCKET_NAME" "$store_distribution_directory" "$store_manifest" index
    publish_category admin "$ADMIN_BUCKET_NAME" "$admin_distribution_directory" "$admin_manifest" index

    verify_published_release store "$STORE_BUCKET_NAME" "$store_manifest"
    verify_published_release admin "$ADMIN_BUCKET_NAME" "$admin_manifest"
    log "Frontend $mode completed for release $RELEASE_SHA without deletion or invalidation."
}

main "$@"
