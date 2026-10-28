#!/usr/bin/env bash

# Tests for the Phase 6C-5c cold standby runtime policies.
#
# README.md carries five reviewed documents under "Phase 6C-5c cold standby
# runtime permissions", the customer managed policies an administrator creates
# from it (ECPortfolioTerraformApplyRuntimeOrchestration,
# ECPortfolioTerraformApplyColdStandby, ECPortfolioColdStandbyOperator,
# ECPortfolioColdStandbyRehearsal, ECPortfolioTerraformPlanRuntimeOrchestration).
# This suite reads them from the README, so what it checks is what gets pasted,
# and:
#   - pins the canonical SHA-256 of each (policy-gate.sh canonical) and checks
#     that the README records the same digest next to the block;
#   - runs a shape gate on each: every action bound to its exact resources, the
#     exact conditions where a statement needs one and no condition elsewhere,
#     read-only Plan apart from the definition check the provider makes while
#     it plans, the exact redrive denial, no wildcard, the size limit;
#   - checks that ECPortfolioAccessAdmin's CustomerManagedPolicyRead lists the
#     five policies by exact ARN;
#   - mutates the documents and requires the gate to reject every mutant, so the
#     gate is shown to catch what it claims to.
#
# No AWS call and no Terraform command. Runs under bash 3.2 and bash 5.

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly README="$SCRIPT_DIRECTORY/../README.md"
readonly GATE_SCRIPT="$SCRIPT_DIRECTORY/policy-gate.sh"

# The reviewed digests. A change to a document changes its digest here, in the
# README, and in the console rendering, all in the same review.
readonly APPLY_SHA="326e60d18d480c759f259c330aed3ce83e76d09a57c7c10c9afaabbe17d632f7"
readonly STANDBY_SHA="01f97613658bd6bfefd6ddf605c1dd1766f905f1eeb168ecfa20745c86ee569d"
readonly OPERATOR_SHA="740d96e849a4708c68940e9255e7e53e609db3e120cf5d3c660676b4655938fe"
readonly REHEARSAL_SHA="022e7348539315e7f5f4a886815ac48beb198687712b2a16a5c50117810951ac"
readonly PLAN_SHA="0cddfdab77886feef085f7382ab373ff4812ea2f7553cd37729dba482cfda8fd"

readonly APPLY_HEADING='### `ECPortfolioTerraformApplyRuntimeOrchestration`'
readonly STANDBY_HEADING='### `ECPortfolioTerraformApplyColdStandby`'
readonly OPERATOR_HEADING='### `ECPortfolioColdStandbyOperator`'
readonly REHEARSAL_HEADING='### `ECPortfolioColdStandbyRehearsal`'
readonly PLAN_HEADING='### `ECPortfolioTerraformPlanRuntimeOrchestration`'
readonly ACCESS_ADMIN_HEADING='### `ECPortfolioAccessAdmin` inline policy'

# The shape gate. Input: one policy document. Argument: $kind (apply, standby,
# operator, rehearsal or plan). Output: one line per violation; none means the
# document passes.
readonly SHAPE_GATE='
def as_list: if type == "array" then . else [.] end;
def glob_regex: "^" + (gsub("(?<c>[\\\\.+^$(){}|\\[\\]])"; "\\\(.c)") | gsub("\\*"; ".*") | gsub("\\?"; ".")) + "$";
def matches_glob($pattern): test($pattern | glob_regex; "i");

def region_arn($service; $rest): "arn:aws:\($service):ap-northeast-1:<ACCOUNT_ID>:\($rest)";
def iam_arn($rest): "arn:aws:iam::<ACCOUNT_ID>:\($rest)";

def machines: ["day-open", "ready-check", "day-close", "origin-guard", "od-standby"];
def machine_arns: [machines[] | region_arn("states"; "stateMachine:ec-portfolio-demo-\(.)")];
def execution_arns: [machines[] | region_arn("states"; "execution:ec-portfolio-demo-\(.):*")];
def role_services: {
  (iam_arn("role/ec-portfolio-demo-runtime-orchestrator")): "states.amazonaws.com",
  (iam_arn("role/ec-portfolio-demo-runtime-eip-writer")): "states.amazonaws.com",
  (iam_arn("role/ec-portfolio-demo-runtime-events")): "events.amazonaws.com"
};
def role_arns: role_services | keys;
def table_arn: region_arn("dynamodb"; "table/ec-portfolio-demo-runtime-control");
def rule_arns: [("origin-guard-signals", "spot-capacity-unavailable", "runtime-orchestration-failed")
  | region_arn("events"; "rule/ec-portfolio-demo-\(.)")];
def new_schedule_arns: [("day-open", "ready-check", "day-close", "origin-guard-tick")
  | region_arn("scheduler"; "schedule/ec-portfolio-demo-runtime/ec-portfolio-demo-\(.)")];
def legacy_schedule_arns: [("rds-start", "ec2-start", "ec2-stop", "rds-stop")
  | region_arn("scheduler"; "schedule/ec-portfolio-demo-runtime/ec-portfolio-demo-\(.)")];
