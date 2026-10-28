#!/usr/bin/env bash

# Tests for the Phase 6C-5c measurement plan gate (measurement-plan-gate.sh).
#
# Everything runs on small synthetic plan JSON built here: one plan per mode
# that must pass, then mutants of them that must each fail, and drift
# allowances the gate must refuse. The reviewed policy
# documents are fixtures too; the comparison with the real documents of the
# Access IaC README happens when the gate runs on a saved plan.
#
# No AWS call and no Terraform command. Runs under bash 3.2 and bash 5.

set -euo pipefail

readonly SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly GATE="$SCRIPT_DIRECTORY/measurement-plan-gate.sh"
readonly ACCOUNT="111122223333"
readonly RUNTIME_BUCKET="ec-portfolio-demo-runtime-artifacts-fixture"
readonly TLS_BUCKET="ec-portfolio-demo-origin-tls-fixture"

work_directory=""

cleanup_tests() {
    local exit_code=$?
    trap - EXIT
    if [[ -n "$work_directory" && "$work_directory" == /tmp/ec-portfolio-measurement-gate-test.* ]]; then
        rm -rf -- "$work_directory"
    fi
    exit "$exit_code"
}

trap cleanup_tests EXIT

fail() {
    printf '[measurement-plan-gate-test] FAIL: %s\n' "$*" >&2
    exit 1
}

work_directory="$(mktemp -d /tmp/ec-portfolio-measurement-gate-test.XXXXXX)"
cd "$work_directory"

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

cat >reviewed-host.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {"Sid": "RegisterWithMeasurementClusterOnly", "Effect": "Allow", "Action": "ecs:RegisterContainerInstance",
     "Resource": "arn:aws:ecs:ap-northeast-1:<ACCOUNT_ID>:cluster/ec-portfolio-demo-measure"},
    {"Sid": "ReadPinnedRuntimeBundleVersion", "Effect": "Allow", "Action": "s3:GetObjectVersion",
     "Resource": "arn:aws:s3:::<RUNTIME_ARTIFACTS_BUCKET>/runtime/spot-runtime.tar.gz"},
    {"Sid": "ReadOriginTlsArchiveOnly", "Effect": "Allow", "Action": "s3:GetObject",
     "Resource": "arn:aws:s3:::<ORIGIN_TLS_BUCKET>/origin-tls/letsencrypt.tar.gz"}
  ]
}
JSON

cat >reviewed-exec.json <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {"Sid": "WriteMeasurementTaskLogs", "Effect": "Allow", "Action": ["logs:CreateLogStream", "logs:PutLogEvents"],
     "Resource": "arn:aws:logs:ap-northeast-1:<ACCOUNT_ID>:log-group:/ec-portfolio/demo/ecs/measure:log-stream:*"}
  ]
}
JSON

# The planned policy is the reviewed one with real values, rendered compactly as
# Terraform's jsonencode would.
render_policy() {
    sed -e "s/<ACCOUNT_ID>/$ACCOUNT/g" -e "s/<RUNTIME_ARTIFACTS_BUCKET>/$RUNTIME_BUCKET/g" \
        -e "s/<ORIGIN_TLS_BUCKET>/$TLS_BUCKET/g" "$1" | jq -c .
}

# The loader as the measurement launch template renders it: only the lines the
# gate reads matter here.
user_data="$(printf '%s\n' '#!/usr/bin/env bash' \
    'readonly ECS_CLUSTER_NAME_VALUE="ec-portfolio-demo-measure"' \
    'readonly AUTOSCALING_GROUP_NAME="ec-portfolio-demo-ecs-spot-measure"' \
    'readonly LIFECYCLE_HOOK_NAME="ec-portfolio-demo-ecs-spot-measure-launching"' \
    'readonly EIP_ALLOCATION_ID_VALUE=""' | base64 | tr -d '\n')"

api_image="$ACCOUNT.dkr.ecr.ap-northeast-1.amazonaws.com/ec-portfolio-demo-api:868efcc04316de89e73174c48d42619cd4466a14"

production_containers="$(jq -cn --arg image "$api_image" '[
  {name: "valkey", image: "valkey/valkey@sha256:16625369f78a3844287f298799bebb7f4e59d0f7f40e789779d60e890f3d4399", essential: true, user: "999:1000",
   logConfiguration: {logDriver: "awslogs", options: {"awslogs-group": "/ec-portfolio/demo/ecs/api", "awslogs-stream-prefix": "valkey"}}},
  {name: "api", image: $image, essential: true, user: "10001:10001",
   environment: [{name: "JAVA_TOOL_OPTIONS", value: "-Djava.net.preferIPv4Stack=true"}],
   logConfiguration: {logDriver: "awslogs", options: {"awslogs-group": "/ec-portfolio/demo/ecs/api", "awslogs-stream-prefix": "api"}}}
]')"

