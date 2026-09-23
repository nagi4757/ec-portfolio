#!/usr/bin/env bash

# Read-only discovery of the Identity Center objects the access root adopts.
#
# It records the baseline the import is gated on: the exact inline policies of
# ECPortfolioTerraformPlan and ECPortfolioTerraformApply with their SHA-256
# digests (raw text and canonical form), and everything about the two permission
# sets that the access root deliberately does not manage -- metadata, AWS
# managed and customer managed policy attachments, permissions boundary,
# provisioned accounts and account assignments. Running it again later and
# comparing the baselines is how the freeze between discovery and import is
# proven.
#
# It calls only Describe, Get and List APIs, stops at the first failed call and
# never retries or falls back to another profile. It refuses to run as anything
# but the access-admin permission set, and refuses to write inside a Git work
# tree: the raw export carries account IDs and principal IDs and must never be
# committed. The summary it prints redacts account IDs and omits principal IDs.
#
# The IAM roles Identity Center provisioned for the two permission sets are
# compared with the inline policies. A difference means an earlier change was
# never provisioned. Adopting a policy in that state would hide the drift behind
# a clean plan, so the discovery stops instead.
#
# Required environment:
#   AWS_PROFILE      the access-admin profile
#   OUT_DIR          absolute path of a directory that does not exist yet and is
#                    outside every Git work tree
#   PLAN_ROLE_NAME   AWSReservedSSO_ECPortfolioTerraformPlan_<suffix>
#   APPLY_ROLE_NAME  AWSReservedSSO_ECPortfolioTerraformApply_<suffix>

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly POLICY_GATE="$SCRIPT_DIRECTORY/policy-gate.sh"
readonly LOG_PREFIX="[access-discovery]"
readonly IDENTITY_CENTER_REGION="ap-northeast-1"
readonly ACCESS_ADMIN_SESSION_PATTERN='^arn:aws:sts::[0-9]{12}:assumed-role/AWSReservedSSO_ECPortfolioAccessAdmin_[0-9a-f]+/[^/]+$'
readonly PLAN_PERMISSION_SET_NAME="ECPortfolioTerraformPlan"
readonly APPLY_PERMISSION_SET_NAME="ECPortfolioTerraformApply"
# The name Identity Center gives the inline policy on the roles it provisions.
readonly RESERVED_ROLE_INLINE_POLICY_NAME="AwsSSOInlinePolicy"

# Set once in main and read by the per-permission-set discovery.
raw_directory=""
baseline_file=""
instance_arn=""
caller_account=""

refuse() {
    printf '%s REFUSED: %s\n' "$LOG_PREFIX" "$*" >&2
    exit 2
}

fail() {
    printf '%s STOP: %s\n' "$LOG_PREFIX" "$*" >&2
    exit 3
}

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

redact() {
    sed -E 's/[0-9]{12}/<ACCOUNT>/g'
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || refuse "Required command is not available: $1"
}

sha256_of_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- "$1" | cut -d ' ' -f 1
    else
        shasum -a 256 -- "$1" | cut -d ' ' -f 1
    fi
}

nearest_existing_directory() {
    local path="$1"
    while [[ ! -d "$path" ]]; do
        path="$(dirname -- "$path")"
    done
    printf '%s' "$path"
}