def document_arns: [("od-readiness", "spot-smoke") | region_arn("ssm"; "document/ec-portfolio-demo-\(.)")];
def group_arn: region_arn("autoscaling"; "autoScalingGroup:*:autoScalingGroupName/ec-portfolio-demo-ecs-spot");
def standby_instance_arn: region_arn("ec2"; "instance/i-01aab176822e4e38c");
def standby_interface_arn: region_arn("ec2"; "network-interface/eni-082890a259bcbe151");
def database_arn: region_arn("rds"; "db:ec-portfolio-demo-mariadb");

# Every action a document may grant, with the exact resources it may name.
def action_table: {
  apply: (
    ([("states:CreateStateMachine", "states:DescribeStateMachine", "states:UpdateStateMachine",
       "states:DeleteStateMachine", "states:ListStateMachineVersions", "states:TagResource",
       "states:UntagResource", "states:ListTagsForResource", "states:StartExecution", "states:ListExecutions")
      | {key: ., value: machine_arns}] | from_entries)
    + ([("states:DescribeExecution", "states:GetExecutionHistory", "states:StopExecution")
      | {key: ., value: execution_arns}] | from_entries)
    + {"states:ValidateStateMachineDefinition": ["*"]}
    + ([("iam:CreateRole", "iam:GetRole", "iam:UpdateRoleDescription", "iam:UpdateAssumeRolePolicy", "iam:DeleteRole",
         "iam:TagRole", "iam:UntagRole", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
         "iam:ListInstanceProfilesForRole", "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy",
         "iam:PassRole")
      | {key: ., value: role_arns}] | from_entries)
    + ([("dynamodb:CreateTable", "dynamodb:DescribeTable", "dynamodb:UpdateTable", "dynamodb:DeleteTable",
         "dynamodb:DescribeTimeToLive", "dynamodb:UpdateTimeToLive", "dynamodb:DescribeContinuousBackups",
         "dynamodb:TagResource", "dynamodb:UntagResource", "dynamodb:ListTagsOfResource")
      | {key: ., value: [table_arn]}] | from_entries)
    + ([("events:PutRule", "events:DescribeRule", "events:DeleteRule", "events:PutTargets", "events:RemoveTargets",
         "events:ListTargetsByRule", "events:TagResource", "events:UntagResource", "events:ListTagsForResource")
      | {key: ., value: rule_arns}] | from_entries)
    + ([("scheduler:CreateSchedule", "scheduler:GetSchedule", "scheduler:UpdateSchedule", "scheduler:DeleteSchedule")
      | {key: ., value: new_schedule_arns}] | from_entries)),
  standby: (
    ([("ssm:CreateDocument", "ssm:DescribeDocument", "ssm:GetDocument", "ssm:DescribeDocumentPermission",
       "ssm:UpdateDocument", "ssm:UpdateDocumentDefaultVersion", "ssm:DeleteDocument", "ssm:AddTagsToResource",
       "ssm:RemoveTagsFromResource", "ssm:ListTagsForResource")
      | {key: ., value: document_arns}] | from_entries)
    + {"scheduler:GetSchedule": legacy_schedule_arns, "scheduler:UpdateSchedule": legacy_schedule_arns,
       "autoscaling:PutScheduledUpdateGroupAction": [group_arn], "autoscaling:DeleteScheduledAction": [group_arn],
       "autoscaling:DescribeScheduledActions": ["*"]}),
  operator: {
    "ec2:StartInstances": [standby_instance_arn], "ec2:StopInstances": [standby_instance_arn],
    "rds:StartDBInstance": [database_arn], "rds:StopDBInstance": [database_arn],
    "dynamodb:GetItem": [table_arn], "dynamodb:PutItem": [table_arn], "dynamodb:DeleteItem": [table_arn]
  },
  rehearsal: {
    "ec2:ModifyNetworkInterfaceAttribute": [standby_interface_arn, standby_instance_arn],
    "states:TestState": ["*"]
  },
  plan: (
    ([("states:DescribeStateMachine", "states:ListStateMachineVersions", "states:ListTagsForResource",
       "states:ListExecutions")
      | {key: ., value: machine_arns}] | from_entries)
    + {"states:ValidateStateMachineDefinition": ["*"]}
    + {"states:DescribeExecution": execution_arns, "states:GetExecutionHistory": execution_arns}
    + ([("dynamodb:DescribeTable", "dynamodb:DescribeContinuousBackups", "dynamodb:DescribeTimeToLive",
         "dynamodb:ListTagsOfResource", "dynamodb:GetItem")
      | {key: ., value: [table_arn]}] | from_entries)
    + {"iam:ListRolePolicies": role_arns, "iam:ListAttachedRolePolicies": role_arns}
    + ([("events:DescribeRule", "events:ListTargetsByRule", "events:ListTagsForResource")
      | {key: ., value: rule_arns}] | from_entries)
    + ([("ssm:DescribeDocument", "ssm:GetDocument", "ssm:DescribeDocumentPermission", "ssm:ListTagsForResource")
      | {key: ., value: document_arns}] | from_entries)
    + {"autoscaling:DescribeScheduledActions": ["*"]})
};