helper() {
    jq -cn --arg name "$1" '{name: $name, image: "valkey/valkey@sha256:16625369f78a3844287f298799bebb7f4e59d0f7f40e789779d60e890f3d4399",
        essential: false, user: "65534:65534", privileged: false, readonlyRootFilesystem: true,
        linuxParameters: {capabilities: {drop: ["ALL"]}}, memoryReservation: 16, memory: 32,
        logConfiguration: {logDriver: "awslogs", options: {"awslogs-group": "/ec-portfolio/demo/ecs/measure", "awslogs-stream-prefix": $name}}}'
}

measurement_containers="$(jq -cn --argjson production "$production_containers" \
    --argjson probe "$(helper memory-probe)" --argjson driver "$(helper load-driver)" '
    ($production | map(
        .logConfiguration.options["awslogs-group"] = "/ec-portfolio/demo/ecs/measure"
        | .logConfiguration.options["awslogs-stream-prefix"] = "measure-\(.name)"
        | if .name == "api" then .environment = [{name: "JAVA_TOOL_OPTIONS", value: "-Djava.net.preferIPv4Stack=true -Xlog:gc,gc+init:stdout:uptime,level,tags"}] else . end))
    + [$probe, ($driver + {dependsOn: [{containerName: "api", condition: "START"}]})]')"

# The after values of the 13 measurement resources, as the enable plan has them.
measurement_after="$(jq -cn --arg ud "$user_data" --arg containers "$measurement_containers" \
    --arg host "$(render_policy reviewed-host.json)" --arg exec "$(render_policy reviewed-exec.json)" '{
  "aws_ecs_cluster.measurement[0]": {name: "ec-portfolio-demo-measure", setting: [{name: "containerInsights", value: "disabled"}]},
  "aws_cloudwatch_log_group.measurement[0]": {name: "/ec-portfolio/demo/ecs/measure", retention_in_days: 7},
  "aws_iam_role.ecs_task_execution_measurement[0]": {name: "ec-portfolio-demo-ecs-task-execution-measure",
    assume_role_policy: ({Version: "2012-10-17", Statement: [{Effect: "Allow", Principal: {Service: "ecs-tasks.amazonaws.com"}, Action: "sts:AssumeRole"}]} | tojson)},
  "aws_iam_role_policy.ecs_task_execution_measurement[0]": {name: "measurement-task-execution", policy: $exec},
  "aws_ecs_task_definition.measurement[0]": {family: "ec-portfolio-demo-api-measure", network_mode: "host", task_role_arn: null,
    container_definitions: $containers},
  "aws_ecs_service.measurement[0]": {name: "ec-portfolio-demo-api-measure", scheduling_strategy: "DAEMON", launch_type: "EC2",
    enable_execute_command: false},
  "aws_iam_role.ecs_spot_measurement[0]": {name: "ec-portfolio-demo-ecs-spot-measure",
    assume_role_policy: ({Version: "2012-10-17", Statement: [{Effect: "Allow", Principal: {Service: "ec2.amazonaws.com"}, Action: "sts:AssumeRole"}]} | tojson)},
  "aws_iam_role_policy.ecs_spot_measurement[0]": {name: "measurement-host", policy: $host},
  "aws_iam_instance_profile.ecs_spot_measurement[0]": {name: "ec-portfolio-demo-ecs-spot-measure"},
  "aws_launch_template.ecs_spot_measurement[0]": {name: "ec-portfolio-demo-ecs-spot-measure", instance_type: "t3a.medium",
    instance_market_options: [{market_type: "spot"}], credit_specification: [{cpu_credits: "standard"}],
    metadata_options: [{http_tokens: "required", http_put_response_hop_limit: 1}],
    iam_instance_profile: [{name: "ec-portfolio-demo-ecs-spot-measure"}], user_data: $ud},
  "aws_autoscaling_group.ecs_spot_measurement[0]": {name: "ec-portfolio-demo-ecs-spot-measure", min_size: 0, desired_capacity: 0,
    max_size: 1, capacity_rebalance: false, tag: [{key: "Name"}, {key: "Project"}, {key: "Environment"}, {key: "Owner"}]},
  "aws_autoscaling_lifecycle_hook.ecs_spot_measurement_launching[0]": {name: "ec-portfolio-demo-ecs-spot-measure-launching",
    lifecycle_transition: "autoscaling:EC2_INSTANCE_LAUNCHING", default_result: "ABANDON", heartbeat_timeout: 3600},
  "aws_autoscaling_schedule.ecs_spot_measurement_backstop[0]": {recurrence: "30 0-11,16-23 * * *", time_zone: "Asia/Tokyo",
    min_size: 0, max_size: 1, desired_capacity: 0}
}')"

