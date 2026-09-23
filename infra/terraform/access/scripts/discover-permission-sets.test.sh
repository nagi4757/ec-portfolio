#!/usr/bin/env bash

# Behaviour tests for the read-only permission set discovery.
#
# The aws command is replaced by a stub that answers from fixture files and
# records every call, so no request reaches AWS. The tests prove the refusals
# happen before any call, that every call is a read, that the baseline digests
# are the digests of the exported text, and that provisioning drift stops the
# discovery.

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly DISCOVERY_SCRIPT="$SCRIPT_DIRECTORY/discover-permission-sets.sh"
readonly GATE_SCRIPT="$SCRIPT_DIRECTORY/policy-gate.sh"

readonly ACCOUNT_ID="111122223333"
readonly INSTANCE_ARN="arn:aws:sso:::instance/ssoins-0000000000000001"
readonly PLAN_ROLE="AWSReservedSSO_ECPortfolioTerraformPlan_0123456789abcdef"
readonly APPLY_ROLE="AWSReservedSSO_ECPortfolioTerraformApply_fedcba9876543210"

work_directory=""

cleanup_tests() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-access-discovery-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup_tests EXIT

fail() {
    printf '[access-discovery-test] FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "$3 (expected to find: $2)"
}

assert_absent() {
    [[ "$1" != *"$2"* ]] || fail "$3 (unexpectedly found: $2)"
}

sha256_of_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- "$1" | cut -d ' ' -f 1
    else
        shasum -a 256 -- "$1" | cut -d ' ' -f 1
    fi
}

mode_of() {
    stat -f %Lp -- "$1" 2>/dev/null || stat -c %a -- "$1"
}

work_directory="$(mktemp -d /tmp/ec-portfolio-access-discovery-test.XXXXXX)"
readonly STUB_BIN="$work_directory/bin"
export FIXTURES="$work_directory/fixtures"
export CALLS_LOG="$work_directory/calls.log"
mkdir -p "$STUB_BIN" "$FIXTURES"

# The stub resolves a call to <service>.<operation>[.<key>].json or .err, where
# the key is the permission set ID or role name the call is about.
cat >"$STUB_BIN/aws" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CALLS_LOG"
service="$1"
operation="$2"
shift 2
key=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --permission-set-arn | --resource-arn) key="${2##*/}"; shift 2 ;;
        --role-name) key="$2"; shift 2 ;;
        *) shift ;;
    esac
done
base="$FIXTURES/$service.$operation"
if [[ -n "$key" && ( -e "$base.$key.json" || -e "$base.$key.err" ) ]]; then
    base="$base.$key"
fi
if [[ -f "$base.err" ]]; then
    cat "$base.err" >&2
    exit 254
fi
if [[ -f "$base.json" ]]; then
    cat "$base.json"
    exit 0
fi
printf 'stub: no fixture for %s %s %s\n' "$service" "$operation" "$key" >&2
exit 255
STUB
chmod 755 "$STUB_BIN/aws"

fixture() {
    cat >"$FIXTURES/$1"
}

readonly PLAN_POLICY='{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DemoStateRead",
      "Effect": "Allow",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::example-state/demo/terraform.tfstate"
    }
  ]
}'
readonly APPLY_POLICY='{"Version":"2012-10-17","Statement":[{"Sid":"DemoStateWrite","Effect":"Allow","Action":["s3:GetObject","s3:PutObject"],"Resource":"arn:aws:s3:::example-state/demo/terraform.tfstate"}]}'