# The only conditions a statement may carry, keyed by its single action (or, for
# the control table, by its action set). Everything else carries none.
def leading_keys: ["lock#runtime", "maintenance", "mode", "standby-hold"];
def required_condition($kind; $actions; $resources):
  if ($actions == ["iam:PassRole"]) then {StringEquals: {"iam:PassedToService": role_services[$resources[0]]}}
  elif $actions == ["autoscaling:PutScheduledUpdateGroupAction"] then
    {NumericEquals: {"autoscaling:MinSize": "0"}, NumericLessThanEquals: {"autoscaling:MaxSize": "2"}}
  elif $actions == ["ec2:ModifyNetworkInterfaceAttribute"] then
    {StringEquals: {"ec2:Attribute/AssociatePublicIpAddress": ["false", "true"]}}
  elif $kind == "operator" and ($actions | any(startswith("dynamodb:"))) then
    {"ForAllValues:StringEquals": {"dynamodb:LeadingKeys": leading_keys}, Null: {"dynamodb:LeadingKeys": "false"}}
  else null end;

# Order and the one-element-list form carry no meaning in a condition.
def normalized_condition: if . == null then null else with_entries(.value |= with_entries(.value |= (as_list | map(tostring) | sort))) end;

# The one Plan action that is not a read by name: AWS provider 6.62 validates a
# known state machine definition while it plans. It changes nothing.
def plan_definition_check: ["states:ValidateStateMachineDefinition"];

# Actions that must stay sole occupants of their statement, so a condition meant
# for them cannot be widened to another action.
def solitary: ["iam:PassRole", "autoscaling:PutScheduledUpdateGroupAction", "ec2:ModifyNetworkInterfaceAttribute"];

def forbidden_actions: [
  "states:RedriveExecution", "ec2:AssociateAddress", "ec2:DisassociateAddress", "ec2:TerminateInstances",
  "ec2:RunInstances", "ec2:ModifyInstanceAttribute", "ssm:SendCommand", "ssm:StartSession",
  "ssm:ModifyDocumentPermission", "autoscaling:SetDesiredCapacity", "autoscaling:UpdateAutoScalingGroup",
  "rds:ModifyDBInstance", "rds:DeleteDBInstance", "rds:RebootDBInstance", "rds:CreateDBSnapshot",
  "iam:CreatePolicy", "iam:CreatePolicyVersion", "iam:AttachRolePolicy", "iam:PutRolePermissionsBoundary",
  "dynamodb:Scan", "dynamodb:Query", "dynamodb:UpdateItem", "dynamodb:BatchWriteItem"
];

# Resources the wildcard entries above must never reach.
def untouchable_arns: [
  region_arn("autoscaling"; "autoScalingGroup:01234567-89ab-cdef-0123-456789abcdef:autoScalingGroupName/ec-portfolio-demo-ecs-spot-measure"),
  region_arn("states"; "execution:ec-portfolio-demo-day-open-extra:run"),
  region_arn("states"; "execution:ec-portfolio-demo-od-standby2:run"),
  region_arn("states"; "execution:ec-portfolio-demo-refund:run"),
  region_arn("states"; "stateMachine:ec-portfolio-demo-day-open")
];

def size_limit: 6144;
def policy_size: tojson | gsub("<ACCOUNT_ID>"; "x" * 12) | length;

def redrive_deny_violations($kind):
  [.Statement[] | select(.Effect == "Deny")] as $denies
  | if ($kind == "apply" or $kind == "plan") then
      if ($denies | length) != 1 then "expected exactly one Deny statement, found \($denies | length)"
      else $denies[0] as $d
        | (if $d.Sid != "DenyRuntimeExecutionRedrive" then "the Deny statement is not DenyRuntimeExecutionRedrive" else empty end),
          (if ($d.Action | as_list) != ["states:RedriveExecution"] then "the Deny statement denies \($d.Action)" else empty end),
          (if ($d.Resource | as_list | sort) != (execution_arns | sort) then "the redrive Deny does not name exactly the five executions" else empty end),
          (if ($d | keys) != ["Action", "Effect", "Resource", "Sid"] then "the redrive Deny carries \($d | keys | join(","))" else empty end)
      end
    elif ($denies | length) > 0 then "a Deny statement in the \($kind) document"
    else empty end;