production_changes="$(jq -cn --arg account "$ACCOUNT" --arg runtime "$RUNTIME_BUCKET" --arg tls "$TLS_BUCKET" \
    --arg containers "$production_containers" '
  ["aws_ecs_cluster.demo", "aws_ecs_capacity_provider.ecs_spot", "aws_ecs_cluster_capacity_providers.demo",
   "aws_ecs_service.api", "aws_launch_template.ecs_spot", "aws_autoscaling_group.ecs_spot",
   "aws_autoscaling_lifecycle_hook.ecs_spot_launching", "aws_iam_role.ecs_spot", "aws_iam_instance_profile.ecs_spot",
   "aws_iam_role_policy.ecs_spot_container_instance", "aws_iam_role_policy.ecs_spot_origin_eip_promotion",
   "aws_iam_role.ecs_task_execution", "aws_iam_role_policy.ecs_task_execution_logs",
   "aws_iam_role_policy.ecs_task_execution_runtime_secrets", "aws_cloudwatch_log_group.ecs_api",
   "aws_s3_object.spot_runtime_bundle", "aws_eip.ec2_origin", "aws_instance.demo", "aws_route53_record.origin_demo",
   "aws_security_group.ec2_origin", "aws_security_group.rds", "aws_db_instance.demo", "aws_cloudfront_distribution.api",
   "aws_scheduler_schedule_group.runtime", "aws_scheduler_schedule.runtime[\"ec2_start\"]",
   "aws_scheduler_schedule.runtime[\"ec2_stop\"]", "aws_scheduler_schedule.runtime[\"rds_start\"]",
   "aws_scheduler_schedule.runtime[\"rds_stop\"]"]
  | map({address: ., mode: "managed", change: {actions: ["no-op"], before: {}, after: {}}})
  + [{address: "aws_ecr_repository.demo_api", mode: "managed", change: {actions: ["no-op"], after: {arn: "arn:aws:ecr:ap-northeast-1:\($account):repository/ec-portfolio-demo-api"}}},
     {address: "aws_s3_bucket.runtime_artifacts", mode: "managed", change: {actions: ["no-op"], after: {bucket: $runtime}}},
     {address: "aws_s3_bucket.origin_tls", mode: "managed", change: {actions: ["no-op"], after: {bucket: $tls}}},
     {address: "aws_ecs_task_definition.api", mode: "managed", change: {actions: ["no-op"], after: {container_definitions: $containers}}},
     {address: "data.aws_caller_identity.current", mode: "data", change: {actions: ["read"], after: {}}}]')"

# plan <applyable> <measurement changes as a JSON array>
plan() {
    jq -n --argjson applyable "$1" --argjson production "$production_changes" --argjson measurement "$2" '{
        format_version: "1.2", terraform_version: "1.16.0", complete: true, errored: false, applyable: $applyable,
        resource_changes: ($production + $measurement), output_changes: {}, resource_drift: []}'
}

plan false '[]' >merge.json
plan true "$(jq -c 'to_entries | map({address: .key, mode: "managed", change: {actions: ["create"], before: null, after: .value, after_unknown: {}}})' <<<"$measurement_after")" >enable.json
plan true "$(jq -c 'to_entries | map({address: .key, mode: "managed", change: {actions: ["delete"], before: .value, after: null}})' <<<"$measurement_after")" >teardown.json
plan true "$(jq -c 'to_entries | map(
    if .key == "aws_launch_template.ecs_spot_measurement[0]" then {address: .key, mode: "managed", change: {actions: ["update"], before: .value, after: (.value + {instance_type: "t3a.small"})}}
    elif .key == "aws_autoscaling_group.ecs_spot_measurement[0]" then {address: .key, mode: "managed", change: {actions: ["update"], before: .value, after: .value}}
    else {address: .key, mode: "managed", change: {actions: ["no-op"], before: .value, after: .value}} end)' <<<"$measurement_after")" >switch.json

# The origin Elastic IP as a refresh reads it once a cutover has moved it to a
# Spot host: the five association-derived attributes change and nothing else
# does. A subset of the aws_eip attributes, enough for each to be compared.
eip_before="$(jq -cn '{allocation_id: "eipalloc-0123456789abcdef0", association_id: "eipassoc-0123456789abcdef0",
  domain: "vpc", id: "eipalloc-0123456789abcdef0", instance: "i-0123456789abcdef0", network_border_group: "ap-northeast-1",
  network_interface: "eni-0123456789abcdef0", private_dns: "ip-10-20-0-10.ap-northeast-1.compute.internal",
  private_ip: "10.20.0.10", public_dns: "ec2-203-0-113-10.ap-northeast-1.compute.amazonaws.com", public_ip: "203.0.113.10",
  public_ipv4_pool: "amazon", tags: {Name: "ec-portfolio-demo-ec2-origin"},
  tags_all: {Name: "ec-portfolio-demo-ec2-origin", Project: "ec-portfolio", Environment: "demo", Owner: "fixture"}}')"
eip_drift="$(jq -cn --argjson before "$eip_before" '{address: "aws_eip.ec2_origin", mode: "managed", type: "aws_eip",
  name: "ec2_origin", provider_name: "registry.terraform.io/hashicorp/aws",
  change: {actions: ["update"], before: $before,
    after: ($before + {association_id: "eipassoc-0fedcba9876543210", instance: "i-0fedcba9876543210",
      network_interface: "eni-0fedcba9876543210", private_dns: "ip-10-20-0-20.ap-northeast-1.compute.internal",
      private_ip: "10.20.0.20"}),
    after_unknown: {}, before_sensitive: {tags: {}, tags_all: {}}, after_sensitive: {tags: {}, tags_all: {}}}}')"
