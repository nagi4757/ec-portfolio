#!/usr/bin/env bash

# Behaviour tests for the inline policy comparison gate.
#
# Everything runs in a temporary sandbox with synthetic policies and synthetic
# plan JSON. No AWS call is made and no Terraform command is run.

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly GATE_SCRIPT="$SCRIPT_DIRECTORY/policy-gate.sh"

work_directory=""

cleanup_tests() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-policy-gate-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup_tests EXIT

fail() {
    printf '[policy-gate-test] FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    [[ "$1" == *"$2"* ]] || fail "$3 (expected to find: $2)"
}

assert_absent() {
    [[ "$1" != *"$2"* ]] || fail "$3 (unexpectedly found: $2)"
}

# Runs the gate and records its combined output and exit status without letting
# errexit abort the test on the expected failures.
run_gate() {
    gate_status=0
    gate_output="$("$GATE_SCRIPT" "$@" 2>&1)" || gate_status=$?
}

expect_match() {
    run_gate compare "$1" "$2"
    ((gate_status == 0)) || fail "$3 (exit $gate_status): $gate_output"
    assert_contains "$gate_output" "MATCH" "$3"
}

expect_mismatch() {
    run_gate compare "$1" "$2"
    ((gate_status == 1)) || fail "$3 (exit $gate_status): $gate_output"
    assert_contains "$gate_output" "MISMATCH" "$3"
}

work_directory="$(mktemp -d /tmp/ec-portfolio-policy-gate-test.XXXXXX)"
cd "$work_directory"

# The exported policy as the console stores it: pretty-printed, one-element
# lists written as strings, statements in authoring order.
cat >baseline.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StateRead",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket"],
      "Resource": "arn:aws:s3:::example-state"
    },
    {
      "Sid": "DenyInsecure",
      "Effect": "Deny",
      "Action": "s3:*",
      "Resource": ["arn:aws:s3:::example-state", "arn:aws:s3:::example-state/*"],
      "Condition": {"Bool": {"aws:SecureTransport": false}}
    }
  ]
}
JSON

# --- 1. semantically identical renderings match ------------------------------

# How aws_iam_policy_document renders the same policy: keys reordered, lists
# re-sorted, one-element lists kept as lists, condition values as strings,
# statements in a different order, a duplicated action collapsed.
cat >rendered.json <<'JSON'
{"Statement":[{"Condition":{"Bool":{"aws:SecureTransport":["false"]}},"Resource":["arn:aws:s3:::example-state/*","arn:aws:s3:::example-state"],"Action":["s3:*"],"Effect":"Deny","Sid":"DenyInsecure"},{"Resource":["arn:aws:s3:::example-state"],"Effect":"Allow","Sid":"StateRead","Action":["s3:ListBucket","s3:GetObject","s3:GetObject"]}],"Version":"2012-10-17"}
JSON

expect_match baseline.json rendered.json \
    "Key order, list order, list-vs-string, duplicates and bool-vs-string must not count as differences."