write_fixtures() {
    rm -f "$FIXTURES"/*
    fixture sts.get-caller-identity.json <<JSON
{"Account": "$ACCOUNT_ID", "UserId": "AROAEXAMPLE:tester",
 "Arn": "arn:aws:sts::$ACCOUNT_ID:assumed-role/AWSReservedSSO_ECPortfolioAccessAdmin_00aa11bb22cc33dd/tester"}
JSON
    fixture sso-admin.list-instances.json <<JSON
{"Instances": [{"InstanceArn": "$INSTANCE_ARN", "IdentityStoreId": "d-0000000001",
                "OwnerAccountId": "$ACCOUNT_ID", "Status": "ACTIVE"}]}
JSON
    fixture sso-admin.list-permission-sets.json <<JSON
{"PermissionSets": ["$INSTANCE_ARN/ps-plan", "$INSTANCE_ARN/ps-apply", "$INSTANCE_ARN/ps-other"]}
JSON
    local id name
    for id in plan apply other; do
        case "$id" in
            plan) name="ECPortfolioTerraformPlan" ;;
            apply) name="ECPortfolioTerraformApply" ;;
            other) name="ECPortfolioECRPush" ;;
        esac
        fixture "sso-admin.describe-permission-set.ps-$id.json" <<JSON
{"PermissionSet": {"Name": "$name", "PermissionSetArn": "$INSTANCE_ARN/ps-$id", "SessionDuration": "PT1H"}}
JSON
    done
    jq -n --arg policy "$PLAN_POLICY" '{InlinePolicy: $policy}' \
        >"$FIXTURES/sso-admin.get-inline-policy-for-permission-set.ps-plan.json"
    jq -n --arg policy "$APPLY_POLICY" '{InlinePolicy: $policy}' \
        >"$FIXTURES/sso-admin.get-inline-policy-for-permission-set.ps-apply.json"
    printf '{"AttachedManagedPolicies": []}\n' | fixture sso-admin.list-managed-policies-in-permission-set.json
    printf '{"CustomerManagedPolicyReferences": []}\n' |
        fixture sso-admin.list-customer-managed-policy-references-in-permission-set.json
    printf 'An error occurred (ResourceNotFoundException) when calling the GetPermissionsBoundaryForPermissionSet operation: none\n' |
        fixture sso-admin.get-permissions-boundary-for-permission-set.err
    printf '{"Tags": []}\n' | fixture sso-admin.list-tags-for-resource.json
    printf '{"AccountIds": ["%s"]}\n' "$ACCOUNT_ID" | fixture sso-admin.list-accounts-for-provisioned-permission-set.json
    printf '{"AccountAssignments": [{"AccountId": "%s", "PrincipalType": "USER", "PrincipalId": "90000000-0000-0000-0000-000000000001"}]}\n' \
        "$ACCOUNT_ID" | fixture sso-admin.list-account-assignments.json
    printf '{"PolicyNames": ["AwsSSOInlinePolicy"]}\n' | fixture iam.list-role-policies.json
    printf '{"AttachedPolicies": []}\n' | fixture iam.list-attached-role-policies.json
    # The provisioned roles carry the same policies, formatted differently.
    jq -n --argjson policy "$PLAN_POLICY" '{PolicyName: "AwsSSOInlinePolicy", PolicyDocument: $policy}' \
        >"$FIXTURES/iam.get-role-policy.$PLAN_ROLE.json"
    jq -n --argjson policy "$APPLY_POLICY" '{PolicyName: "AwsSSOInlinePolicy", PolicyDocument: $policy}' \
        >"$FIXTURES/iam.get-role-policy.$APPLY_ROLE.json"
}

run_count=0

# Runs the discovery against the stub with a fresh OUT_DIR unless one is given.
run_discovery() {
    run_count=$((run_count + 1))
    out_directory="${1:-$work_directory/out/run-$run_count}"
    : >"$CALLS_LOG"
    discovery_status=0
    discovery_output="$(PATH="$STUB_BIN:$PATH" \
        AWS_PROFILE="ec-portfolio-access-admin" OUT_DIR="$out_directory" \
        PLAN_ROLE_NAME="${PLAN_ROLE_NAME_OVERRIDE:-$PLAN_ROLE}" APPLY_ROLE_NAME="$APPLY_ROLE" \
        "$DISCOVERY_SCRIPT" 2>&1)" || discovery_status=$?
    calls="$(cat "$CALLS_LOG")"
}

expect_refused_without_calls() {
    ((discovery_status == 2)) || fail "$1 (exit $discovery_status): $discovery_output"
    assert_contains "$discovery_output" "REFUSED" "$1"
    [[ -z "$calls" ]] || fail "$1: AWS was called before the refusal: $calls"
}

write_fixtures

# --- 1. unsafe inputs are refused before any AWS call ------------------------

run_discovery "relative/out"
expect_refused_without_calls "A relative OUT_DIR must be refused."

mkdir -p "$work_directory/existing"
run_discovery "$work_directory/existing"
expect_refused_without_calls "An existing OUT_DIR must be refused so a baseline is never overwritten."

git init -q "$work_directory/repository"
run_discovery "$work_directory/repository/nested/baseline"
expect_refused_without_calls "An OUT_DIR inside a Git work tree must be refused."
assert_contains "$discovery_output" "inside a Git work tree" "The Git refusal must say why."
[[ ! -e "$work_directory/repository/nested" ]] || fail "A refused OUT_DIR must not be created."

PLAN_ROLE_NAME_OVERRIDE="AWSReservedSSO_ECPortfolioTerraformApply_0123456789abcdef"
run_discovery
unset PLAN_ROLE_NAME_OVERRIDE
expect_refused_without_calls "A role name of the wrong permission set must be refused."

# --- 2. the happy path is read-only and records exact digests ----------------

run_discovery
((discovery_status == 0)) || fail "The discovery must succeed on consistent fixtures (exit $discovery_status): $discovery_output"
baseline="$(cat "$out_directory/baseline.txt")"

printf '%s' "$PLAN_POLICY" >"$work_directory/expected-plan-policy.json"
assert_contains "$baseline" \
    "ECPortfolioTerraformPlan.inline_policy.raw_sha256=$(sha256_of_file "$work_directory/expected-plan-policy.json")" \
    "The raw digest must be the digest of the exported text, byte for byte."
cmp -s "$work_directory/expected-plan-policy.json" "$out_directory/ECPortfolioTerraformPlan.inline-policy.json" ||
    fail "The exported policy must be the Identity Center text without any added byte."
assert_contains "$baseline" \
    "ECPortfolioTerraformPlan.inline_policy.canonical_sha256=$("$GATE_SCRIPT" canonical "$work_directory/expected-plan-policy.json")" \
    "The canonical digest must come from the policy gate."
assert_contains "$baseline" "ECPortfolioTerraformPlan.permissions_boundary=\"absent\"" \
    "A missing permissions boundary must be recorded as absent, not fail the discovery."
assert_contains "$baseline" "ECPortfolioTerraformApply.reserved_role_inline_policy=matches" \
    "The reserved role comparison must be recorded."
assert_contains "$baseline" "permission_set_names=ECPortfolioECRPush,ECPortfolioTerraformApply,ECPortfolioTerraformPlan" \
    "Every permission set name must be recorded."

mutating_calls="$(grep -E '(^| )(put|create|delete|update|provision|attach|detach|tag|untag)-' "$CALLS_LOG" || true)"
[[ -z "$mutating_calls" ]] || fail "The discovery must only read: $mutating_calls"

assert_absent "$discovery_output" "$ACCOUNT_ID" "The printed summary must redact account IDs."
assert_absent "$discovery_output" "90000000-0000-0000-0000-000000000001" "The printed summary must omit principal IDs."
assert_contains "$discovery_output" "ECPortfolioTerraformPlan.account_assignments=USERx1" \
    "The printed summary must show the assignment shape."
for field in raw_sha256 canonical_sha256 statement_count non_whitespace_characters; do
    assert_contains "$discovery_output" "ECPortfolioTerraformApply.inline_policy.$field=" \
        "The printed summary must show the inline policy $field."
done
[[ "$(mode_of "$out_directory")" == "700" ]] || fail "OUT_DIR must be private to the operator."
[[ "$(mode_of "$out_directory/baseline.txt")" == "600" ]] || fail "The baseline must be private to the operator."

# --- 3. conditions that must stop the discovery ------------------------------

jq '.PolicyDocument.Statement[0].Action = ["s3:GetObject", "s3:PutObject"]' \
    "$FIXTURES/iam.get-role-policy.$PLAN_ROLE.json" >"$work_directory/drifted.json"
mv "$work_directory/drifted.json" "$FIXTURES/iam.get-role-policy.$PLAN_ROLE.json"
run_discovery
((discovery_status == 3)) || fail "Provisioning drift must stop the discovery (exit $discovery_status)."
assert_contains "$discovery_output" "does not carry the current ECPortfolioTerraformPlan inline policy" \
    "The drift must be named."
write_fixtures

printf '{"InlinePolicy": ""}\n' >"$FIXTURES/sso-admin.get-inline-policy-for-permission-set.ps-apply.json"
run_discovery
((discovery_status == 3)) || fail "A permission set without an inline policy must stop the discovery."
assert_contains "$discovery_output" "ECPortfolioTerraformApply has no inline policy" "The empty policy must be named."
write_fixtures

printf '{"AccountIds": ["%s", "444455556666"]}\n' "$ACCOUNT_ID" |
    fixture sso-admin.list-accounts-for-provisioned-permission-set.json
run_discovery
((discovery_status == 3)) || fail "Provisioning to another account must stop the discovery."
assert_absent "$discovery_output" "444455556666" "Account IDs must be redacted in the stop message."
write_fixtures

sed -i.bak 's/AccessAdmin_00aa11bb22cc33dd/TerraformPlan_0123456789abcdef/' "$FIXTURES/sts.get-caller-identity.json"
run_discovery
((discovery_status == 3)) || fail "Any caller but the access-admin permission set must be stopped."
assert_contains "$discovery_output" "the caller is not the ECPortfolioAccessAdmin permission set" "The identity must be named."
[[ "$calls" == "sts get-caller-identity"* && "$calls" != *sso-admin* ]] ||
    fail "Nothing but the identity call may run for a wrong caller: $calls"
write_fixtures

printf 'An error occurred (AccessDeniedException) when calling the ListInstances operation: User: arn:aws:sts::%s:assumed-role/X/y is not authorized to perform: sso:ListInstances on resource: arn:aws:sso:::instance/*\n' \
    "$ACCOUNT_ID" | fixture sso-admin.list-instances.err
rm -f "$FIXTURES/sso-admin.list-instances.json"
run_discovery
((discovery_status == 3)) || fail "An AccessDenied must stop the discovery."
assert_contains "$discovery_output" "(AccessDeniedException) when calling the ListInstances operation" \
    "The failed operation must be reported."
assert_contains "$discovery_output" "not authorized to perform: sso:ListInstances" "The denied action must be reported."
assert_absent "$discovery_output" "$ACCOUNT_ID" "The error report must redact account IDs."
[[ "$(grep -c 'list-instances' "$CALLS_LOG")" == "1" ]] || fail "A failed call must never be retried."
write_fixtures

# --- 4. static contract ------------------------------------------------------

discovery_contents="$(cat "$DISCOVERY_SCRIPT")"
for forbidden in "put-inline-policy" "provision-permission-set" "delete-" "create-" "update-" \
    "attach-" "detach-" "--profile"; do
    assert_absent "$discovery_contents" "$forbidden" "discover-permission-sets.sh must not contain: $forbidden"
done

printf '[access-discovery-test] PASS\n'