for base in merge enable switch teardown; do
    jq --argjson drift "$eip_drift" '.resource_drift = [$drift]' "$base.json" >"$base-drift.json"
done

# The allowance an operator gives after reading that drift in the saved plan:
# each attribute named on its own.
cutover_allowance=(--allow-drift aws_eip.ec2_origin:association_id --allow-drift aws_eip.ec2_origin:instance
    --allow-drift aws_eip.ec2_origin:network_interface --allow-drift aws_eip.ec2_origin:private_dns
    --allow-drift aws_eip.ec2_origin:private_ip)

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

gate_output=""
gate_status=0
run_gate() {
    local mode="$1" plan_file="$2"
    shift 2
    gate_status=0
    if [[ "$mode" == enable ]]; then
        set -- --reviewed-host-policy reviewed-host.json --reviewed-exec-policy reviewed-exec.json "$@"
    fi
    gate_output="$("$GATE" "$mode" "$plan_file" "$@" 2>&1)" || gate_status=$?
}

expect_pass() {
    run_gate "$@"
    ((gate_status == 0)) || fail "expected PASS for $1 $2: $gate_output"
    [[ "$gate_output" == *"PASS $1"* ]] || fail "no PASS line for $1 $2"
}

mutants=0
# expect_reject <mode> <base plan> <expected message part> <jq filter> [gate options...]
expect_reject() {
    local mode="$1" base="$2" expected="$3" filter="$4"
    shift 4
    jq "def rc(\$a): .resource_changes[] | select(.address == \$a); def after(\$a): rc(\$a).change.after; $filter" \
        "$base" >mutant.json || fail "mutant could not be built: $filter"
    ! cmp -s mutant.json <(jq . "$base") || fail "mutant did not change the plan: $filter"
    run_gate "$mode" mutant.json "$@"
    ((gate_status == 1)) || fail "mutant survived ($mode, exit $gate_status): $filter"
    [[ "$gate_output" == *"$expected"* ]] || fail "mutant rejected for another reason ($filter): $gate_output"
    mutants=$((mutants + 1))
}

refused=0
# expect_fail <mode> <plan> <expected message part> [gate options...]: the plan
# as it is, refused for the drift allowance given.
expect_fail() {
    local mode="$1" plan_file="$2" expected="$3"
    shift 3
    run_gate "$mode" "$plan_file" "$@"
    ((gate_status == 1)) || fail "expected FAIL for $mode $plan_file $* (exit $gate_status): $gate_output"
    [[ "$gate_output" == *"$expected"* ]] || fail "$mode $plan_file $* failed for another reason: $gate_output"
    refused=$((refused + 1))
}

# --- 1. each mode passes on its own plan --------------------------------------

expect_pass merge merge.json
expect_pass enable enable.json
expect_pass switch switch.json
expect_pass teardown teardown.json
[[ "$gate_output" == *"delete=13"* ]] || fail "the teardown summary must count 13 deletes: $gate_output"

# Drift passes in every mode when each attribute it changes is named, and an
# allowance for drift the plan does not have changes nothing. A narrower drift
# needs only its own attribute: the address associated again with the same
# host moves only the association ID.
for mode in merge enable switch teardown; do
    expect_pass "$mode" "$mode-drift.json" "${cutover_allowance[@]}"
done
expect_pass merge merge.json "${cutover_allowance[@]}"
jq '.resource_drift[0].change |= (.after += (.before | {instance, network_interface, private_dns, private_ip}))' \
    merge-drift.json >reassociated.json
expect_pass merge reassociated.json --allow-drift aws_eip.ec2_origin:association_id

# None of the five is allowed unless named: without an allowance the drift fails
# on the address, and leaving out any one attribute fails on that one.
expect_fail merge merge-drift.json "PG4 drift not allowed: aws_eip.ec2_origin"
for omitted in association_id instance network_interface private_dns private_ip; do
    set --
    for attribute in association_id instance network_interface private_dns private_ip; do
        [[ "$attribute" == "$omitted" ]] || set -- "$@" --allow-drift "aws_eip.ec2_origin:$attribute"
    done
    expect_fail merge merge-drift.json "PG4 drift not allowed: aws_eip.ec2_origin $omitted" "$@"
done

# --- 2. the wrong mode for a plan fails ---------------------------------------

for pair in "merge enable.json" "teardown enable.json" "enable teardown.json" "switch enable.json" "merge teardown.json" "enable merge.json"; do
    run_gate ${pair}
    ((gate_status == 1)) || fail "a plan passed the wrong mode: $pair"
done

# --- 3. PG0-PG4 ---------------------------------------------------------------

expect_reject enable enable.json "PG0 the plan is errored" '.errored = true'
expect_reject enable enable.json "PG0 the plan is not complete" '.complete = false'
expect_reject enable enable.json "PG0 the plan is not applyable" '.applyable = false'
expect_reject enable enable.json "PG1 unexpected update of aws_launch_template.ecs_spot" \
    '(rc("aws_launch_template.ecs_spot").change.actions) = ["update"]'