run_gate canonical baseline.json
baseline_digest="$gate_output"
run_gate canonical rendered.json
[[ "$gate_output" == "$baseline_digest" && ${#baseline_digest} -eq 64 ]] ||
    fail "Equivalent policies must have the same canonical SHA-256."

# --- 2. every meaning-bearing difference is caught ---------------------------

mutate() {
    jq "$1" baseline.json >mutated.json
}

mutate 'del(.Statement[1])'
expect_mismatch baseline.json mutated.json "A dropped statement must fail the gate."
assert_contains "$gate_output" "missing statement: Effect=Deny Sid=DenyInsecure" \
    "The dropped statement must be named."

mutate '.Statement[0].Action += ["s3:PutObject"]'
expect_mismatch baseline.json mutated.json "An added action must fail the gate."

mutate '.Statement[0].Resource = "arn:aws:s3:::other-state"'
expect_mismatch baseline.json mutated.json "A changed resource must fail the gate."

mutate '.Statement[0].Sid = "StateReadRenamed"'
expect_mismatch baseline.json mutated.json "A changed Sid must fail the gate."

mutate '.Statement[1].Effect = "Allow"'
expect_mismatch baseline.json mutated.json "A changed Effect must fail the gate."

mutate '.Statement[1].Condition.Bool["aws:SecureTransport"] = true'
expect_mismatch baseline.json mutated.json "A changed condition value must fail the gate."

mutate '.Statement[1].Condition = {"BoolIfExists": {"aws:SecureTransport": false}}'
expect_mismatch baseline.json mutated.json "A changed condition operator must fail the gate."

mutate 'del(.Version)'
expect_mismatch baseline.json mutated.json "A missing Version is a different policy language version."
assert_contains "$gate_output" "Version differs" "The Version difference must be named."

mutate '.Statement[0].Action = ["S3:GetObject", "s3:ListBucket"]'
expect_mismatch baseline.json mutated.json "A case change is a change to the reviewed text."

mutate '.Statement += [.Statement[0]]'
expect_mismatch baseline.json mutated.json "A duplicated statement changes the statement multiset."
assert_contains "$gate_output" "statement count differs" "The multiplicity difference must be reported."

# --- 3. unsupported shapes are refused, never ignored ------------------------

mutate '.Statement[0].Principal = {"AWS": "*"}'
run_gate canonical mutated.json
((gate_status != 0)) || fail "An unknown statement key must be refused."
assert_contains "$gate_output" "unsupported statement keys: Principal" "The refused key must be named."

mutate '.Statement[0].Action = [{"not": "a string"}]'
run_gate canonical mutated.json
((gate_status != 0)) || fail "A non-scalar action must be refused."
assert_contains "$gate_output" "unsupported policy value of type object" "The refused value type must be named."

printf '[1, 2]\n' >not-a-policy.json
run_gate canonical not-a-policy.json
((gate_status != 0)) || fail "A document that is not a JSON object must be refused."

run_gate compare baseline.json missing.json
((gate_status != 0)) || fail "A missing policy file must be refused."

# --- 4. import-only plan verification ----------------------------------------

readonly PLAN_ADDRESS="aws_ssoadmin_permission_set_inline_policy.plan"
readonly APPLY_ADDRESS="aws_ssoadmin_permission_set_inline_policy.apply"

cp baseline.json apply-baseline.json

# Builds the JSON form of a plan. $1 is a jq expression applied to the passing
# plan, so each negative case differs from the passing one in exactly one way.
build_plan() {
    jq -n --rawfile plan_policy rendered.json --rawfile apply_policy rendered.json '
        {
          format_version: "1.2",
          errored: false,
          resource_changes: [
            {address: "data.aws_ssoadmin_permission_set.plan", mode: "data",
             change: {actions: ["read"]}},
            {address: "aws_ssoadmin_permission_set_inline_policy.plan", mode: "managed",
             change: {actions: ["no-op"], after: {inline_policy: $plan_policy}, importing: {id: "ps-plan,ins"}}},
            {address: "aws_ssoadmin_permission_set_inline_policy.apply", mode: "managed",
             change: {actions: ["no-op"], after: {inline_policy: $apply_policy}, importing: {id: "ps-apply,ins"}}}
          ]
        }' | jq "$1" >plan.json
}

verify_plan() {
    run_gate verify-import-plan plan.json \
        "$PLAN_ADDRESS=baseline.json" "$APPLY_ADDRESS=apply-baseline.json"
}

build_plan '.'
verify_plan
((gate_status == 0)) || fail "A no-op import of both matching policies must pass (exit $gate_status): $gate_output"
assert_contains "$gate_output" "PASS import-only plan: 2 import(s)" "The passing plan must be reported."

build_plan '.resource_changes[1].change.actions = ["update"]'
verify_plan
((gate_status != 0)) || fail "An in-place update must fail the gate."
assert_contains "$gate_output" "$PLAN_ADDRESS: update" "The mutating address must be named."

build_plan '.resource_changes += [{address: "aws_ssoadmin_permission_set_inline_policy.extra", mode: "managed", change: {actions: ["create"]}}]'
verify_plan
((gate_status != 0)) || fail "An extra managed resource must fail the gate."
assert_contains "$gate_output" "aws_ssoadmin_permission_set_inline_policy.extra: create" \
    "The extra resource must be named."

build_plan 'del(.resource_changes[2].change.importing)'
verify_plan
((gate_status != 0)) || fail "A managed resource that is not imported must fail the gate."
assert_contains "$gate_output" "imported addresses differ" "The missing import must be reported."

jq '.Statement[0].Action += ["s3:PutObject"]' baseline.json >widened.json
build_plan '.'
jq --rawfile widened widened.json \
    '.resource_changes[1].change.after.inline_policy = $widened' plan.json >plan-mismatch.json
mv plan-mismatch.json plan.json
verify_plan
((gate_status != 0)) || fail "A no-op import whose policy differs from the baseline must fail the gate."
assert_contains "$gate_output" "MISMATCH" "The policy difference must be reported."

build_plan '.errored = true'
verify_plan
((gate_status != 0)) || fail "An errored plan must fail the gate."

build_plan 'del(.resource_changes[1].change.after.inline_policy)'
verify_plan
((gate_status != 0)) || fail "A plan without a rendered policy must fail the gate."
assert_contains "$gate_output" "no planned inline_policy for $PLAN_ADDRESS" "The missing policy must be named."

printf '{"resource_changes": []}\n' >plan.json
verify_plan
((gate_status != 0)) || fail "A document that is not a plan must be refused."

# --- 5. static contract ------------------------------------------------------

gate_contents="$(cat "$GATE_SCRIPT")"
for forbidden in "aws " "terraform apply" "terraform import"; do
    assert_absent "$gate_contents" "$forbidden" "policy-gate.sh must not invoke: $forbidden"
done

printf '[policy-gate-test] PASS\n'
