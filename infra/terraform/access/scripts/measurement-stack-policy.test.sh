#!/usr/bin/env bash

# Tests for the Phase 6C-5c measurement stack policies.
#
# README.md carries four reviewed documents under "Phase 6C-5c measurement stack
# permissions": the customer managed policies an administrator creates from it
# (ECPortfolioTerraformApplyMeasurementStack, ECPortfolioTerraformPlanMeasurementStack)
# and the runtime role policies the Demo root writes (measurement-host,
# measurement-task-execution). This suite reads them from the README, so what it
# checks is what gets pasted, and:
#   - pins the canonical SHA-256 of each (policy-gate.sh canonical) and checks
#     that the README records the same digest next to the block;
#   - runs a shape gate on each, the invariants any later edit has to keep;
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
readonly APPLY_SHA="7e318370f0e838b2e7a05b85f158660659ad45179a6a79a94679f823174ebfeb"
readonly PLAN_SHA="cb0302816f61d73a7913dc3814bc9aad07290e13f2a72284a70584958ce0378f"
readonly HOST_SHA="bf82e6b8aa0d156809364451464339e3d59d7db9a7ec1b206fd4e282df972c35"
readonly EXEC_SHA="cd6ba5bf479ba3547ca7c186133cdf768874b792660300d3ab5d7ef63cedfb44"

readonly APPLY_HEADING='### `ECPortfolioTerraformApplyMeasurementStack`'
readonly PLAN_HEADING='### `ECPortfolioTerraformPlanMeasurementStack`'
readonly HOST_HEADING='#### Host role `ec-portfolio-demo-ecs-spot-measure`: `measurement-host`'
readonly EXEC_HEADING='#### Task execution role `ec-portfolio-demo-ecs-task-execution-measure`: `measurement-task-execution`'

# The shape gate. Input: one policy document. Arguments: $kind (apply, plan,
# host or exec). Output: one line per violation; none means the document passes.
#
# Resources are matched exactly against a fixed list. "*" and "?" in that list
# are IAM wildcards, so the list itself is checked against production ARNs by
# turning each entry into an anchored regular expression: an entry that would
# reach a production resource is caught however it is written.
readonly SHAPE_GATE='
def as_list: if type == "array" then . else [.] end;
def glob_regex: "^" + (gsub("(?<c>[\\\\.+^$(){}|\\[\\]])"; "\\\(.c)") | gsub("\\*"; ".*") | gsub("\\?"; ".")) + "$";
def matches_glob($pattern): test($pattern | glob_regex; "i");

def region_arn($service; $rest): "arn:aws:\($service):ap-northeast-1:<ACCOUNT_ID>:\($rest)";
def iam_arn($rest): "arn:aws:iam::<ACCOUNT_ID>:\($rest)";

def measurement_name: "ec-portfolio-demo-ecs-spot-measure";
def measurement_cluster_arn: region_arn("ecs"; "cluster/ec-portfolio-demo-measure");
def launch_template_arn: region_arn("ec2"; "launch-template/*");

# Every resource a measurement document may name, other than "*" and the launch
# template pattern.
def measurement_resources: [
  measurement_cluster_arn,
  region_arn("ecs"; "service/ec-portfolio-demo-measure/ec-portfolio-demo-api-measure"),
  region_arn("ecs"; "task-definition/ec-portfolio-demo-api-measure:*"),
  region_arn("ecs"; "container-instance/ec-portfolio-demo-measure/*"),
  region_arn("ecs"; "task/ec-portfolio-demo-measure/*"),
  region_arn("logs"; "log-group:/ec-portfolio/demo/ecs/measure"),
  region_arn("logs"; "log-group:/ec-portfolio/demo/ecs/measure:*"),
  region_arn("logs"; "log-group:/ec-portfolio/demo/ecs/measure:log-stream:*"),
  iam_arn("role/ec-portfolio-demo-ecs-spot-measure"),
  iam_arn("role/ec-portfolio-demo-ecs-task-execution-measure"),
  iam_arn("instance-profile/ec-portfolio-demo-ecs-spot-measure"),
  region_arn("autoscaling"; "autoScalingGroup:*:autoScalingGroupName/ec-portfolio-demo-ecs-spot-measure")
];