expect_reject enable enable.json "PG1 replace of aws_ecs_task_definition.measurement[0]" \
    '(rc("aws_ecs_task_definition.measurement[0]").change.actions) = ["delete", "create"]'
expect_reject enable enable.json "PG1 expected create of aws_autoscaling_schedule.ecs_spot_measurement_backstop[0]" \
    '.resource_changes |= map(select(.address != "aws_autoscaling_schedule.ecs_spot_measurement_backstop[0]"))'
expect_reject enable enable.json "PG1 unexpected create of aws_eip.measurement" \
    '.resource_changes += [{address: "aws_eip.measurement", mode: "managed", change: {actions: ["create"], after: {}}}]'
expect_reject enable enable.json "PG2 production resource absent from the plan: aws_eip.ec2_origin" \
    '.resource_changes |= map(select(.address != "aws_eip.ec2_origin"))'
expect_reject teardown teardown.json "PG1 unexpected delete of aws_instance.demo" \
    '(rc("aws_instance.demo").change.actions) = ["delete"]'
expect_reject teardown teardown.json "PG1 expected delete of aws_ecs_cluster.measurement[0]" \
    '(rc("aws_ecs_cluster.measurement[0]").change.actions) = ["no-op"]'
expect_reject switch switch.json "PG1 unexpected update of aws_ecs_task_definition.measurement[0]" \
    '(rc("aws_ecs_task_definition.measurement[0]").change.actions) = ["update"]'
expect_reject merge merge.json "PG1 unexpected create of aws_ecs_cluster.measurement[0]" \
    '.resource_changes += [{address: "aws_ecs_cluster.measurement[0]", mode: "managed", change: {actions: ["create"], after: {}}}]'
expect_reject merge merge.json "PG3 output change: spot_runtime_bundle_version_id" \
    '.output_changes = {spot_runtime_bundle_version_id: {actions: ["update"]}}'

# --- 4. PG5: the launch template ----------------------------------------------

lt='after("aws_launch_template.ecs_spot_measurement[0]")'
expect_reject enable enable.json "PG5 launch template user data names an Elastic IP allocation" \
    "($lt.user_data) |= (@base64d | sub(\"EIP_ALLOCATION_ID_VALUE=\\\"\\\"\"; \"EIP_ALLOCATION_ID_VALUE=\\\"eipalloc-0123456789abcdef0\\\"\") | @base64)"
expect_reject enable enable.json "PG5 launch template user data lacks: readonly ECS_CLUSTER_NAME_VALUE=\"ec-portfolio-demo-measure\"" \
    "($lt.user_data) |= (@base64d | sub(\"demo-measure\\\"\"; \"demo\\\"\") | @base64)"
expect_reject enable enable.json "PG5 launch template user data lacks: readonly AUTOSCALING_GROUP_NAME" \
    "($lt.user_data) |= (@base64d | sub(\"GROUP_NAME=\\\"ec-portfolio-demo-ecs-spot-measure\\\"\"; \"GROUP_NAME=\\\"ec-portfolio-demo-ecs-spot\\\"\") | @base64)"
expect_reject enable enable.json "PG5 launch template instance type t3a.large" "($lt.instance_type) = \"t3a.large\""
expect_reject enable enable.json "PG5 launch template credits are not standard" "($lt.credit_specification) = [{cpu_credits: \"unlimited\"}]"
expect_reject enable enable.json "PG5 launch template is not Spot" "($lt.instance_market_options) = []"
expect_reject enable enable.json "PG5 launch template metadata is not IMDSv2" "($lt.metadata_options[0].http_tokens) = \"optional\""
expect_reject enable enable.json "PG5 launch template instance profile is not the measurement profile" \
    "($lt.iam_instance_profile) = [{name: \"ec-portfolio-demo-ecs-spot\"}]"
expect_reject switch switch.json "PG5 launch template user data names an Elastic IP allocation" \
    "($lt.user_data) |= (@base64d | . + \"readonly X=eipalloc-0123456789abcdef0\n\" | @base64)"

# --- 5. PG5: the group, backstop, hook, cluster, service, roles ---------------

asg='after("aws_autoscaling_group.ecs_spot_measurement[0]")'
expect_reject enable enable.json "not 0/0/1" "($asg.max_size) = 2"
expect_reject enable enable.json "not 0/0/1" "($asg.desired_capacity) = 1"
expect_reject enable enable.json "PG5 group has capacity rebalance" "($asg.capacity_rebalance) = true"
expect_reject enable enable.json "PG5 group carries AmazonECSManaged" "($asg.tag) += [{key: \"AmazonECSManaged\"}]"
expect_reject switch switch.json "not 0/0/1" "($asg.desired_capacity) = 1"
expect_reject enable enable.json "PG5 backstop" \
    'after("aws_autoscaling_schedule.ecs_spot_measurement_backstop[0]").recurrence = "30 16 * * 1-5"'
