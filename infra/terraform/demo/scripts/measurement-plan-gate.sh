#!/usr/bin/env bash

# Fail-closed gate for every Demo plan that touches the Phase 6C-5c measurement
# stack (ecs_measurement.tf, iam_ecs_measurement.tf).
#
# The stack sits next to production, applied by the same identity. A saved plan
# may be applied only when it changes exactly the measurement resources the
# step expects, in exactly the expected way, and leaves every production
# resource as it is. This script reads the JSON form of the saved plan and
# refuses anything else.
#
# Usage:
#   measurement-plan-gate.sh <mode> <plan.json> [options]
#
#   <mode>       merge     the stack PR itself, switch off: no change at all
#                enable    switch on: exactly the 13 measurement creates
#                switch    instance type change: the launch template and the
#                          Auto Scaling group updated in place, nothing else
#                teardown  switch off again: exactly the 13 measurement deletes
#   <plan.json>  terraform show -json <saved plan>
#
#   --reviewed-host-policy <file>   required for enable: the measurement-host
#   --reviewed-exec-policy <file>   and measurement-task-execution documents of
#                                   the Access IaC README, as written there
#   --allow-drift <address>         a resource_drift address that is expected,
#                                   repeatable; any other drift fails
#
# Checks (any failure exits 1 and the plan must not be applied):
#   PG0  the plan is complete, not errored, applyable unless it is empty
#   PG1  the managed changes are exactly the mode's set and actions; no replace
#   PG2  the key production resources are in the plan, as no-ops
#   PG3  no output changes
#   PG4  no resource drift outside --allow-drift
#   PG5  the content of what is created or changed: the launch template carries
#        no Elastic IP and names the measurement cluster, group and hook; the
#        group is 0/0/1 without capacity rebalance or AmazonECSManaged; the
#        backstop; the task definition (production API image, helpers' limits,
#        measurement log group only); the service; the role trusts; and both
#        role policies canonically equal to the reviewed documents
#
# No AWS call. Needs jq; the policy comparison uses the access root's
# policy-gate.sh.

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly POLICY_GATE="$SCRIPT_DIRECTORY/../../access/scripts/policy-gate.sh"
readonly LOG_PREFIX="[measurement-plan-gate]"

readonly MEASUREMENT_ADDRESSES='[
  "aws_ecs_cluster.measurement[0]",
  "aws_cloudwatch_log_group.measurement[0]",
  "aws_iam_role.ecs_task_execution_measurement[0]",
  "aws_iam_role_policy.ecs_task_execution_measurement[0]",
  "aws_ecs_task_definition.measurement[0]",
  "aws_ecs_service.measurement[0]",
  "aws_iam_role.ecs_spot_measurement[0]",
  "aws_iam_role_policy.ecs_spot_measurement[0]",
  "aws_iam_instance_profile.ecs_spot_measurement[0]",
  "aws_launch_template.ecs_spot_measurement[0]",
  "aws_autoscaling_group.ecs_spot_measurement[0]",
  "aws_autoscaling_lifecycle_hook.ecs_spot_measurement_launching[0]",
  "aws_autoscaling_schedule.ecs_spot_measurement_backstop[0]"
]'

# Present in every plan of the Demo root, and never changed by one of these.
readonly PRODUCTION_ADDRESSES='[
  "aws_ecs_cluster.demo",
  "aws_ecs_capacity_provider.ecs_spot",
  "aws_ecs_cluster_capacity_providers.demo",
  "aws_ecs_task_definition.api",
  "aws_ecs_service.api",
  "aws_launch_template.ecs_spot",
  "aws_autoscaling_group.ecs_spot",
  "aws_autoscaling_lifecycle_hook.ecs_spot_launching",
  "aws_iam_role.ecs_spot",
  "aws_iam_instance_profile.ecs_spot",
  "aws_iam_role_policy.ecs_spot_container_instance",
  "aws_iam_role.ecs_task_execution",
  "aws_iam_role_policy.ecs_task_execution_logs",
  "aws_iam_role_policy.ecs_task_execution_runtime_secrets",
  "aws_cloudwatch_log_group.ecs_api",
  "aws_s3_object.spot_runtime_bundle",
  "aws_s3_bucket.runtime_artifacts",
  "aws_s3_bucket.origin_tls",
  "aws_ecr_repository.demo_api",
  "aws_eip.ec2_origin",
  "aws_instance.demo",
  "aws_route53_record.origin_demo",
  "aws_security_group.ec2_origin",
  "aws_security_group.rds",
  "aws_db_instance.demo",
  "aws_cloudfront_distribution.api",
  "aws_scheduler_schedule_group.runtime",
  "aws_scheduler_schedule.runtime[\"ec2_start\"]",
  "aws_scheduler_schedule.runtime[\"ec2_stop\"]",
  "aws_scheduler_schedule.runtime[\"rds_start\"]",
  "aws_scheduler_schedule.runtime[\"rds_stop\"]"
]'