# Production resources the runtime roles read, exactly as the production roles do.
def shared_reads: [
  region_arn("ecr"; "repository/ec-portfolio-demo-api"),
  "arn:aws:s3:::<RUNTIME_ARTIFACTS_BUCKET>/runtime/spot-runtime.tar.gz",
  "arn:aws:s3:::<ORIGIN_TLS_BUCKET>/origin-tls/letsencrypt.tar.gz",
  region_arn("ssm"; "parameter/ec-portfolio/demo/origin/verify-token"),
  region_arn("ssm"; "parameter/ec-portfolio/demo/db/master-password"),
  region_arn("ssm"; "parameter/ec-portfolio/demo/app/auth-jwt-secret")
];

# No entry of measurement_resources may match any of these. The launch templates
# are absent on purpose: their IDs carry no name, so they are scoped by tag.
def production_arns: [
  region_arn("ecs"; "cluster/ec-portfolio-demo"),
  region_arn("ecs"; "service/ec-portfolio-demo/ec-portfolio-demo-api"),
  region_arn("ecs"; "task-definition/ec-portfolio-demo-api:42"),
  region_arn("ecs"; "container-instance/ec-portfolio-demo/0123456789abcdef0123456789abcdef"),
  region_arn("ecs"; "task/ec-portfolio-demo/0123456789abcdef0123456789abcdef"),
  region_arn("ecs"; "capacity-provider/ec-portfolio-demo-ecs-spot"),
  iam_arn("role/ec-portfolio-demo-ecs-spot"),
  iam_arn("role/ec-portfolio-demo-ecs-task-execution"),
  iam_arn("role/ec-portfolio-demo-ec2"),
  iam_arn("role/ec-portfolio-demo-scheduler"),
  iam_arn("instance-profile/ec-portfolio-demo-ecs-spot"),
  iam_arn("instance-profile/ec-portfolio-demo-ec2"),
  region_arn("autoscaling"; "autoScalingGroup:01234567-89ab-cdef-0123-456789abcdef:autoScalingGroupName/ec-portfolio-demo-ecs-spot"),
  region_arn("logs"; "log-group:/ec-portfolio/demo/ecs/api"),
  region_arn("logs"; "log-group:/ec-portfolio/demo/ecs/api:*"),
  region_arn("logs"; "log-group:/ec-portfolio/demo/ecs/api:log-stream:api/api/0123456789abcdef"),
  region_arn("ec2"; "elastic-ip/eipalloc-0123456789abcdef0"),
  region_arn("ec2"; "instance/i-0123456789abcdef0"),
  region_arn("ssm"; "parameter/ec-portfolio/demo/deploy/desired-image-sha")
];

def forbidden_actions: [
  "ec2:AssociateAddress", "ec2:DisassociateAddress", "ec2:AllocateAddress", "ec2:ReleaseAddress",
  "ec2:DescribeAddresses", "ec2:RunInstances", "ec2:TerminateInstances", "ec2:CreateTags", "ec2:DeleteTags",
  "ec2:ModifyInstanceCreditSpecification", "ec2:AssociateIamInstanceProfile",
  "ec2:ReplaceIamInstanceProfileAssociation",
  "iam:CreatePolicy", "iam:CreatePolicyVersion", "iam:SetDefaultPolicyVersion", "iam:AttachRolePolicy",
  "iam:DetachRolePolicy", "iam:PutRolePermissionsBoundary", "iam:DeleteRolePermissionsBoundary",
  "iam:UpdateAssumeRolePolicy", "iam:CreateServiceLinkedRole", "iam:CreateUser", "iam:CreateAccessKey",
  "sts:AssumeRole", "route53:ChangeResourceRecordSets", "route53:ListHostedZones",
  "ssm:SendCommand", "ssm:StartSession", "ssm:UpdateInstanceInformation", "ssm:PutParameter",
  "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
  "ecs:ExecuteCommand", "ecs:RunTask", "ecs:StartTask", "ecs:UpdateCluster", "ecs:CreateCapacityProvider",
  "ecs:UpdateCapacityProvider", "ecs:DeleteCapacityProvider", "ecs:PutClusterCapacityProviders",
  "s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:PutBucketPolicy",
  "autoscaling:SetDesiredCapacity", "autoscaling:AttachInstances", "autoscaling:SetInstanceProtection",
  "autoscaling:RecordLifecycleActionHeartbeat", "kms:Decrypt", "kms:CreateGrant",
  "cloudfront:UpdateDistribution"
];