expect_reject enable enable.json "PG5 backstop" \
    'after("aws_autoscaling_schedule.ecs_spot_measurement_backstop[0]").max_size = 0'
expect_reject enable enable.json "PG5 lifecycle hook" \
    'after("aws_autoscaling_lifecycle_hook.ecs_spot_measurement_launching[0]").default_result = "CONTINUE"'
expect_reject enable enable.json "PG5 cluster" \
    'after("aws_ecs_cluster.measurement[0]").setting = [{name: "containerInsights", value: "enabled"}]'
expect_reject enable enable.json "PG5 log group" 'after("aws_cloudwatch_log_group.measurement[0]").name = "/ec-portfolio/demo/ecs/api"'
expect_reject enable enable.json "PG5 service" 'after("aws_ecs_service.measurement[0]").enable_execute_command = true'
expect_reject enable enable.json "PG5 role ec-portfolio-demo-ecs-spot-measure is not trusted by ec2.amazonaws.com alone" \
    'after("aws_iam_role.ecs_spot_measurement[0]").assume_role_policy |= (fromjson | .Statement[0].Principal.Service = ["ec2.amazonaws.com", "ssm.amazonaws.com"] | tojson)'
expect_reject enable enable.json "PG5 instance profile name" \
    'after("aws_iam_instance_profile.ecs_spot_measurement[0]").name = "ec-portfolio-demo-ecs-spot"'

# --- 6. PG5: the task definition ----------------------------------------------

td='after("aws_ecs_task_definition.measurement[0]").container_definitions'
expect_reject enable enable.json "PG5 container api logs outside the measurement log group" \
    "($td) |= (fromjson | map(if .name == \"api\" then .logConfiguration.options[\"awslogs-group\"] = \"/ec-portfolio/demo/ecs/api\" else . end) | tojson)"
expect_reject enable enable.json "PG5 measurement API image differs from the production API image" \
    "($td) |= (fromjson | map(if .name == \"api\" then .image = \"$ACCOUNT.dkr.ecr.ap-northeast-1.amazonaws.com/ec-portfolio-demo-api:0000000000000000000000000000000000000000\" else . end) | tojson)"
expect_reject enable enable.json "PG5 measurement API lacks the GC logging option" \
    "($td) |= (fromjson | map(if .name == \"api\" then .environment = [{name: \"JAVA_TOOL_OPTIONS\", value: \"-Djava.net.preferIPv4Stack=true\"}] else . end) | tojson)"
expect_reject enable enable.json "PG5 helper memory-probe" \
    "($td) |= (fromjson | map(if .name == \"memory-probe\" then .readonlyRootFilesystem = false else . end) | tojson)"
expect_reject enable enable.json "PG5 helper load-driver" \
    "($td) |= (fromjson | map(if .name == \"load-driver\" then .user = \"0:0\" else . end) | tojson)"
expect_reject enable enable.json "PG5 helper load-driver" \
    "($td) |= (fromjson | map(if .name == \"load-driver\" then .portMappings = [{containerPort: 8081, hostPort: 8081}] else . end) | tojson)"
expect_reject enable enable.json "PG5 container valkey is privileged" \
    "($td) |= (fromjson | map(if .name == \"valkey\" then .privileged = true else . end) | tojson)"
expect_reject enable enable.json "PG5 task definition containers" \
    "($td) |= (fromjson | . + [{name: \"shell\", logConfiguration: {options: {\"awslogs-group\": \"/ec-portfolio/demo/ecs/measure\"}}}] | tojson)"
expect_reject enable enable.json "PG5 load-driver does not wait" \
    "($td) |= (fromjson | map(if .name == \"load-driver\" then del(.dependsOn) else . end) | tojson)"
expect_reject enable enable.json "PG5 task definition has a task role" \
    'after("aws_ecs_task_definition.measurement[0]").task_role_arn = "arn:aws:iam::111122223333:role/x"'

# --- 7. PG5: the role policies ------------------------------------------------

expect_reject enable enable.json "PG5 aws_iam_role_policy.ecs_spot_measurement[0] differs from the reviewed document" \
    'after("aws_iam_role_policy.ecs_spot_measurement[0]").policy |= (fromjson | .Statement += [{Sid: "X", Effect: "Allow", Action: "ec2:AssociateAddress", Resource: "*"}] | tojson)'
expect_reject enable enable.json "PG5 aws_iam_role_policy.ecs_task_execution_measurement[0] differs from the reviewed document" \
    'after("aws_iam_role_policy.ecs_task_execution_measurement[0]").policy |= (fromjson | .Statement[0].Resource = "arn:aws:logs:ap-northeast-1:111122223333:log-group:/ec-portfolio/demo/ecs/api:log-stream:*" | tojson)'
expect_reject enable enable.json "PG5 measurement-host is unknown in the plan" \
    '(rc("aws_iam_role_policy.ecs_spot_measurement[0]").change) |= (.after_unknown = {policy: true} | .after.policy = null)'
expect_reject enable enable.json "PG5 policy name" 'after("aws_iam_role_policy.ecs_spot_measurement[0]").name = "measurement"'