# PG0-PG5 on the plan. Output: one line per violation.
readonly PLAN_GATE_FILTER='
def changes: [.resource_changes[]? | select(.mode == "managed")];
def change_of($address): (changes | map(select(.address == $address)) | first) // null;
def after_of($address): change_of($address).change.after;
def actions_of($address): change_of($address).change.actions;

def measurement_name: "ec-portfolio-demo-ecs-spot-measure";
def measurement_cluster: "ec-portfolio-demo-measure";
def measurement_log_group: "/ec-portfolio/demo/ecs/measure";
def gc_option: " -Xlog:gc,gc+init:stdout:uptime,level,tags";

def expected_actions:
  if $mode == "merge" then {}
  elif $mode == "enable" then ($measurement | map({key: ., value: ["create"]}) | from_entries)
  elif $mode == "teardown" then ($measurement | map({key: ., value: ["delete"]}) | from_entries)
  else {"aws_launch_template.ecs_spot_measurement[0]": ["update"], "aws_autoscaling_group.ecs_spot_measurement[0]": ["update"]}
  end;

def decoded_user_data: (after_of("aws_launch_template.ecs_spot_measurement[0]").user_data // "") | @base64d;

def launch_template_violations:
  after_of("aws_launch_template.ecs_spot_measurement[0]") as $lt
  | decoded_user_data as $ud
  | (if $lt.name != measurement_name then "PG5 launch template name \($lt.name)" else empty end),
    (if ($lt.instance_type | IN("t3a.medium", "t3a.small")) | not then "PG5 launch template instance type \($lt.instance_type)" else empty end),
    (if ($lt.instance_market_options // [] | first // {} | .market_type) != "spot" then "PG5 launch template is not Spot" else empty end),
    (if ($lt.credit_specification // [] | first // {} | .cpu_credits) != "standard" then "PG5 launch template credits are not standard" else empty end),
    (($lt.metadata_options // [] | first // {}) as $m
      | if $m.http_tokens != "required" or $m.http_put_response_hop_limit != 1 then "PG5 launch template metadata is not IMDSv2 with hop limit 1" else empty end),
    (if ($lt.iam_instance_profile // [] | first // {} | .name) != measurement_name then "PG5 launch template instance profile is not the measurement profile" else empty end),
    (if ($ud | contains("eipalloc-")) then "PG5 launch template user data names an Elastic IP allocation" else empty end),
    (["readonly EIP_ALLOCATION_ID_VALUE=\"\"",
      "readonly ECS_CLUSTER_NAME_VALUE=\"\(measurement_cluster)\"",
      "readonly AUTOSCALING_GROUP_NAME=\"\(measurement_name)\"",
      "readonly LIFECYCLE_HOOK_NAME=\"\(measurement_name)-launching\""][] as $line
      | if ($ud | split("\n") | index($line)) == null then "PG5 launch template user data lacks: \($line)" else empty end);

def group_violations:
  after_of("aws_autoscaling_group.ecs_spot_measurement[0]") as $asg
  | (if $asg.name != measurement_name then "PG5 group name \($asg.name)" else empty end),
    (if [$asg.min_size, $asg.desired_capacity, $asg.max_size] != [0, 0, 1] then "PG5 group min/desired/max \($asg.min_size)/\($asg.desired_capacity)/\($asg.max_size), not 0/0/1" else empty end),
    (if $asg.capacity_rebalance != false then "PG5 group has capacity rebalance" else empty end),
    (if ([$asg.tag[]?.key] | index("AmazonECSManaged")) != null then "PG5 group carries AmazonECSManaged" else empty end);

def task_definition_violations:
  after_of("aws_ecs_task_definition.measurement[0]") as $td
  | ((after_of("aws_ecs_task_definition.api").container_definitions // "[]") | fromjson
      | map(select(.name == "api")) | first // {} | .image) as $production_image
  | (if [$td.family, $td.network_mode] != ["ec-portfolio-demo-api-measure", "host"] then "PG5 task definition family or network mode" else empty end),
    (if ($td.task_role_arn // null) != null then "PG5 task definition has a task role" else empty end),
    (if ($td.container_definitions | type) != "string" then "PG5 task definition containers are unknown in the plan"
     else
       ($td.container_definitions | fromjson) as $containers
       | (if ([$containers[].name] | sort) != ["api", "load-driver", "memory-probe", "valkey"] then "PG5 task definition containers \([$containers[].name] | join(","))" else empty end),
         ($containers[] | select(.logConfiguration.options["awslogs-group"] != measurement_log_group) | "PG5 container \(.name) logs outside the measurement log group"),
         ($containers[] | select(.privileged == true) | "PG5 container \(.name) is privileged"),
         ($containers[] | select(.name == "api") as $api
           | (if $api.image != $production_image or $production_image == null then "PG5 measurement API image differs from the production API image" else empty end),
             ([$api.environment[]? | select(.name == "JAVA_TOOL_OPTIONS") | .value] as $opts
               | if ($opts | length) != 1 or ($opts[0] | endswith(gc_option) | not) then "PG5 measurement API lacks the GC logging option" else empty end)),
         ($containers[] | select(.name == "memory-probe" or .name == "load-driver") as $h
           | if [$h.essential, $h.user, $h.readonlyRootFilesystem, ($h.linuxParameters.capabilities.drop // []), $h.memoryReservation, $h.memory, ($h.portMappings // [])]
                != [false, "65534:65534", true, ["ALL"], 16, 32, []]
             then "PG5 helper \($h.name) is not non-essential nobody, read-only, no capabilities, 16/32 MiB, no port" else empty end),
         ($containers[] | select(.name == "load-driver") | if .dependsOn != [{"containerName": "api", "condition": "START"}] then "PG5 load-driver does not wait for the API container start" else empty end)
     end);

def creation_violations:
  (after_of("aws_autoscaling_schedule.ecs_spot_measurement_backstop[0]") as $s
    | if [$s.recurrence, $s.time_zone, $s.min_size, $s.max_size, $s.desired_capacity] != ["30 0-11,16-23 * * *", "Asia/Tokyo", 0, 1, 0]
      then "PG5 backstop is not 30 0-11,16-23 * * * Asia/Tokyo to 0/0/1" else empty end),
  (after_of("aws_autoscaling_lifecycle_hook.ecs_spot_measurement_launching[0]") as $h
    | if [$h.name, $h.lifecycle_transition, $h.default_result] != ["\(measurement_name)-launching", "autoscaling:EC2_INSTANCE_LAUNCHING", "ABANDON"]
      then "PG5 lifecycle hook is not the launching hook with ABANDON" else empty end),
  (after_of("aws_ecs_cluster.measurement[0]") as $c
    | if $c.name != measurement_cluster or ([$c.setting[]? | select(.name == "containerInsights") | .value] != ["disabled"])
      then "PG5 cluster is not \(measurement_cluster) with Container Insights disabled" else empty end),
  (after_of("aws_cloudwatch_log_group.measurement[0]") as $l
    | if $l.name != measurement_log_group then "PG5 log group \($l.name)" else empty end),
  (after_of("aws_ecs_service.measurement[0]") as $svc
    | if [$svc.name, $svc.scheduling_strategy, $svc.launch_type, $svc.enable_execute_command] != ["ec-portfolio-demo-api-measure", "DAEMON", "EC2", false]
      then "PG5 service is not the DAEMON ec-portfolio-demo-api-measure on EC2 without execute command" else empty end),
  ([["aws_iam_role.ecs_spot_measurement[0]", measurement_name, "ec2.amazonaws.com"],
    ["aws_iam_role.ecs_task_execution_measurement[0]", "ec-portfolio-demo-ecs-task-execution-measure", "ecs-tasks.amazonaws.com"]][] as [$address, $name, $service]
    | after_of($address) as $role
    | if $role.name != $name then "PG5 role name \($role.name)"
      elif (($role.assume_role_policy // "{}") | fromjson | .Statement)
           != [{"Effect": "Allow", "Principal": {"Service": $service}, "Action": "sts:AssumeRole"}]
      then "PG5 role \($name) is not trusted by \($service) alone"
      else empty end),
  (if after_of("aws_iam_instance_profile.ecs_spot_measurement[0]").name != measurement_name then "PG5 instance profile name" else empty end),
  ([["aws_iam_role_policy.ecs_spot_measurement[0]", "measurement-host"],
    ["aws_iam_role_policy.ecs_task_execution_measurement[0]", "measurement-task-execution"]][] as [$address, $name]
    | change_of($address).change as $c
    | if $c.after.name != $name then "PG5 policy name \($c.after.name) at \($address)"
      elif ($c.after_unknown.policy // false) or ($c.after.policy | type) != "string"
      then "PG5 \($name) is unknown in the plan and cannot be compared" else empty end),
  task_definition_violations;

(if (.format_version // null) == null then "PG0 not the JSON form of a plan" else empty end),
(if .errored == true then "PG0 the plan is errored" else empty end),
(if .complete != true then "PG0 the plan is not complete" else empty end),
(if $mode != "merge" and .applyable != true then "PG0 the plan is not applyable" else empty end),

(expected_actions as $expected
  | (changes | map(select(.change.actions != ["no-op"])) | map({key: .address, value: .change.actions}) | from_entries) as $actual
  | (($actual | to_entries[] | select(.value | (index("delete") != null and index("create") != null))) | "PG1 replace of \(.key)"),
    (($actual | to_entries[] | select($expected[.key] == null)) | "PG1 unexpected \(.value | join(",")) of \(.key)"),
    (($expected | to_entries[] | select($actual[.key] != .value)) | "PG1 expected \(.value | join(",")) of \(.key), plan has \($actual[.key] // ["no-op or absent"] | join(","))")),

($production[] as $address
  | actions_of($address) as $a
  | if $a == null then "PG2 production resource absent from the plan: \($address)"
    elif $a != ["no-op"] then "PG2 production resource changed: \($address) \($a | join(","))"
    else empty end),

(.output_changes // {} | to_entries[] | select(.value.actions != ["no-op"]) | "PG3 output change: \(.key)"),

(.resource_drift[]? | select(.address as $a | $allowed_drift | index($a) | not) | "PG4 drift not allowed: \(.address)"),

(if $mode == "enable" then launch_template_violations, group_violations, creation_violations
 elif $mode == "switch" then launch_template_violations, group_violations
 else empty end)
'

fail() {
    printf '%s FAIL: %s\n' "$LOG_PREFIX" "$*" >&2
    exit 1
}

usage() {
    printf 'Usage: %s merge|enable|switch|teardown <plan.json> [--reviewed-host-policy FILE] [--reviewed-exec-policy FILE] [--allow-drift ADDRESS]...\n' "$0" >&2
    exit 2
}

work_directory=""
cleanup() {
    if [[ -n "$work_directory" && -d "$work_directory" ]]; then
        rm -rf -- "$work_directory"
    fi
}
trap cleanup EXIT

# compare_policy <address> <reviewed.json> <plan.json>: the planned policy with
# the account ID and the two bucket names written back as the placeholders of
# the reviewed document, compared canonically.
compare_policy() {
    local address="$1" reviewed="$2" plan="$3" rendered
    rendered="$work_directory/$(printf '%s' "$address" | tr -c 'A-Za-z0-9' '_').json"
    jq -r --arg address "$address" '
        def after_of($a): ([.resource_changes[]? | select(.mode == "managed" and .address == $a)] | first // {}).change.after;
        (after_of("aws_ecr_repository.demo_api").arn // "" | split(":") | .[4] // "") as $account
        | (after_of("aws_s3_bucket.runtime_artifacts").bucket // "") as $runtime
        | (after_of("aws_s3_bucket.origin_tls").bucket // "") as $tls
        | if ($account | test("^[0-9]{12}$") | not) or $runtime == "" or $tls == ""
          then error("the account ID or a bucket name is not in the plan")
          else after_of($address).policy
               | split($account) | join("<ACCOUNT_ID>")
               | split($runtime) | join("<RUNTIME_ARTIFACTS_BUCKET>")
               | split($tls) | join("<ORIGIN_TLS_BUCKET>")
          end
    ' "$plan" >"$rendered" || return 1
    "$POLICY_GATE" compare "$reviewed" "$rendered" >/dev/null 2>"$rendered.diff" || {
        printf 'PG5 %s differs from the reviewed document:\n%s\n' "$address" "$(sed 's/^/    /' "$rendered.diff")"
        return 1
    }
}

main() {
    command -v jq >/dev/null 2>&1 || fail "jq is required"
    [[ $# -ge 2 ]] || usage
    local mode="$1" plan="$2"
    shift 2
    case "$mode" in merge | enable | switch | teardown) ;; *) usage ;; esac
    [[ -f "$plan" ]] || fail "plan JSON not found: $plan"

    local host_policy="" exec_policy="" allowed_drift="[]"
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --reviewed-host-policy) [[ $# -ge 2 ]] || usage; host_policy="$2"; shift 2 ;;
        --reviewed-exec-policy) [[ $# -ge 2 ]] || usage; exec_policy="$2"; shift 2 ;;
        --allow-drift) [[ $# -ge 2 ]] || usage; allowed_drift="$(jq -c --arg a "$2" '. + [$a]' <<<"$allowed_drift")"; shift 2 ;;
        *) usage ;;
        esac
    done
    if [[ "$mode" == enable ]]; then
        [[ -f "$host_policy" && -f "$exec_policy" ]] ||
            fail "enable needs --reviewed-host-policy and --reviewed-exec-policy (the Access IaC README documents)"
        [[ -x "$POLICY_GATE" ]] || fail "the access root policy gate is not available: $POLICY_GATE"
    fi

    work_directory="$(mktemp -d)"
    local violations
    violations="$(jq -r --arg mode "$mode" --argjson measurement "$MEASUREMENT_ADDRESSES" \
        --argjson production "$PRODUCTION_ADDRESSES" --argjson allowed_drift "$allowed_drift" \
        "$PLAN_GATE_FILTER" "$plan")" || fail "the plan could not be evaluated: $plan"

    if [[ "$mode" == enable ]]; then
        local policy_violation
        policy_violation="$(compare_policy 'aws_iam_role_policy.ecs_spot_measurement[0]' "$host_policy" "$plan")" ||
            violations+=$'\n'"${policy_violation:-PG5 measurement-host could not be compared}"
        policy_violation="$(compare_policy 'aws_iam_role_policy.ecs_task_execution_measurement[0]' "$exec_policy" "$plan")" ||
            violations+=$'\n'"${policy_violation:-PG5 measurement-task-execution could not be compared}"
    fi
    violations="$(printf '%s\n' "$violations" | sed '/^$/d')"

    local summary
    summary="$(jq -r '[.resource_changes[]? | select(.mode == "managed") | .change.actions | join(",")]
        | group_by(.) | map("\(.[0])=\(length)") | join(" ")' "$plan")"
    if [[ -n "$violations" ]]; then
        printf '%s\n' "$violations" | sed "s/^/$LOG_PREFIX /" >&2
        fail "$(printf '%s\n' "$violations" | grep -c '^PG') violation(s) in $mode mode ($summary); do not apply this plan"
    fi
    printf '%s PASS %s: %s\n' "$LOG_PREFIX" "$mode" "$summary"
}

main "$@"