def star_allowed: {
  apply: ["autoscaling:DescribeScheduledActions"],
  plan: ["ecs:ListTasks", "autoscaling:DescribeScheduledActions", "autoscaling:DescribeScalingActivities",
         "autoscaling:DescribeAutoScalingInstances"],
  host: ["ecs:DiscoverPollEndpoint", "ecr:GetAuthorizationToken"],
  exec: ["ecr:GetAuthorizationToken"]
};

def pass_role_targets: {
  (iam_arn("role/ec-portfolio-demo-ecs-spot-measure")): "ec2.amazonaws.com",
  (iam_arn("role/ec-portfolio-demo-ecs-task-execution-measure")): "ecs-tasks.amazonaws.com"
};

def placeholders: {
  apply: {"<ACCOUNT_ID>": 12},
  plan: {"<ACCOUNT_ID>": 12},
  host: {"<ACCOUNT_ID>": 12, "<RUNTIME_ARTIFACTS_BUCKET>": 63, "<ORIGIN_TLS_BUCKET>": 63},
  exec: {"<ACCOUNT_ID>": 12}
};

def size_limit: {apply: 6144, plan: 6144, host: 10240, exec: 10240};

# Non-whitespace characters, as IAM counts them, with each placeholder at the
# longest value it can stand for.
def policy_size($kind):
  reduce (placeholders[$kind] | to_entries[]) as $p
    (tojson; gsub($p.key; "x" * $p.value))
  | length;