# Without the reviewed documents an enable plan is not judged at all.
"$GATE" enable enable.json >gate.out 2>&1 && fail "enable without reviewed documents must fail" || true
grep -q "enable needs --reviewed-host-policy and --reviewed-exec-policy" gate.out || fail "enable without documents: $(cat gate.out)"

# --- 8. PG4: drift, one attribute at a time -----------------------------------

# Every mutant keeps the whole cutover allowance: the drift itself must fail.
eip='.resource_drift[0].change'

# Any other attribute of the origin Elastic IP fails, named, in every mode.
expect_reject merge merge-drift.json "PG4 drift not allowed: aws_eip.ec2_origin tags" \
    "$eip.after.tags.Name = \"ec-portfolio-demo-ec2-origin-renamed\"" "${cutover_allowance[@]}"
expect_reject merge merge-drift.json "PG4 drift not allowed: aws_eip.ec2_origin tags" \
    "$eip.after.tags.Owner = \"someone-else\"" "${cutover_allowance[@]}"
expect_reject merge merge-drift.json "PG4 drift not allowed: aws_eip.ec2_origin tags_all" \
    "$eip.after.tags_all |= del(.Environment)" "${cutover_allowance[@]}"
expect_reject merge merge-drift.json "PG4 drift not allowed: aws_eip.ec2_origin domain" \
    "$eip.after.domain = \"standard\"" "${cutover_allowance[@]}"
for attribute in allocation_id id public_ip public_dns network_border_group public_ipv4_pool; do
    expect_reject merge merge-drift.json "PG4 drift not allowed: aws_eip.ec2_origin $attribute" \
        "$eip.after.$attribute += \"-changed\"" "${cutover_allowance[@]}"
done
expect_reject enable enable-drift.json "PG4 drift not allowed: aws_eip.ec2_origin tags" \
    "$eip.after.tags = {}" "${cutover_allowance[@]}"
expect_reject switch switch-drift.json "PG4 drift not allowed: aws_eip.ec2_origin public_ip" \
    "$eip.after.public_ip = \"198.51.100.20\"" "${cutover_allowance[@]}"
expect_reject teardown teardown-drift.json "PG4 drift not allowed: aws_eip.ec2_origin domain" \
    "$eip.after.domain = \"standard\"" "${cutover_allowance[@]}"

# An attribute that appears or disappears fails, allowed or not.
expect_reject merge merge-drift.json "PG4 drift of aws_eip.ec2_origin adds or removes customer_owned_ip" \
    "$eip.after.customer_owned_ip = \"198.51.100.30\"" "${cutover_allowance[@]}"
expect_reject merge merge-drift.json "PG4 drift of aws_eip.ec2_origin adds or removes tags" \
    "$eip.after |= del(.tags)" "${cutover_allowance[@]}"
expect_reject merge merge-drift.json "PG4 drift of aws_eip.ec2_origin adds or removes private_dns" \
    "$eip.after |= del(.private_dns)" "${cutover_allowance[@]}"
expect_reject merge merge-drift.json "PG4 drift of aws_eip.ec2_origin adds or removes instance" \
    "$eip.before |= del(.instance)" "${cutover_allowance[@]}"

# Only an update of known values is read: a delete outside Terraform, any other
# action, a missing or malformed change, unknown values, a data source and an
# update without a difference fail.
expect_reject merge merge-drift.json "PG4 drift of aws_eip.ec2_origin is not an update" \
    "$eip |= (.actions = [\"delete\"] | .after = null)" "${cutover_allowance[@]}"
for actions in '["delete", "create"]' '["create"]' '["no-op"]' '[]'; do
    expect_reject merge merge-drift.json "PG4 drift of aws_eip.ec2_origin is not an update" \
        "$eip.actions = $actions" "${cutover_allowance[@]}"
done
expect_reject merge merge-drift.json "PG4 drift of aws_eip.ec2_origin is not an update" \
    "$eip |= del(.actions)" "${cutover_allowance[@]}"
expect_reject merge merge-drift.json "PG4 drift of aws_eip.ec2_origin is not an update" \
    '.resource_drift[0] |= del(.change)' "${cutover_allowance[@]}"
expect_reject merge merge-drift.json "PG4 drift of aws_eip.ec2_origin is not an update" \
    '.resource_drift[0].change = "update"' "${cutover_allowance[@]}"
for side in before after; do
    expect_reject merge merge-drift.json "PG4 drift of aws_eip.ec2_origin has no object before and after" \
        "$eip.$side = null" "${cutover_allowance[@]}"
done
expect_reject merge merge-drift.json "PG4 drift of aws_eip.ec2_origin has no object before and after" \
    "$eip.after = \"203.0.113.10\"" "${cutover_allowance[@]}"
for unknown in '{instance: true}' '{tags: {Name: true}}' '{tags_all: [false, {Owner: true}]}' 'true'; do
    expect_reject merge merge-drift.json "PG4 drift of aws_eip.ec2_origin has unknown values" \
        "$eip.after_unknown = $unknown" "${cutover_allowance[@]}"
