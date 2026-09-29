#!/usr/bin/env bash

# The Spot runtime bundle contract, across the three places that name it.
#
#   infra/terraform/demo/runtime_artifacts.tf      spot_bundle_manifest_artifacts
#                                                   builds the archive and its
#                                                   bundle.sha256
#   infra/terraform/demo/templates/
#     ecs-spot-user-data.sh.tftpl                   BUNDLE_EXECUTABLES and
#                                                   BUNDLE_DATA_FILES set modes
#                                                   after extraction
#   infra/runtime/demo/bootstrap-spot-host.sh       REQUIRED_BUNDLE_ARTIFACTS is
#                                                   what the host insists on
#
# A file added to one and not the others fails on a host, at launch, as an
# ABANDON. This suite fails it here instead. It then builds a bundle the way
# Terraform does -- the listed files plus a sha256sum-format manifest -- applies
# the loader's modes, and runs the bootstrap's own verification on it, so a pass
# means the real host-side checks accept the real files.
#
# No AWS, no Terraform, no root. Runs under bash 3.2 and bash 5.

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly RUNTIME_DIRECTORY="$SCRIPT_DIRECTORY"
readonly TERRAFORM_DIRECTORY="$SCRIPT_DIRECTORY/../../terraform/demo"
readonly ARTIFACTS_TF="$TERRAFORM_DIRECTORY/runtime_artifacts.tf"
readonly LOCALS_TF="$TERRAFORM_DIRECTORY/locals.tf"
readonly LOADER_TEMPLATE="$TERRAFORM_DIRECTORY/templates/ecs-spot-user-data.sh.tftpl"
readonly BOOTSTRAP_SCRIPT="$RUNTIME_DIRECTORY/bootstrap-spot-host.sh"
readonly POST_UNIT_FILE="$RUNTIME_DIRECTORY/ec-portfolio-spot-post-bootstrap.service"

work_directory=""

cleanup_tests() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-spot-bundle-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup_tests EXIT

fail() {
    printf '[spot-bundle-test] FAIL: %s\n' "$*" >&2
    exit 1
}

work_directory="$(mktemp -d /tmp/ec-portfolio-spot-bundle-test.XXXXXX)"

sorted_words() {
    tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort
}

# ---------------------------------------------------------------------------
# 1. The three lists
# ---------------------------------------------------------------------------