def statement_violations($kind):
  . as $s
  | (.Sid // "") as $sid
  | (.Action // [] | as_list) as $actions
  | (.Resource // [] | as_list) as $resources
  | (action_table[$kind]) as $table
  | [
      (if ($sid | test("^[A-Za-z0-9]+$")) | not then "a statement without a valid Sid" else empty end),
      ((($s | keys) - ["Sid", "Effect", "Action", "Resource", "Condition"])
        | if length > 0 then "\($sid): keys \(join(","))" else empty end),
      (if ($actions | length) == 0 or ($resources | length) == 0 then "\($sid): no Action or no Resource" else empty end),
      ($actions[] as $a
        | (if ($a | test("^[a-z0-9-]+:[A-Za-z]+$")) | not then "\($sid): wildcard or malformed action \($a)" else empty end),
          (forbidden_actions[] as $f | if ($f | matches_glob($a)) then "\($sid): forbidden action \($f) (as \($a))" else empty end),
          (if ($table[$a] // null) == null then "\($sid): \($a) is not granted in the \($kind) document"
           else ($resources - $table[$a]) as $extra
             | if ($extra | length) > 0 then "\($sid): \($a) on \($extra | join(","))" else empty end end),
          (if $kind == "plan" and (($a | test(":(Describe|List|Get)[A-Za-z]*$")) | not)
              and (plan_definition_check | index($a) | not)
           then "\($sid): non-read action \($a) in the Plan document" else empty end)),
      (if ($actions | map(select(. as $a | solitary | index($a))) | length) > 0 and (($actions | length) != 1 or ($resources | length) != 1 and $actions != ["ec2:ModifyNetworkInterfaceAttribute"])
       then "\($sid): \($actions | join(",")) must stand alone on one resource" else empty end),
      (required_condition($kind; $actions; $resources) as $want
        | ($s.Condition // null | normalized_condition) as $got
        | if ($want | normalized_condition) != $got then "\($sid): condition \($s.Condition // "none") (want \($want // "none"))" else empty end)
    ]
  | .[];

# The coverage a document must keep: each listed action names every resource of
# its family, so a state machine, a role or an execution cannot drop out of one.
def coverage($kind):
  {
    apply: {"states:CreateStateMachine": machine_arns, "states:StartExecution": machine_arns,
            "states:StopExecution": execution_arns, "iam:CreateRole": role_arns, "iam:PassRole": role_arns,
            "events:PutRule": rule_arns, "scheduler:CreateSchedule": new_schedule_arns},
    standby: {"ssm:CreateDocument": document_arns, "scheduler:UpdateSchedule": legacy_schedule_arns},
    operator: {"ec2:StopInstances": [standby_instance_arn], "rds:StopDBInstance": [database_arn]},
    rehearsal: {"ec2:ModifyNetworkInterfaceAttribute": [standby_interface_arn]},
    plan: {"states:DescribeStateMachine": machine_arns, "states:DescribeExecution": execution_arns,
           "iam:ListRolePolicies": role_arns, "events:DescribeRule": rule_arns, "ssm:GetDocument": document_arns}
  }[$kind];

def coverage_violations($kind):
  . as $doc
  | coverage($kind) | to_entries[]
  | .key as $a | .value as $want
  | ([$doc.Statement[] | select(.Effect == "Allow") | select(.Action | as_list | index($a)) | .Resource | as_list[]] | unique) as $got
  | ($want - $got) | if length > 0 then "\($a) does not cover \(join(","))" else empty end;

def allowlist_violations:
  [action_table[][][]] | unique | map(select(test("[*?]") and . != "*"))[] as $entry
  | untouchable_arns[] as $u
  | if ($u | matches_glob($entry)) and ($u | test("execution:ec-portfolio-demo-(day-open|ready-check|day-close|origin-guard|od-standby):") | not)
    then "allowlist entry \($entry) matches \($u)" else empty end;

def policy_violations($kind):
  [
    (if .Version != "2012-10-17" then "Version" else empty end),
    ((keys - ["Version", "Statement"]) | if length > 0 then "unknown policy keys \(join(","))" else empty end),
    (tojson | [scan("<[A-Z_]+>")] | unique - ["<ACCOUNT_ID>"] | if length > 0 then "unknown placeholder \(join(","))" else empty end),
    (policy_size as $size | if $size > size_limit then "size \($size) > \(size_limit)" else empty end),
    ([.Statement[].Sid] | if length != (unique | length) then "duplicate Sid" else empty end),
    redrive_deny_violations($kind),
    (.Statement[] | select(.Effect != "Deny") | if .Effect != "Allow" then "\(.Sid): Effect \(.Effect)" else statement_violations($kind) end),
    coverage_violations($kind),
    allowlist_violations
  ]
  | .[];

policy_violations($kind)
'

# The AccessAdmin read list: exactly the five new ARNs among the references, no
# pattern, no duplicate. Input: the AccessAdmin inline policy. Output: violations.
readonly ACCESS_ADMIN_GATE='
def new_policies: ["ECPortfolioTerraformPlanRuntimeOrchestration", "ECPortfolioTerraformApplyRuntimeOrchestration",
  "ECPortfolioTerraformApplyColdStandby", "ECPortfolioColdStandbyOperator", "ECPortfolioColdStandbyRehearsal"];
[.Statement[] | select(.Sid == "CustomerManagedPolicyRead")] as $s
| if ($s | length) != 1 then "CustomerManagedPolicyRead appears \($s | length) times"
  else ($s[0].Resource | if type == "array" then . else [.] end) as $r
    | (new_policies[] as $p | if ($r | index("arn:aws:iam::<ACCOUNT_ID>:policy/\($p)")) == null then "missing \($p)" else empty end),
      ($r[] | select(test("[*?]")) | "pattern \(.)"),
      (if ($r | length) != ($r | unique | length) then "duplicate ARN" else empty end),
      (if ($r | length) != 25 then "expected 25 ARNs, found \($r | length)" else empty end)
  end
'

work_directory=""

cleanup_tests() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-cold-standby-policy-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup_tests EXIT

fail() {
    printf '[cold-standby-policy-test] FAIL: %s\n' "$*" >&2
    exit 1
}

# extract_block <readme> <heading> <output>: the first ```json block after the
# heading, which must appear exactly once. Fails rather than returning nothing.
extract_block() {
    local readme="$1" heading="$2" output="$3" count
    count="$(awk -v heading="$heading" '$0 == heading { n++ } END { print n + 0 }' "$readme")"
    [[ "$count" == 1 ]] || fail "expected the heading exactly once, found $count: $heading"
    awk -v heading="$heading" '
        $0 == heading { found = 1; next }
        found && !inside && /^#/ { exit }
        found && !inside && $0 == "```json" { inside = 1; next }
        inside && $0 == "```" { exit }
        inside { print }
    ' "$readme" >"$output"
    [[ -s "$output" ]] || fail "no JSON block under: $heading"
    jq -e 'type == "object"' "$output" >/dev/null || fail "the block under '$heading' is not a JSON object"
}

# recorded_digest <heading>: the first digest in backticks between the heading's
# JSON block and the next heading.
recorded_digest() {
    awk -v heading="$1" '
        $0 == heading { found = 1; next }
        found && !after && $0 == "```json" { inside = 1; next }
        inside && $0 == "```" { inside = 0; after = 1; next }
        after && /^#/ { exit }
        after { print }
    ' "$README" | grep -Eo '`[0-9a-f]{64}`' | head -n 1 | tr -d '`'
}

# run_gate <kind> <policy.json>: sets gate_output to the violations, one per line.
run_gate() {
    gate_output="$(jq -r --arg kind "$1" "$SHAPE_GATE" "$2")" ||
        fail "the shape gate could not evaluate $2"
}

work_directory="$(mktemp -d /tmp/ec-portfolio-cold-standby-policy-test.XXXXXX)"

kinds=(apply standby operator rehearsal plan)
headings=("$APPLY_HEADING" "$STANDBY_HEADING" "$OPERATOR_HEADING" "$REHEARSAL_HEADING" "$PLAN_HEADING")
digests=("$APPLY_SHA" "$STANDBY_SHA" "$OPERATOR_SHA" "$REHEARSAL_SHA" "$PLAN_SHA")

# --- 1. the documents as written: pinned digests and a clean shape gate -------

for index in 0 1 2 3 4; do
    kind="${kinds[$index]}"
    document="$work_directory/$kind.json"
    extract_block "$README" "${headings[$index]}" "$document"

    actual="$("$GATE_SCRIPT" canonical "$document")"
    [[ "$actual" == "${digests[$index]}" ]] ||
        fail "$kind: canonical SHA-256 $actual differs from the reviewed ${digests[$index]}"
    [[ "$(recorded_digest "${headings[$index]}")" == "${digests[$index]}" ]] ||
        fail "$kind: the README does not record the canonical SHA-256 next to the block"

    run_gate "$kind" "$document"
    [[ -z "$gate_output" ]] || fail "$kind: the reviewed document fails the shape gate:
$gate_output"
done

# The gate must see every statement: a positive control that is not empty.
run_gate apply <(jq '.Statement += [{"Sid": "Probe", "Effect": "Allow", "Action": "ec2:RunInstances", "Resource": "*"}]' \
    "$work_directory/apply.json")
[[ "$gate_output" == *"forbidden action ec2:RunInstances"* ]] || fail "the shape gate ignored an added statement"

# The AccessAdmin read list.
extract_block "$README" "$ACCESS_ADMIN_HEADING" "$work_directory/access-admin.json"
access_admin_output="$(jq -r "$ACCESS_ADMIN_GATE" "$work_directory/access-admin.json")" ||
    fail "the AccessAdmin gate could not evaluate the document"
[[ -z "$access_admin_output" ]] || fail "ECPortfolioAccessAdmin CustomerManagedPolicyRead:
$access_admin_output"

# --- 2. every mutant must fail the shape gate ---------------------------------

mutants=0

# expect_rejected <kind> <name> <jq filter applied to the document>
expect_rejected() {
    local kind="$1" name="$2" filter="$3" mutated="$work_directory/mutant.json"
    jq "def st(\$sid): .Statement[] | select(.Sid == \$sid); $filter" "$work_directory/$kind.json" >"$mutated" ||
        fail "mutant '$name' could not be built"
    if cmp -s "$mutated" <(jq . "$work_directory/$kind.json"); then
        fail "mutant '$name' did not change the document"
    fi
    run_gate "$kind" "$mutated"
    [[ -n "$gate_output" ]] || fail "mutant survived: $kind: $name"
    mutants=$((mutants + 1))
}

ACCOUNT_REGION='arn:aws:states:ap-northeast-1:<ACCOUNT_ID>'

expect_rejected apply "redrive allowed instead of denied" 'st("DenyRuntimeExecutionRedrive").Effect = "Allow"'
expect_rejected apply "redrive Deny without od-standby" \
    'st("DenyRuntimeExecutionRedrive").Resource |= map(select(test("od-standby") | not))'
expect_rejected apply "redrive Deny with a condition" \
    'st("DenyRuntimeExecutionRedrive").Condition = {"StringEquals": {"aws:RequestedRegion": "ap-northeast-1"}}'
expect_rejected apply "redrive Deny removed" 'del(.Statement[] | select(.Sid == "DenyRuntimeExecutionRedrive"))'
expect_rejected apply "RedriveExecution granted" \
    "st(\"ObserveRuntimeStateMachineExecutions\").Action += [\"states:RedriveExecution\"]"
expect_rejected apply "state machines by pattern" \
    "st(\"ManageExactRuntimeStateMachines\").Resource = \"$ACCOUNT_REGION:stateMachine:ec-portfolio-demo-*\""
expect_rejected apply "od-standby dropped from the managed state machines" \
    'st("ManageExactRuntimeStateMachines").Resource |= map(select(test("od-standby") | not))'
expect_rejected apply "od-standby dropped from the rehearsals" \
    'st("StartRuntimeStateMachineRehearsals").Resource |= map(select(test("od-standby") | not))'
expect_rejected apply "another state machine" \
    "st(\"StartRuntimeStateMachineRehearsals\").Resource += [\"$ACCOUNT_REGION:stateMachine:ec-portfolio-demo-refund\"]"
expect_rejected apply "CreateStateMachine on *" 'st("ValidateStateMachineDefinitions").Action = ["states:CreateStateMachine"]'
expect_rejected apply "the scheduler role among the runtime roles" \
    'st("ManageExactRuntimeRoles").Resource += ["arn:aws:iam::<ACCOUNT_ID>:role/ec-portfolio-demo-scheduler"]'
expect_rejected apply "roles by pattern" \
    'st("ManageExactRuntimeRoles").Resource = "arn:aws:iam::<ACCOUNT_ID>:role/ec-portfolio-demo-runtime-*"'
expect_rejected apply "EIP writer PassRole dropped" 'del(.Statement[] | select(.Sid == "PassRuntimeEipWriterRoleToStepFunctions"))'
expect_rejected apply "PassRole without its condition" 'st("PassRuntimeEipWriterRoleToStepFunctions") |= del(.Condition)'
expect_rejected apply "events role passed to Step Functions" \
    'st("PassRuntimeEventsRoleToEventBridge").Condition.StringEquals["iam:PassedToService"] = "states.amazonaws.com"'
expect_rejected apply "PassRole on the EC2 host role" \
    'st("PassRuntimeOrchestratorRoleToStepFunctions").Resource = "arn:aws:iam::<ACCOUNT_ID>:role/ec-portfolio-demo-ec2"'
expect_rejected apply "PassRole on two roles" \
    'st("PassRuntimeOrchestratorRoleToStepFunctions").Resource = ["arn:aws:iam::<ACCOUNT_ID>:role/ec-portfolio-demo-runtime-orchestrator", "arn:aws:iam::<ACCOUNT_ID>:role/ec-portfolio-demo-runtime-eip-writer"]'
expect_rejected apply "table by pattern" \
    'st("ManageExactRuntimeControlTable").Resource = "arn:aws:dynamodb:ap-northeast-1:<ACCOUNT_ID>:table/*"'
expect_rejected apply "table item writes" 'st("ManageExactRuntimeControlTable").Action += ["dynamodb:PutItem"]'
expect_rejected apply "a fourth rule" \
    'st("ManageExactRuntimeRules").Resource += ["arn:aws:events:ap-northeast-1:<ACCOUNT_ID>:rule/ec-portfolio-demo-other"]'
expect_rejected apply "DeleteSchedule on the existing schedules" \
    'st("ManageExactRuntimeSchedules").Resource += ["arn:aws:scheduler:ap-northeast-1:<ACCOUNT_ID>:schedule/ec-portfolio-demo-runtime/ec-portfolio-demo-ec2-start"]'
expect_rejected apply "service wildcard" 'st("ManageExactRuntimeRules").Action = ["events:*"]'
expect_rejected apply "AssociateAddress added" \
    '.Statement += [{"Sid": "X", "Effect": "Allow", "Action": "ec2:AssociateAddress", "Resource": "*"}]'
expect_rejected apply "Allow with NotAction" \
    '.Statement += [{"Sid": "N", "Effect": "Allow", "NotAction": "iam:*", "Resource": "*"}]'
expect_rejected apply "a condition with IfExists" \
    'st("ManageExactRuntimeControlTable").Condition = {"StringEqualsIfExists": {"aws:RequestedRegion": "ap-northeast-1"}}'
expect_rejected apply "an unknown placeholder" \
    'st("ManageExactRuntimeControlTable").Resource = "arn:aws:dynamodb:ap-northeast-1:<OTHER_ACCOUNT>:table/ec-portfolio-demo-runtime-control"'
expect_rejected apply "over the managed policy size limit" \
    '.Statement += [range(0; 12) as $i | {"Sid": "Pad\($i)", "Effect": "Allow", "Action": "dynamodb:DescribeTable", "Resource": "arn:aws:dynamodb:ap-northeast-1:<ACCOUNT_ID>:table/ec-portfolio-demo-runtime-control"}]'
expect_rejected apply "duplicate Sid" '.Statement += [.Statement[0]]'
expect_rejected apply "a Principal key" 'st("ManageExactRuntimeRules").Principal = "*"'

expect_rejected standby "document sharing" 'st("ManageExactRuntimeCommandDocuments").Action += ["ssm:ModifyDocumentPermission"]'
expect_rejected standby "SendCommand added" 'st("ManageExactRuntimeCommandDocuments").Action += ["ssm:SendCommand"]'
expect_rejected standby "documents by pattern" \
    'st("ManageExactRuntimeCommandDocuments").Resource = "arn:aws:ssm:ap-northeast-1:<ACCOUNT_ID>:document/*"'
expect_rejected standby "the AWS-owned shell document" \
    'st("ManageExactRuntimeCommandDocuments").Resource += ["arn:aws:ssm:ap-northeast-1::document/AWS-RunShellScript"]'
expect_rejected standby "DeleteSchedule on the existing schedules" 'st("ChangeExactLegacyRuntimeSchedules").Action += ["scheduler:DeleteSchedule"]'
expect_rejected standby "existing schedules by pattern" \
    'st("ChangeExactLegacyRuntimeSchedules").Resource = "arn:aws:scheduler:ap-northeast-1:<ACCOUNT_ID>:schedule/ec-portfolio-demo-runtime/*"'
expect_rejected standby "an existing schedule dropped" \
    'st("ChangeExactLegacyRuntimeSchedules").Resource |= map(select(test("ec2-start") | not))'
expect_rejected standby "backstop without its size conditions" 'st("PutProductionGroupBackstop") |= del(.Condition)'
expect_rejected standby "backstop maximum widened" \
    'st("PutProductionGroupBackstop").Condition.NumericLessThanEquals["autoscaling:MaxSize"] = "10"'
expect_rejected standby "backstop minimum free" \
    'st("PutProductionGroupBackstop").Condition = {"NumericLessThanEquals": {"autoscaling:MaxSize": "2"}}'
expect_rejected standby "backstop on the measurement group" \
    'st("PutProductionGroupBackstop").Resource = "arn:aws:autoscaling:ap-northeast-1:<ACCOUNT_ID>:autoScalingGroup:*:autoScalingGroupName/ec-portfolio-demo-ecs-spot-measure"'
expect_rejected standby "backstop on any group" \
    'st("PutProductionGroupBackstop").Resource = "arn:aws:autoscaling:ap-northeast-1:<ACCOUNT_ID>:autoScalingGroup:*:autoScalingGroupName/*"'
expect_rejected standby "backstop condition widened to delete" \
    'st("PutProductionGroupBackstop").Action = ["autoscaling:PutScheduledUpdateGroupAction", "autoscaling:DeleteScheduledAction"]'
expect_rejected standby "SetDesiredCapacity added" 'st("DeleteProductionGroupScheduledAction").Action = ["autoscaling:SetDesiredCapacity"]'
expect_rejected standby "a Deny statement" \
    '.Statement += [{"Sid": "D", "Effect": "Deny", "Action": "ssm:DeleteDocument", "Resource": "*"}]'

expect_rejected operator "any instance" \
    'st("StartStopExactOnDemandStandby").Resource = "arn:aws:ec2:ap-northeast-1:<ACCOUNT_ID>:instance/*"'
expect_rejected operator "TerminateInstances added" 'st("StartStopExactOnDemandStandby").Action += ["ec2:TerminateInstances"]'
expect_rejected operator "ModifyDBInstance added" 'st("StartStopExactDemoDatabase").Action += ["rds:ModifyDBInstance"]'
expect_rejected operator "any database" \
    'st("StartStopExactDemoDatabase").Resource = "arn:aws:rds:ap-northeast-1:<ACCOUNT_ID>:db:*"'
expect_rejected operator "control items without leading keys" 'st("OperateExactRuntimeControlItems") |= del(.Condition)'
expect_rejected operator "control items: run records too" \
    'st("OperateExactRuntimeControlItems").Condition["ForAllValues:StringEquals"]["dynamodb:LeadingKeys"] += ["run#*"]'
expect_rejected operator "control items: vacuous ForAllValues" 'st("OperateExactRuntimeControlItems").Condition |= del(.Null)'
expect_rejected operator "control items: UpdateItem" 'st("OperateExactRuntimeControlItems").Action += ["dynamodb:UpdateItem"]'
expect_rejected operator "AssociateAddress added" \
    '.Statement += [{"Sid": "E", "Effect": "Allow", "Action": "ec2:AssociateAddress", "Resource": "arn:aws:ec2:ap-northeast-1:<ACCOUNT_ID>:instance/i-01aab176822e4e38c"}]'
expect_rejected operator "a condition on the instance statement" \
    'st("StartStopExactOnDemandStandby").Condition = {"StringEquals": {"aws:RequestedRegion": "ap-northeast-1"}}'

expect_rejected rehearsal "interface attribute without its condition" 'st("ToggleOnDemandPublicIpv4Assignment") |= del(.Condition)'
expect_rejected rehearsal "source/destination check instead" \
    'st("ToggleOnDemandPublicIpv4Assignment").Condition = {"StringEquals": {"ec2:Attribute/SourceDestCheck": ["true", "false"]}}'
expect_rejected rehearsal "any attribute through ec2:Attribute" \
    'st("ToggleOnDemandPublicIpv4Assignment").Condition = {"StringLike": {"ec2:Attribute": "*"}}'
expect_rejected rehearsal "any interface" \
    'st("ToggleOnDemandPublicIpv4Assignment").Resource = "arn:aws:ec2:ap-northeast-1:<ACCOUNT_ID>:network-interface/*"'
expect_rejected rehearsal "a security group among the resources" \
    'st("ToggleOnDemandPublicIpv4Assignment").Resource += ["arn:aws:ec2:ap-northeast-1:<ACCOUNT_ID>:security-group/*"]'
expect_rejected rehearsal "ModifyInstanceAttribute added" 'st("ToggleOnDemandPublicIpv4Assignment").Action = ["ec2:ModifyNetworkInterfaceAttribute", "ec2:ModifyInstanceAttribute"]'
expect_rejected rehearsal "StartExecution through the rehearsal" 'st("TestRuntimeStates").Action = ["states:TestState", "states:StartExecution"]'

expect_rejected plan "a write action" 'st("ReadExactRuntimeStateMachines").Action += ["states:StartExecution"]'
expect_rejected plan "control item writes" 'st("ReadExactRuntimeControlTable").Action += ["dynamodb:PutItem"]'
expect_rejected plan "redrive Deny removed" 'del(.Statement[] | select(.Sid == "DenyRuntimeExecutionRedrive"))'
expect_rejected plan "document update" 'st("ReadExactRuntimeCommandDocuments").Action += ["ssm:UpdateDocument"]'
expect_rejected plan "PassRole in the Plan document" \
    '.Statement += [{"Sid": "P", "Effect": "Allow", "Action": "iam:PassRole", "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/ec-portfolio-demo-runtime-orchestrator", "Condition": {"StringEquals": {"iam:PassedToService": "states.amazonaws.com"}}}]'
expect_rejected plan "executions of od-standby not readable" \
    'st("ReadExactRuntimeExecutions").Resource |= map(select(test("od-standby") | not))'
expect_rejected plan "the EIP writer role unread" \
    'st("ReadExactRuntimeRolePolicies").Resource |= map(select(test("eip-writer") | not))'
expect_rejected plan "CreateStateMachine on * instead of the definition check" \
    'st("ValidateStateMachineDefinitions").Action = "states:CreateStateMachine"'
expect_rejected plan "a write action next to the definition check" \
    'st("ValidateStateMachineDefinitions").Action = ["states:ValidateStateMachineDefinition", "states:UpdateStateMachine"]'
expect_rejected plan "TestState on * in the Plan document" \
    'st("ValidateStateMachineDefinitions").Action = "states:TestState"'
expect_rejected plan "the definition check widened to all of Step Functions" \
    'st("ValidateStateMachineDefinitions").Action = "states:*"'
expect_rejected plan "the definition check with a pattern action" \
    'st("ValidateStateMachineDefinitions").Action = "states:Validate*"'
expect_rejected plan "the definition check on a state machine role" \
    'st("ValidateStateMachineDefinitions").Resource = "arn:aws:iam::<ACCOUNT_ID>:role/ec-portfolio-demo-runtime-orchestrator"'

# The AccessAdmin gate rejects a missing, widened or duplicated reference.
access_admin_rejects() {
    local name="$1" filter="$2" output
    output="$(jq "$filter" "$work_directory/access-admin.json" | jq -r "$ACCESS_ADMIN_GATE")" ||
        fail "the AccessAdmin mutant '$name' could not be evaluated"
    [[ -n "$output" ]] || fail "AccessAdmin mutant survived: $name"
    mutants=$((mutants + 1))
}
access_admin_rejects "rehearsal policy unread" \
    '(.Statement[] | select(.Sid == "CustomerManagedPolicyRead") | .Resource) |= map(select(test("Rehearsal") | not))'
access_admin_rejects "a policy pattern" \
    '(.Statement[] | select(.Sid == "CustomerManagedPolicyRead") | .Resource) += ["arn:aws:iam::<ACCOUNT_ID>:policy/ECPortfolio*"]'
access_admin_rejects "a duplicate reference" \
    '(.Statement[] | select(.Sid == "CustomerManagedPolicyRead") | .Resource) += ["arn:aws:iam::<ACCOUNT_ID>:policy/ECPortfolioColdStandbyOperator"]'

# --- 3. the extraction itself fails closed ------------------------------------

: >"$work_directory/empty.md"
missing="$( (extract_block "$work_directory/empty.md" "$APPLY_HEADING" "$work_directory/none.json") 2>&1 || true)"
[[ "$missing" == *"expected the heading exactly once, found 0"* ]] ||
    fail "a README without the section must fail the extraction: $missing"

printf '[cold-standby-policy-test] PASS (5 documents pinned and gated, AccessAdmin read list checked, %d mutants rejected)\n' "$mutants"