def statement_violations($kind):
  . as $s
  | (.Sid // "") as $sid
  | (.Action // [] | as_list) as $actions
  | (.Resource // [] | as_list) as $resources
  | (.Condition // {}) as $condition
  | [
      (if ($sid | test("^[A-Za-z0-9]+$")) | not then "a statement without a valid Sid" else empty end),
      (if $s.Effect != "Allow" then "\($sid): Effect \($s.Effect)" else empty end),
      ((["NotAction", "NotResource", "Principal", "NotPrincipal"] - ($s | keys))
        | if length != 4 then "\($sid): NotAction, NotResource or Principal" else empty end),
      ((($s | keys) - ["Sid", "Effect", "Action", "Resource", "Condition", "NotAction", "NotResource",
                      "Principal", "NotPrincipal"])
        | if length > 0 then "\($sid): unknown keys \(join(","))" else empty end),
      (if ($actions | length) == 0 or ($resources | length) == 0 then "\($sid): no Action or no Resource" else empty end),
      (($condition | keys) - ["StringEquals", "ArnEquals"]
        | if length > 0 then "\($sid): condition operator \(join(","))" else empty end),

      ($actions[] as $a
        | (if ($a | test("^[a-z0-9-]+:[A-Za-z]+$")) | not then "\($sid): wildcard or malformed action \($a)" else empty end),
          (forbidden_actions[] as $f | if ($f | matches_glob($a)) then "\($sid): forbidden action \($f) (as \($a))" else empty end),
          (if $kind == "plan" and (($a | test(":(Describe|List|Get)[A-Za-z]*$")) or $a == "logs:FilterLogEvents" | not)
           then "\($sid): non-read action \($a) in the Plan document" else empty end),
          (if ($a | ascii_downcase) == "iam:passrole" and $kind != "apply" then "\($sid): iam:PassRole outside the Apply document" else empty end)),

      (if ($actions | map(ascii_downcase) | index("iam:passrole")) != null then
         (if $actions != ["iam:PassRole"] or ($resources | length) != 1 then "\($sid): iam:PassRole must stand alone on one role"
          elif (pass_role_targets[$resources[0]] // null) == null then "\($sid): iam:PassRole on \($resources[0])"
          elif $condition != {StringEquals: {"iam:PassedToService": pass_role_targets[$resources[0]]}}
          then "\($sid): iam:PassRole without its exact iam:PassedToService"
          else empty end)
       else empty end),

      (if ($resources | index("*")) != null then
         (if $resources != ["*"] then "\($sid): \"*\" mixed with other resources" else empty end),
         ($actions - star_allowed[$kind] | if length > 0 then "\($sid): \"*\" resource for \(join(","))" else empty end),
         (if ($actions | index("ecs:ListTasks")) != null and $condition != {ArnEquals: {"ecs:cluster": measurement_cluster_arn}}
          then "\($sid): ecs:ListTasks without the measurement ecs:cluster condition" else empty end)
       else empty end),

      ($resources[] | select(. != "*") as $r
        | (if $r == launch_template_arn then
             (if $kind != "apply" then "\($sid): launch template outside the Apply document"
              elif ($actions - ["ec2:CreateLaunchTemplate", "ec2:CreateLaunchTemplateVersion", "ec2:ModifyLaunchTemplate",
                                "ec2:DeleteLaunchTemplate"]) != [] then "\($sid): non launch template action on launch-template/*"
              elif ($actions | index("ec2:CreateLaunchTemplate")) != null
                   and $condition.StringEquals["aws:RequestTag/Name"] != measurement_name
              then "\($sid): launch template create not scoped to the measurement Name request tag"
              elif ($actions | index("ec2:CreateLaunchTemplate")) == null
                   and $condition.StringEquals["aws:ResourceTag/Name"] != measurement_name
              then "\($sid): launch template change not scoped to the measurement Name resource tag"
              else empty end)
           elif (measurement_resources | index($r)) != null then empty
           elif ($kind == "host" or $kind == "exec") and (shared_reads | index($r)) != null then empty
           else "\($sid): resource outside the measurement allowlist \($r)" end))
    ]
  | .[];

# Every document resource has to come from measurement_resources, so this one
# check on the list covers them all: a measurement pattern widened far enough to
# reach production fails every document.
def allowlist_violations:
  measurement_resources[] as $r
  | production_arns[] as $p
  | if ($p | matches_glob($r)) then "allowlist entry \($r) matches production \($p)" else empty end;

def policy_violations($kind):
  [
    (if .Version != "2012-10-17" then "Version" else empty end),
    ((keys - ["Version", "Statement"]) | if length > 0 then "unknown policy keys \(join(","))" else empty end),
    (tojson | [scan("<[A-Z_]+>")] | unique - (placeholders[$kind] | keys)
      | if length > 0 then "unknown placeholder \(join(","))" else empty end),
    (policy_size($kind) as $size | if $size > size_limit[$kind] then "size \($size) > \(size_limit[$kind])" else empty end),
    ([.Statement[].Sid] | if length != (unique | length) then "duplicate Sid" else empty end),
    (.Statement[] | statement_violations($kind)),
    allowlist_violations
  ]
  | .[];

policy_violations($kind)
'

work_directory=""

cleanup_tests() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-measurement-policy-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup_tests EXIT

fail() {
    printf '[measurement-stack-policy-test] FAIL: %s\n' "$*" >&2
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

work_directory="$(mktemp -d /tmp/ec-portfolio-measurement-policy-test.XXXXXX)"

kinds=(apply plan host exec)
headings=("$APPLY_HEADING" "$PLAN_HEADING" "$HOST_HEADING" "$EXEC_HEADING")
digests=("$APPLY_SHA" "$PLAN_SHA" "$HOST_SHA" "$EXEC_SHA")

# --- 1. the documents as written: pinned digests and a clean shape gate -------

for index in 0 1 2 3; do
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

# The gate must also see every statement: a positive control that is not empty.
run_gate apply <(jq '.Statement += [{"Sid": "Probe", "Effect": "Allow", "Action": "ec2:RunInstances", "Resource": "*"}]' \
    "$work_directory/apply.json")
[[ "$gate_output" == *"forbidden action ec2:RunInstances"* ]] || fail "the shape gate ignored an added statement"

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

expect_rejected apply "AssociateAddress added" \
    '.Statement += [{"Sid": "X", "Effect": "Allow", "Action": "ec2:AssociateAddress", "Resource": "*"}]'
expect_rejected apply "Elastic IP action through a wildcard" \
    '.Statement += [{"Sid": "X", "Effect": "Allow", "Action": "ec2:*Address*", "Resource": "*"}]'
expect_rejected apply "host PassRole without its condition" \
    'st("PassMeasurementHostRoleToEc2") |= del(.Condition)'
expect_rejected apply "execution PassRole to another service" \
    'st("PassMeasurementExecutionRoleToEcsTasks").Condition.StringEquals["iam:PassedToService"] = "ec2.amazonaws.com"'
expect_rejected apply "PassRole on a production role" \
    'st("PassMeasurementHostRoleToEc2").Resource = "arn:aws:iam::<ACCOUNT_ID>:role/ec-portfolio-demo-ecs-spot"'
expect_rejected apply "cluster widened to production" \
    'st("ReadDeleteExactMeasurementEcsCluster").Resource = "arn:aws:ecs:ap-northeast-1:<ACCOUNT_ID>:cluster/ec-portfolio-demo"'
expect_rejected apply "cluster pattern reaching production" \
    'st("ReadDeleteExactMeasurementEcsCluster").Resource = "arn:aws:ecs:ap-northeast-1:<ACCOUNT_ID>:cluster/ec-portfolio-demo*"'
expect_rejected apply "task definition family widened" \
    'st("RegisterMeasurementTaskDefinitionFamily").Resource = "arn:aws:ecs:ap-northeast-1:<ACCOUNT_ID>:task-definition/ec-portfolio-demo-api*"'
expect_rejected apply "roles widened by a wildcard" \
    'st("ManageExactMeasurementRoles").Resource = "arn:aws:iam::<ACCOUNT_ID>:role/ec-portfolio-demo-ecs-*"'
expect_rejected apply "Auto Scaling group on *" \
    'st("ManageExactMeasurementAutoScalingGroup").Resource = "*"'
expect_rejected apply "launch template changes under the production Name" \
    'st("ManageMeasurementLaunchTemplate").Condition.StringEquals["aws:ResourceTag/Name"] = "ec-portfolio-demo-ecs-spot"'
expect_rejected apply "launch template create without its tag condition" \
    'st("CreateMeasurementLaunchTemplate") |= del(.Condition)'
expect_rejected apply "service action wildcard" \
    'st("ManageExactMeasurementEcsService").Action = ["ecs:*"]'
expect_rejected apply "Allow with NotAction" \
    '.Statement += [{"Sid": "N", "Effect": "Allow", "NotAction": "iam:*", "Resource": "*"}]'
expect_rejected apply "SetDesiredCapacity added" \
    'st("ManageExactMeasurementAutoScalingGroup").Action += ["autoscaling:SetDesiredCapacity"]'
expect_rejected apply "ExecuteCommand added" \
    'st("ManageExactMeasurementEcsService").Action += ["ecs:ExecuteCommand"]'
expect_rejected apply "AttachRolePolicy added" \
    'st("ManageExactMeasurementRoles").Action += ["iam:AttachRolePolicy"]'
expect_rejected apply "log group moved to production" \
    'st("ManageExactMeasurementLogGroup").Resource = ["arn:aws:logs:ap-northeast-1:<ACCOUNT_ID>:log-group:/ec-portfolio/demo/ecs/api"]'
expect_rejected apply "a second * resource" \
    '.Statement += [{"Sid": "X", "Effect": "Allow", "Action": "ecs:DescribeClusters", "Resource": "*"}]'
expect_rejected apply "condition with IfExists" \
    'st("CreateMeasurementEcsCluster").Condition = {"StringEqualsIfExists": {"aws:RequestTag/Name": "ec-portfolio-demo-measure"}}'
expect_rejected apply "over the managed policy size limit" \
    '.Statement += [range(0; 40) as $i | {"Sid": "Pad\($i)", "Effect": "Allow", "Action": "ecs:DescribeClusters", "Resource": "arn:aws:ecs:ap-northeast-1:<ACCOUNT_ID>:cluster/ec-portfolio-demo-measure"}]'
expect_rejected apply "an unknown placeholder" \
    'st("ReadDeleteExactMeasurementEcsCluster").Resource = "arn:aws:ecs:ap-northeast-1:<OTHER_ACCOUNT>:cluster/ec-portfolio-demo-measure"'
expect_rejected apply "Deny statement" \
    '.Statement += [{"Sid": "D", "Effect": "Deny", "Action": "ecs:DeleteCluster", "Resource": "*"}]'
expect_rejected apply "duplicate Sid" \
    '.Statement += [.Statement[0]]'

expect_rejected plan "write action" \
    'st("ReadExactMeasurementEcsService").Action += ["ecs:UpdateService"]'
expect_rejected plan "ListTasks without the cluster condition" \
    'st("ListMeasurementClusterTasks") |= del(.Condition)'
expect_rejected plan "ListTasks on the production cluster" \
    'st("ListMeasurementClusterTasks").Condition.ArnEquals["ecs:cluster"] = "arn:aws:ecs:ap-northeast-1:<ACCOUNT_ID>:cluster/ec-portfolio-demo"'
expect_rejected plan "tasks of any cluster" \
    'st("ReadMeasurementContainerInstancesAndTasks").Resource = "arn:aws:ecs:ap-northeast-1:<ACCOUNT_ID>:task/*"'
expect_rejected plan "production log streams" \
    'st("ReadMeasurementLogStreams").Resource = "arn:aws:logs:ap-northeast-1:<ACCOUNT_ID>:log-group:/ec-portfolio/demo/ecs/api:log-stream:*"'
expect_rejected plan "PassRole in the Plan document" \
    '.Statement += [{"Sid": "P", "Effect": "Allow", "Action": "iam:PassRole", "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/ec-portfolio-demo-ecs-spot-measure", "Condition": {"StringEquals": {"iam:PassedToService": "ec2.amazonaws.com"}}}]'

expect_rejected host "register with the production cluster" \
    'st("RegisterWithMeasurementClusterOnly").Resource = "arn:aws:ecs:ap-northeast-1:<ACCOUNT_ID>:cluster/ec-portfolio-demo"'
expect_rejected host "poll production container instances" \
    'st("PollAndDrainMeasurementClusterInstances").Resource = "arn:aws:ecs:ap-northeast-1:<ACCOUNT_ID>:container-instance/*"'
expect_rejected host "AssociateAddress added" \
    '.Statement += [{"Sid": "E", "Effect": "Allow", "Action": "ec2:AssociateAddress", "Resource": "*"}]'
expect_rejected host "origin TLS write-back" \
    'st("ReadOriginTlsArchiveOnly").Action = ["s3:GetObject", "s3:PutObject"]'
expect_rejected host "Route 53 ACME" \
    '.Statement += [{"Sid": "R", "Effect": "Allow", "Action": "route53:ChangeResourceRecordSets", "Resource": "*"}]'
expect_rejected host "Systems Manager session registration" \
    '.Statement += [{"Sid": "S", "Effect": "Allow", "Action": "ssm:UpdateInstanceInformation", "Resource": "*"}]'
expect_rejected host "lifecycle action on the production group" \
    'st("CompleteOwnLaunchLifecycleAction").Resource = "arn:aws:autoscaling:ap-northeast-1:<ACCOUNT_ID>:autoScalingGroup:*:autoScalingGroupName/ec-portfolio-demo-ecs-spot"'
expect_rejected host "a bucket outside the shared reads" \
    'st("ReadOriginTlsArchiveOnly").Resource = "arn:aws:s3:::<ORIGIN_TLS_BUCKET>/*"'
expect_rejected host "PassRole in a runtime role" \
    '.Statement += [{"Sid": "P", "Effect": "Allow", "Action": "iam:PassRole", "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/ec-portfolio-demo-ecs-spot-measure", "Condition": {"StringEquals": {"iam:PassedToService": "ec2.amazonaws.com"}}}]'

expect_rejected exec "logs into the production log group" \
    'st("WriteMeasurementTaskLogs").Resource = "arn:aws:logs:ap-northeast-1:<ACCOUNT_ID>:log-group:/ec-portfolio/demo/ecs/api:log-stream:*"'
expect_rejected exec "every Demo parameter" \
    'st("ReadApiRuntimeSecrets").Resource = "arn:aws:ssm:ap-northeast-1:<ACCOUNT_ID>:parameter/ec-portfolio/demo/*"'
expect_rejected exec "kms:Decrypt added" \
    '.Statement += [{"Sid": "K", "Effect": "Allow", "Action": "kms:Decrypt", "Resource": "*"}]'

# --- 3. the extraction itself fails closed ------------------------------------

: >"$work_directory/empty.md"
missing="$( (extract_block "$work_directory/empty.md" "$APPLY_HEADING" "$work_directory/none.json") 2>&1 || true)"
[[ "$missing" == *"expected the heading exactly once, found 0"* ]] ||
    fail "a README without the section must fail the extraction: $missing"

printf '[measurement-stack-policy-test] PASS (4 documents pinned and gated, %d mutants rejected)\n' "$mutants"