terraform_list="$(awk '
    /spot_bundle_manifest_artifacts[[:space:]]*=[[:space:]]*\[/ { inside = 1; next }
    inside && /^[[:space:]]*\]/ { exit }
    inside { if (match($0, /"[^"]+"/)) print substr($0, RSTART + 1, RLENGTH - 2) }' "$ARTIFACTS_TF")"
[[ -n "$terraform_list" ]] || fail "spot_bundle_manifest_artifacts could not be read from $ARTIFACTS_TF."

bootstrap_list="$(bash -c 'source "$1"; printf "%s\n" "${REQUIRED_BUNDLE_ARTIFACTS[@]}"' _ "$BOOTSTRAP_SCRIPT")"

loader_executables="$(sed -n 's/^readonly BUNDLE_EXECUTABLES="\(.*\)"$/\1/p' "$LOADER_TEMPLATE")"
loader_data_files="$(sed -n 's/^readonly BUNDLE_DATA_FILES="\(.*\)"$/\1/p' "$LOADER_TEMPLATE")"
[[ -n "$loader_executables" && -n "$loader_data_files" ]] ||
    fail "The loader's file-mode lists could not be read from $LOADER_TEMPLATE."

# Terraform's manifest list and the bootstrap's required list are the same set,
# in the same order (the manifest is generated in list order).
[[ "$terraform_list" == "$bootstrap_list" ]] ||
    fail "runtime_artifacts.tf and bootstrap-spot-host.sh must list the same artifacts in the same order.
  terraform: $(tr '\n' ' ' <<<"$terraform_list")
  bootstrap: $(tr '\n' ' ' <<<"$bootstrap_list")"

# No name appears twice anywhere.
for list_name in terraform_list bootstrap_list; do
    duplicates="$(printf '%s\n' "${!list_name}" | LC_ALL=C sort | uniq -d)"
    [[ -z "$duplicates" ]] || fail "$list_name names a file twice: $duplicates"
done
duplicates="$(printf '%s %s' "$loader_executables" "$loader_data_files" | sorted_words | uniq -d)"
[[ -z "$duplicates" ]] || fail "The loader names a file in both mode lists: $duplicates"

# The loader covers exactly the bootstrap, the required artifacts and the
# manifest -- scripts as executables, everything else as data.
expected_executables="$( { printf 'bootstrap-spot-host.sh\n'; grep '\.sh$' <<<"$bootstrap_list"; } | LC_ALL=C sort)"
expected_data="$( { grep -v '\.sh$' <<<"$bootstrap_list" || true; printf 'bundle.sha256\n'; } | LC_ALL=C sort)"
[[ "$(sorted_words <<<"$loader_executables")" == "$expected_executables" ]] ||
    fail "BUNDLE_EXECUTABLES must be the bootstrap plus every required .sh.
  loader:   $loader_executables
  expected: $(tr '\n' ' ' <<<"$expected_executables")"
[[ "$(sorted_words <<<"$loader_data_files")" == "$expected_data" ]] ||
    fail "BUNDLE_DATA_FILES must be every required non-script plus bundle.sha256.
  loader:   $loader_data_files
  expected: $(tr '\n' ' ' <<<"$expected_data")"

# Every listed file is a reviewed repository file.
while IFS= read -r name; do
    [[ -f "$RUNTIME_DIRECTORY/$name" ]] || fail "The bundle lists $name, which is not in infra/runtime/demo."
done <<<"$bootstrap_list"

# The Phase 6C-4a artifacts are in all three.
for name in imds-guard.sh ec-portfolio-imds-guard.service ec-portfolio-spot-post-bootstrap.service; do
    grep -qxF "$name" <<<"$terraform_list" || fail "runtime_artifacts.tf must ship $name."
    grep -qxF "$name" <<<"$bootstrap_list" || fail "bootstrap-spot-host.sh must require $name."
    grep -qwF "$name" <<<"$loader_executables $loader_data_files" || fail "The loader must set the mode of $name."
done

# ---------------------------------------------------------------------------
# 2. Where the bundle lands, as the post unit runs it
# ---------------------------------------------------------------------------

host_directory="$(sed -n 's/^[[:space:]]*spot_runtime_host_directory[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$LOCALS_TF")"
[[ -n "$host_directory" ]] || fail "spot_runtime_host_directory could not be read from $LOCALS_TF."
grep -qxF "ExecStart=$host_directory/bootstrap-spot-host.sh post" "$POST_UNIT_FILE" ||
    fail "The post unit must run the bootstrap from $host_directory, where the loader extracts it."

# ---------------------------------------------------------------------------
# 3. End to end: build, extract, set modes, verify with the bootstrap itself
# ---------------------------------------------------------------------------

# The manifest in the format runtime_artifacts.tf writes: digest, two spaces,
# name, one line per required artifact in list order.
write_manifest() {
    local directory="$1" name digest
    : >"$directory/bundle.sha256"
    while IFS= read -r name; do
        digest="$(sha256sum -- "$directory/$name" | awk '{ print $1 }')"
        printf '%s  %s\n' "$digest" "$name" >>"$directory/bundle.sha256"
    done <<<"$terraform_list"
}

build_archive() {
    local staging="$1" archive="$2" name
    rm -rf "$staging"; mkdir -p "$staging"
    cp "$BOOTSTRAP_SCRIPT" "$staging/bootstrap-spot-host.sh"
    while IFS= read -r name; do
        cp "$RUNTIME_DIRECTORY/$name" "$staging/$name"
    done <<<"$terraform_list"
    write_manifest "$staging"
    # Terraform's archive entries carry no useful mode; model that by stripping
    # every permission bit the loader is responsible for restoring.
    chmod 0400 "$staging"/*
    ( cd "$staging" && tar -czf "$archive" -- * )
}

# The loader's extraction and mode normalisation, from its own two lists.
extract_like_loader() {
    local archive="$1" destination="$2" name
    rm -rf "$destination"; mkdir -p "$destination"
    tar -xzf "$archive" -C "$destination"
    for name in $loader_executables; do
        [[ -f "$destination/$name" ]] || return 1
        chmod 0755 "$destination/$name"
    done
    for name in $loader_data_files; do
        [[ -f "$destination/$name" ]] || return 1
        chmod 0644 "$destination/$name"
    done
}

# The bootstrap's own checks, sourced from the extracted copy. The prefix keeps
# the cleanup's paths inside the sandbox.
bootstrap_accepts() {
    local destination="$1"
    env SPOT_BOOTSTRAP_PREFIX="$work_directory/prefix" \
        bash -c 'source "$1"; resolve_bundle; verify_bundle_checksums' _ "$destination/bootstrap-spot-host.sh" \
        >"$work_directory/verify.out" 2>&1
}

archive="$work_directory/spot-runtime.tar.gz"
build_archive "$work_directory/staging" "$archive"

listed="$(tar -tzf "$archive" | sed 's|^\./||' | LC_ALL=C sort)"
expected_entries="$( { printf 'bootstrap-spot-host.sh\nbundle.sha256\n'; printf '%s\n' "$terraform_list"; } | LC_ALL=C sort)"
[[ "$listed" == "$expected_entries" ]] ||
    fail "The archive must hold exactly the bootstrap, the manifest and the required artifacts.
  archive:  $(tr '\n' ' ' <<<"$listed")
  expected: $(tr '\n' ' ' <<<"$expected_entries")"

extract_like_loader "$archive" "$work_directory/extracted" ||
    fail "The loader's lists must find every file in the archive."
bootstrap_accepts "$work_directory/extracted" ||
    fail "The bootstrap must accept a bundle built from the repository. Output: $(cat "$work_directory/verify.out")"
grep -q "imds-guard.sh" "$work_directory/extracted/bundle.sha256" ||
    fail "The manifest must carry a checksum for imds-guard.sh."

# A changed byte in any shipped file is refused.
for name in imds-guard.sh ec-portfolio-spot-post-bootstrap.service configure-origin.sh; do
    extract_like_loader "$archive" "$work_directory/tampered" || fail "extraction failed"
    printf '# tampered\n' >>"$work_directory/tampered/$name"
    if bootstrap_accepts "$work_directory/tampered"; then
        fail "A bundle whose $name no longer matches its checksum must be refused."
    fi
done

# A manifest that stops covering a Phase 6C-4a artifact is refused.
for name in imds-guard.sh ec-portfolio-imds-guard.service ec-portfolio-spot-post-bootstrap.service; do
    extract_like_loader "$archive" "$work_directory/short-manifest" || fail "extraction failed"
    grep -vF "  $name" "$work_directory/short-manifest/bundle.sha256" >"$work_directory/manifest.tmp"
    cat "$work_directory/manifest.tmp" >"$work_directory/short-manifest/bundle.sha256"
    if bootstrap_accepts "$work_directory/short-manifest"; then
        fail "A manifest that omits $name must be refused."
    fi
done

# Without the loader's mode step, the scripts are not executable and the
# bootstrap refuses them: the modes are part of the contract, not decoration.
rm -rf "$work_directory/no-modes"; mkdir -p "$work_directory/no-modes"
tar -xzf "$archive" -C "$work_directory/no-modes"
chmod 0644 "$work_directory/no-modes"/*
chmod 0755 "$work_directory/no-modes/bootstrap-spot-host.sh"
if bootstrap_accepts "$work_directory/no-modes"; then
    fail "A bundle whose helper scripts are not executable must be refused."
fi

printf '[spot-bundle-test] PASS\n'