done
expect_reject merge merge-drift.json "PG4 drift of aws_eip.ec2_origin has an unreadable after_unknown" \
    "$eip.after_unknown = \"instance\"" "${cutover_allowance[@]}"
expect_reject merge merge-drift.json "PG4 drift of aws_eip.ec2_origin is not a managed resource" \
    '.resource_drift[0].mode = "data"' "${cutover_allowance[@]}"
expect_reject merge merge-drift.json "PG4 drift of aws_eip.ec2_origin is not a managed resource" \
    '.resource_drift[0] |= del(.mode)' "${cutover_allowance[@]}"
expect_reject merge merge-drift.json "PG4 drift of aws_eip.ec2_origin changes no attribute" \
    "$eip.after = $eip.before" "${cutover_allowance[@]}"

# Each entry is judged on its own: a second entry for the address cannot hide a
# forbidden change, after or before an allowed one, and is refused itself.
expect_reject merge merge-drift.json "PG4 drift not allowed: aws_eip.ec2_origin tags" \
    ".resource_drift += [.resource_drift[0] | .change.after.tags.Name = \"renamed\"]" "${cutover_allowance[@]}"
expect_reject merge merge-drift.json "PG4 drift not allowed: aws_eip.ec2_origin tags" \
    ".resource_drift = [.resource_drift[0] | .change.after.tags.Name = \"renamed\"] + .resource_drift" "${cutover_allowance[@]}"
expect_reject merge merge-drift.json "PG4 drift of aws_eip.ec2_origin is listed more than once" \
    '.resource_drift += .resource_drift' "${cutover_allowance[@]}"

# Drift of any other address fails whatever is allowed for the Elastic IP, and
# so does a drift list or entry the gate cannot read.
expect_reject merge merge-drift.json "PG4 drift not allowed: aws_route53_record.origin_demo" \
    '.resource_drift += [{address: "aws_route53_record.origin_demo", mode: "managed", change: {actions: ["update"],
        before: {records: ["203.0.113.10"]}, after: {records: ["198.51.100.20"]}, after_unknown: {}}}]' "${cutover_allowance[@]}"
expect_reject merge merge-drift.json "PG4 drift not allowed: aws_instance.demo" \
    '.resource_drift += [{address: "aws_instance.demo", mode: "managed", change: {actions: ["update"],
        before: {instance_state: "running"}, after: {instance_state: "stopped"}, after_unknown: {}}}]' "${cutover_allowance[@]}"
expect_reject merge merge-drift.json "PG4 drift not allowed: aws_autoscaling_group.ecs_spot_measurement[0]" \
    '.resource_drift += [{address: "aws_autoscaling_group.ecs_spot_measurement[0]", mode: "managed", change: {actions: ["update"],
        before: {desired_capacity: 0}, after: {desired_capacity: 1}, after_unknown: {}}}]' "${cutover_allowance[@]}"
expect_reject merge merge-drift.json "PG4 drift not allowed: aws_eip.ec2_origin[0]" \
    '.resource_drift[0].address = "aws_eip.ec2_origin[0]"' "${cutover_allowance[@]}"
expect_reject merge merge-drift.json "PG4 resource drift is not a list" \
    '.resource_drift = {"aws_eip.ec2_origin": .resource_drift[0]}' "${cutover_allowance[@]}"
expect_reject merge merge-drift.json "PG4 drift entry without an address" \
    '.resource_drift[0] |= del(.address)' "${cutover_allowance[@]}"
expect_reject merge merge-drift.json "PG4 drift entry without an address" \
    '.resource_drift += ["aws_eip.ec2_origin"]' "${cutover_allowance[@]}"

# The allowance is checked before the plan is read, here on a plan without
# drift: the address-only form of earlier versions and malformed values, then
# anything beyond the five attributes of the origin Elastic IP, are refused,
# also next to a valid allowance.
for allowance in "" aws_eip.ec2_origin aws_eip.ec2_origin: :instance; do
    expect_fail merge merge.json "--allow-drift takes ADDRESS:ATTRIBUTE" --allow-drift "$allowance"
done
for allowance in aws_eip.ec2_origin:tags aws_eip.ec2_origin:tags_all aws_eip.ec2_origin:domain aws_eip.ec2_origin:public_ip \
    aws_eip.ec2_origin:Instance "aws_eip.ec2_origin:instance,tags" "aws_eip.ec2_origin:*" aws_eip.ec2_origin:instance:tags \
    "aws_eip.ec2_origin[0]:instance" aws_route53_record.origin_demo:records aws_instance.demo:instance_state; do
    expect_fail merge merge.json "is outside the drift that may be allowed" --allow-drift "$allowance"
done
expect_fail merge merge-drift.json "is outside the drift that may be allowed" \
    "${cutover_allowance[@]}" --allow-drift aws_eip.ec2_origin:tags

printf '[measurement-plan-gate-test] PASS (4 modes, %d mutants rejected, %d runs refused for their drift allowance)\n' \
    "$mutants" "$refused"