validate_inputs() {
    local name
    for name in AWS_PROFILE OUT_DIR PLAN_ROLE_NAME APPLY_ROLE_NAME; do
        [[ -n "${!name:-}" ]] || refuse "$name must be set explicitly"
    done

    [[ "$PLAN_ROLE_NAME" =~ ^AWSReservedSSO_ECPortfolioTerraformPlan_[0-9a-f]+$ ]] ||
        refuse "PLAN_ROLE_NAME is not the reserved role of $PLAN_PERMISSION_SET_NAME"
    [[ "$APPLY_ROLE_NAME" =~ ^AWSReservedSSO_ECPortfolioTerraformApply_[0-9a-f]+$ ]] ||
        refuse "APPLY_ROLE_NAME is not the reserved role of $APPLY_PERMISSION_SET_NAME"

    [[ "$OUT_DIR" == /* ]] || refuse "OUT_DIR must be an absolute path"
    [[ ! -e "$OUT_DIR" ]] || refuse "OUT_DIR must not exist yet; every run writes a fresh baseline"

    local ancestor
    ancestor="$(nearest_existing_directory "$OUT_DIR")"
    if [[ "$(git -C "$ancestor" rev-parse --is-inside-work-tree 2>/dev/null || true)" == "true" ]]; then
        refuse "OUT_DIR is inside a Git work tree; the raw export carries account and principal IDs"
    fi
}

# Reduces an AWS CLI error to its error code, operation and denied action. The
# full message stays in the errors directory; it names ARNs and is not printed.
summarize_aws_error() {
    local summary
    summary="$(grep -oE '\([A-Za-z]+\) when calling the [A-Za-z]+ operation|not authorized to perform: [A-Za-z0-9:-]+' "$1" |
        tr '\n' ' ' || true)"
    [[ -n "$summary" ]] || summary="$(head -c 300 "$1")"
    printf '%s' "$summary" | redact
}

# Runs one read-only AWS CLI call and saves its JSON output. The first failure
# stops the discovery.
aws_json() {
    local output_file="$1"
    shift
    local error_file
    error_file="$OUT_DIR/errors/$(basename -- "$output_file" .json).err"

    if aws "$@" --region "$IDENTITY_CENTER_REGION" --output json >"$output_file" 2>"$error_file"; then
        rm -f -- "$error_file"
        return 0
    fi
    fail "aws $1 $2 failed: $(summarize_aws_error "$error_file")"
}

# For calls that report "not configured" as an error code instead of an empty
# result, such as a permission set without a permissions boundary.
aws_json_allow_absent() {
    local output_file="$1" absent_code="$2"
    shift 2
    local error_file
    error_file="$OUT_DIR/errors/$(basename -- "$output_file" .json).err"

    if aws "$@" --region "$IDENTITY_CENTER_REGION" --output json >"$output_file" 2>"$error_file"; then
        rm -f -- "$error_file"
        return 0
    fi
    if grep -q "($absent_code)" "$error_file"; then
        printf '{"__absent__": "%s"}\n' "$absent_code" >"$output_file"
        rm -f -- "$error_file"
        return 0
    fi
    fail "aws $1 $2 failed: $(summarize_aws_error "$error_file")"
}

permission_set_arn_by_name() {
    local name="$1"
    jq -rs --arg name "$name" '
        [.[].PermissionSet | select(.Name == $name) | .PermissionSetArn]
        | if length == 1 then .[0]
          else error("expected exactly one permission set named \($name), found \(length)")
          end
    ' "$raw_directory"/describe.*.json
}

discover_permission_set() {
    local name="$1" role_name="$2"
    local arn prefix
    arn="$(permission_set_arn_by_name "$name")" || fail "cannot resolve the permission set $name"
    prefix="$raw_directory/$name"
    local scope=(--instance-arn "$instance_arn" --permission-set-arn "$arn")

    # The policy text is written exactly as Identity Center returns it (-j adds
    # no newline), so the raw digest is the digest of the live document.
    aws_json "$prefix.inline-response.json" sso-admin get-inline-policy-for-permission-set "${scope[@]}"
    local policy_file="$OUT_DIR/$name.inline-policy.json"
    jq -j '.InlinePolicy // ""' "$prefix.inline-response.json" >"$policy_file"
    [[ -s "$policy_file" ]] || fail "$name has no inline policy; there is nothing to import"

    local raw_digest canonical_digest statement_count non_whitespace_characters
    raw_digest="$(sha256_of_file "$policy_file")"
    canonical_digest="$("$POLICY_GATE" canonical "$policy_file")" ||
        fail "the $name inline policy cannot be canonicalized"
    statement_count="$(jq '.Statement | if type == "array" then length else 1 end' "$policy_file")"
    non_whitespace_characters="$(tr -d '[:space:]' <"$policy_file" | wc -c | tr -d ' ')"

    aws_json "$prefix.managed.json" sso-admin list-managed-policies-in-permission-set "${scope[@]}"
    aws_json "$prefix.customer-managed.json" \
        sso-admin list-customer-managed-policy-references-in-permission-set "${scope[@]}"
    aws_json_allow_absent "$prefix.boundary.json" ResourceNotFoundException \
        sso-admin get-permissions-boundary-for-permission-set "${scope[@]}"
    aws_json "$prefix.tags.json" sso-admin list-tags-for-resource \
        --instance-arn "$instance_arn" --resource-arn "$arn"
    aws_json "$prefix.accounts.json" sso-admin list-accounts-for-provisioned-permission-set "${scope[@]}"

    # The reserved role check below reads IAM in the caller's account, so it can
    # only vouch for a permission set provisioned there and nowhere else.
    local provisioned_accounts
    provisioned_accounts="$(jq -r '.AccountIds | sort | join(",")' "$prefix.accounts.json")"
    [[ "$provisioned_accounts" == "$caller_account" ]] ||
        fail "$name is provisioned to [$(printf '%s' "$provisioned_accounts" | redact)], not only to the caller's account"

    aws_json "$prefix.assignments.json" sso-admin list-account-assignments \
        --account-id "$caller_account" --permission-set-arn "$arn" --instance-arn "$instance_arn"

    aws_json "$prefix.role-policies.json" iam list-role-policies --role-name "$role_name"
    jq -e --arg policy "$RESERVED_ROLE_INLINE_POLICY_NAME" '.PolicyNames | any(. == $policy)' \
        "$prefix.role-policies.json" >/dev/null ||
        fail "$role_name has no $RESERVED_ROLE_INLINE_POLICY_NAME; the inline policy was never provisioned"
    aws_json "$prefix.role-inline.json" iam get-role-policy \
        --role-name "$role_name" --policy-name "$RESERVED_ROLE_INLINE_POLICY_NAME"

    local role_policy_file="$raw_directory/$name.role-inline-policy.json"
    jq -e '.PolicyDocument | if type == "object" then . else error("PolicyDocument is not decoded JSON") end' \
        "$prefix.role-inline.json" >"$role_policy_file" 2>/dev/null ||
        fail "cannot read the inline policy document of $role_name"
    "$POLICY_GATE" compare "$policy_file" "$role_policy_file" >/dev/null 2>"$OUT_DIR/errors/$name.drift.err" ||
        fail "$role_name does not carry the current $name inline policy; an earlier change was never provisioned (details: $OUT_DIR/errors/$name.drift.err)"
    rm -f -- "$OUT_DIR/errors/$name.drift.err"

    aws_json "$prefix.role-attached.json" iam list-attached-role-policies --role-name "$role_name"

    local describe_file="$raw_directory/describe.${arn##*/}.json"
    {
        printf '%s.permission_set_arn=%s\n' "$name" "$arn"
        printf '%s.session_duration=%s\n' "$name" "$(jq -r '.PermissionSet.SessionDuration // ""' "$describe_file")"
        printf '%s.relay_state=%s\n' "$name" "$(jq -r '.PermissionSet.RelayState // ""' "$describe_file")"
        printf '%s.description=%s\n' "$name" "$(jq -r '.PermissionSet.Description // ""' "$describe_file")"
        printf '%s.tags=%s\n' "$name" "$(jq -c '.Tags // [] | sort_by(.Key)' "$prefix.tags.json")"
        printf '%s.inline_policy.raw_sha256=%s\n' "$name" "$raw_digest"
        printf '%s.inline_policy.canonical_sha256=%s\n' "$name" "$canonical_digest"
        printf '%s.inline_policy.statement_count=%s\n' "$name" "$statement_count"
        printf '%s.inline_policy.non_whitespace_characters=%s\n' "$name" "$non_whitespace_characters"
        printf '%s.managed_policies=%s\n' "$name" \
            "$(jq -c '[.AttachedManagedPolicies[]?.Arn] | sort' "$prefix.managed.json")"
        printf '%s.customer_managed_policies=%s\n' "$name" \
            "$(jq -c '[.CustomerManagedPolicyReferences[]? | "\(.Path // "/")\(.Name)"] | sort' "$prefix.customer-managed.json")"
        printf '%s.permissions_boundary=%s\n' "$name" \
            "$(jq -c 'if has("__absent__") then "absent" else .PermissionsBoundary end' "$prefix.boundary.json")"
        printf '%s.provisioned_accounts=%s\n' "$name" "$provisioned_accounts"
        printf '%s.account_assignments=%s\n' "$name" \
            "$(jq -c '[.AccountAssignments[]? | {AccountId, PrincipalType, PrincipalId}] | sort_by(.PrincipalType, .PrincipalId)' "$prefix.assignments.json")"
        printf '%s.reserved_role=%s\n' "$name" "$role_name"
        printf '%s.reserved_role_inline_policy=matches\n' "$name"
        printf '%s.reserved_role_attached_policies=%s\n' "$name" \
            "$(jq -c '[.AttachedPolicies[]?.PolicyArn] | sort' "$prefix.role-attached.json")"
    } >>"$baseline_file"
}

print_summary() {
    local name
    log "baseline: $baseline_file"
    grep -E '^(instance_arn|instance_owner_is_caller_account|permission_set_names)=' "$baseline_file" | redact
    for name in "$PLAN_PERMISSION_SET_NAME" "$APPLY_PERMISSION_SET_NAME"; do
        grep -E "^$name\\.(permission_set_arn|session_duration|tags|inline_policy\\.[a-z0-9_]+|managed_policies|customer_managed_policies|permissions_boundary|provisioned_accounts|reserved_role_inline_policy|reserved_role_attached_policies)=" \
            "$baseline_file" | redact
        # Principal IDs stay in the baseline file; the summary shows their shape only.
        printf '%s.account_assignments=%s\n' "$name" "$(jq -r '
            [.AccountAssignments[]?.PrincipalType] | group_by(.) | map("\(.[0])x\(length)") | join(",")
        ' "$raw_directory/$name.assignments.json")"
    done
}

main() {
    require_command aws
    require_command jq
    require_command git
    validate_inputs

    umask 077
    mkdir -p -- "$OUT_DIR/raw" "$OUT_DIR/errors"
    chmod 700 "$OUT_DIR"
    raw_directory="$OUT_DIR/raw"
    baseline_file="$OUT_DIR/baseline.txt"

    log "read-only discovery with profile $AWS_PROFILE"

    aws_json "$raw_directory/caller.json" sts get-caller-identity
    local caller_arn
    caller_arn="$(jq -r '.Arn' "$raw_directory/caller.json")"
    caller_account="$(jq -r '.Account' "$raw_directory/caller.json")"
    [[ "$caller_arn" =~ $ACCESS_ADMIN_SESSION_PATTERN ]] ||
        fail "the caller is not the ECPortfolioAccessAdmin permission set: $(printf '%s' "$caller_arn" | redact)"

    aws_json "$raw_directory/instances.json" sso-admin list-instances
    [[ "$(jq '.Instances | length' "$raw_directory/instances.json")" == "1" ]] ||
        fail "expected exactly one Identity Center instance"
    instance_arn="$(jq -r '.Instances[0].InstanceArn' "$raw_directory/instances.json")"

    aws_json "$raw_directory/permission-sets.json" sso-admin list-permission-sets --instance-arn "$instance_arn"
    [[ "$(jq '.PermissionSets | length' "$raw_directory/permission-sets.json")" != "0" ]] ||
        fail "the Identity Center instance has no permission sets"
    local permission_set_arn
    for permission_set_arn in $(jq -r '.PermissionSets[]' "$raw_directory/permission-sets.json"); do
        aws_json "$raw_directory/describe.${permission_set_arn##*/}.json" sso-admin describe-permission-set \
            --instance-arn "$instance_arn" --permission-set-arn "$permission_set_arn"
    done

    {
        printf 'discovered_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'caller_arn=%s\n' "$caller_arn"
        printf 'instance_arn=%s\n' "$instance_arn"
        printf 'identity_store_id=%s\n' "$(jq -r '.Instances[0].IdentityStoreId' "$raw_directory/instances.json")"
        printf 'instance_owner_is_caller_account=%s\n' \
            "$(jq -r --arg account "$caller_account" '.Instances[0].OwnerAccountId == $account' "$raw_directory/instances.json")"
        printf 'permission_set_names=%s\n' \
            "$(jq -rs '[.[].PermissionSet.Name] | sort | join(",")' "$raw_directory"/describe.*.json)"
    } >"$baseline_file"

    discover_permission_set "$PLAN_PERMISSION_SET_NAME" "$PLAN_ROLE_NAME"
    discover_permission_set "$APPLY_PERMISSION_SET_NAME" "$APPLY_ROLE_NAME"

    print_summary
    log "DONE: read-only discovery complete; no AWS resource was changed"
}

main "$@"
