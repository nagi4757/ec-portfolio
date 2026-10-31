#!/usr/bin/env python3
"""Fail-closed offline gate for the P3-a saved plan of the cold standby.

It reads `terraform show -json <saved plan>` and accepts it only when the plan
creates exactly the 25 reviewed resources, inert, with the values the reviewed
HCL/ASL/SSM source renders to, and leaves every existing resource, output and
drift observation as it is. Every new schedule and rule must be DISABLED even
if the source said otherwise.

AWS provider 6.62.0 plans a few Optional+Computed settings it is not given as
unknown. Only the exact addresses and attributes of PROVIDER_COMPUTED_UNKNOWN
may be unknown, and only when the attribute is unknown as a whole, has no
planned value and is absent from the configuration; their final values are
read back after the apply.

The plan JSON must be `terraform show -json` of the saved plan it is given
with, and the Demo root must be committed; the result records both digests,
the approved account digest and the source commit. Right before the separately
approved apply, `verify` checks that the file to apply is still the reviewed
one and the checkout is still the reviewed commit. Terraform itself refuses a
saved plan whose state changed after the plan.

It makes no AWS call and runs no Terraform plan or apply. Its subprocesses are
a provider-free `terraform console` render, `terraform show -json` of the given
saved plan without AWS variables, and read-only `git rev-parse` / `git status`.
"""
import base64
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("p3a_export", HERE / "cold-standby-plan-export.py")
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)
ADDRESSES = json.loads((HERE / "cold-standby-plan-addresses.json").read_text())
NEW = set(ADDRESSES["P3A_ADDRESSES"])
EXISTING = set(ADDRESSES["EXISTING_ADDRESSES"])
DRIFT = ADDRESSES["DRIFT_ALLOWLIST"]
COMPUTED_UNKNOWN = ADDRESSES["PROVIDER_COMPUTED_UNKNOWN"]
# P3-a creates the control plane inert whatever the source says: a schedule or
# rule that the reviewed source itself switched on still fails the gate.
INERT_TYPES = ("aws_scheduler_schedule", "aws_cloudwatch_event_rule")
DEMO_PATH = "infra/terraform/demo"
# P3-a2: the one change between P3-a and the rehearsals. A host stops moving the
# origin Elastic IP to itself and the group stops replacing on a rebalance
# recommendation; every other resource and output stays as it is.
P3A2_TEMPLATE = "aws_launch_template.ecs_spot"
P3A2_GROUP = "aws_autoscaling_group.ecs_spot"
P3A2_POLICY = "aws_iam_role_policy.ecs_spot_origin_eip_promotion"
P3A2_CHANGED = {P3A2_TEMPLATE, P3A2_GROUP, P3A2_POLICY}
P3A2_OUTPUT = "ecs_spot_launch_template_version"
P3A2_VERSION = 4
P3A2_ALLOCATION_LINE = "readonly EIP_ALLOCATION_ID_VALUE="
USAGE = ("usage: cold-standby-plan-gate.sh p3a <saved.tfplan> <plan.json> <approved-account-sha256>\n"
         "       cold-standby-plan-gate.sh p3a2 <saved.tfplan> <plan.json> <approved-account-sha256>\n"
         "       cold-standby-plan-gate.sh verify <saved.tfplan> <saved-plan-sha256> <source-commit>")


class Rejected(Exception):
    pass


def check(value, code):
    if not value:
        raise Rejected(code)


def strict_json(text):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            check(key not in result, "PG0 duplicate JSON key")
            result[key] = value
        return result
    return json.loads(text, object_pairs_hook=unique)


def load(path):
    return strict_json(Path(path).read_text())


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def resources(module):
    check(isinstance(module, dict), "PG0 missing module")
    result = list(module.get("resources", []))
    for child in module.get("child_modules", []):
        result += resources(child)
    return result


def indexed(items, code):
    result = {}
    for item in items:
        check(isinstance(item, dict) and isinstance(item.get("address"), str), code)
        check(item["address"] not in result, code + " duplicate address")
        result[item["address"]] = item
    return result


def context_from_plan(plan, approved_account_sha):
    prior = indexed(resources(plan["prior_state"]["values"]["root_module"]), "PG0 prior resources")
    scheduler = prior.get("aws_iam_role.scheduler", {}).get("values", {}).get("arn", "")
    match = re.fullmatch(r"arn:aws:iam::([0-9]{12}):role/ec-portfolio-demo-scheduler", scheduler)
    check(match, "PG0 account/scheduler identity")
    account = match[1]
    # The reviewer passes the SHA-256 of the 12-digit Demo account, so the
    # account ID itself never has to be written into the repository.
    check(re.fullmatch(r"[0-9a-f]{64}", approved_account_sha or "") and hashlib.sha256(account.encode()).hexdigest() == approved_account_sha, "PG0 unapproved account")
    prior_caller = prior.get("data.aws_caller_identity.current", {})
    check(prior_caller.get("mode") == "data" and prior_caller.get("values", {}).get("account_id") == account,
          "PG0 refreshed caller account mismatch")
    planned = indexed(resources(plan.get("planned_values", {}).get("root_module", {})), "PG0 planned identity")
    caller = planned.get("data.aws_caller_identity.current", {})
    check(not caller or (caller.get("mode") == "data" and caller.get("values", {}).get("account_id") == account), "PG0 planned caller account mismatch")
    configuration = indexed(plan.get("configuration", {}).get("root_module", {}).get("resources", []), "PG0 identity configuration")
    check(configuration.get("data.aws_caller_identity.current", {}).get("provider_config_key") == "aws",
          "PG0 caller provider binding")
    provider_identity_config(plan)
    context = {"data": {"aws_partition": {"current": {"partition": "aws"}}, "aws_caller_identity": {"current": {"account_id": account}}}}
    needed = exporter.fixture_context(account)
    for resource_type, names in needed.items():
        if resource_type == "data":
            continue
        for name, attrs in names.items():
            address = resource_type + "." + name
            value = prior.get(address, {}).get("values", {})
            check(all(key in value and isinstance(value[key], str) and value[key] for key in attrs), "PG0 context missing " + address)
            context.setdefault(resource_type, {})[name] = {key: value[key] for key in attrs}
    c = context
    instance = c["aws_instance"]["demo"]
    check(re.fullmatch(r"i-[0-9a-f]{17}", instance["id"]) and instance["arn"] == "arn:aws:ec2:ap-northeast-1:" + account + ":instance/" + instance["id"], "PG0 instance context")
    check(re.fullmatch(r"eni-[0-9a-f]{17}", instance["primary_network_interface_id"]), "PG0 ENI context")
    check(re.fullmatch(r"eipalloc-[0-9a-f]{17}", c["aws_eip"]["ec2_origin"]["allocation_id"]), "PG0 EIP context")
    # Every identity/ARN comes from prior state, with a fixed production scope.
    reference = exporter.fixture_context(account)
    for resource_type, name, attr in (("aws_ecs_cluster", "demo", "arn"), ("aws_ecs_service", "api", "name"),
                                      ("aws_ecs_service", "api", "id"), ("aws_iam_instance_profile", "ecs_spot", "arn"),
                                      ("aws_iam_instance_profile", "ec2", "arn"), ("aws_ecr_repository", "demo_api", "repository_url"),
                                      ("aws_scheduler_schedule_group", "runtime", "name"), ("aws_sns_topic", "alerts", "arn"),
                                      ("aws_ssm_parameter", "deploy_desired_image_sha", "name"), ("aws_ssm_parameter", "deploy_desired_image_sha", "arn")):
        check(c[resource_type][name][attr] == reference[resource_type][name][attr], "PG0 scope " + resource_type + "." + name)
    db = c["aws_db_instance"]["demo"]
    check(db["identifier"] == "ec-portfolio-demo-mariadb" and db["arn"] == "arn:aws:rds:ap-northeast-1:" + account + ":db:" + db["identifier"], "PG0 database scope")
    asg = c["aws_autoscaling_group"]["ecs_spot"]
    check(asg["name"] == "ec-portfolio-demo-ecs-spot" and re.fullmatch(r"arn:aws:autoscaling:ap-northeast-1:" + account + r":autoScalingGroup:[0-9a-f-]{36}:autoScalingGroupName/ec-portfolio-demo-ecs-spot", asg["arn"]), "PG0 ASG scope")
    check(re.fullmatch(r"d[a-z0-9]{1,62}\.cloudfront\.net", c["aws_cloudfront_distribution"]["api"]["domain_name"]), "PG0 CloudFront context")
    return context


def provider_identity_config(plan):
    providers = plan.get("configuration", {}).get("provider_config", {})
    aws = providers.get("aws", {})
    check(aws.get("full_name") == "registry.terraform.io/hashicorp/aws" and
          set(aws.get("expressions", {})) == {"region", "default_tags"} and
          aws["expressions"]["region"] == {"references": ["local.aws_region"]} and
          not any(key.startswith("aws.") for key in providers), "PG0 provider credential override")


def stamp(text):
    check(isinstance(text, str) and text.endswith("Z"), "PG4 plan time")
    return datetime.datetime.fromisoformat(text[:-1] + "+00:00").timestamp()


def config_check(specification, actual, expected, label):
    if isinstance(specification, list):
        check(isinstance(actual, list) and len(actual) == len(specification), "PG5 configuration block " + label)
        for i, child in enumerate(specification):
            config_check(child, actual[i], expected[i], label + "/" + str(i))
    elif isinstance(specification, dict) and set(specification) == {"refs"}:
        check(isinstance(actual, dict), "PG5 configuration expression " + label)
        wanted = specification["refs"]
        if wanted:
            check(set(actual) == {"references"} and exporter.canonical_refs(actual["references"]) == wanted, "PG5 configuration references " + label)
        else:
            check(set(actual) == {"constant_value"} and actual["constant_value"] == expected, "PG5 configuration constant " + label)
    else:
        check(isinstance(actual, dict) and set(actual) == set(specification), "PG5 configuration attributes " + label)
        for key in specification:
            config_check(specification[key], actual[key], expected[key], label + "/" + key)


def values_check(expected, actual, unknown, specification, label):
    if unknown is True:
        allowed = label.endswith(("/arn", "/role_arn", "/role")) and isinstance(specification, dict) and "refs" in specification and any(re.match(r"aws_(?:iam_role|sfn_state_machine)\.runtime", ref) for ref in specification["refs"])
        check(allowed and actual is None, "PG5 unverifiable unknown " + label)
        return
    if isinstance(specification, dict) and set(specification) == {"refs"} and isinstance(expected, (dict, list)):
        check(not unknown and actual == expected, "PG5 reviewed source collection " + label)
        return
    if isinstance(expected, dict):
        check(isinstance(actual, dict), "PG5 value object " + label)
        for key, value in expected.items():
            values_check(value, actual.get(key), (unknown or {}).get(key, False), specification[key], label + "/" + key)
    elif isinstance(expected, list):
        check(isinstance(actual, list) and len(actual) == len(expected), "PG5 value list " + label)
        for i, value in enumerate(expected):
            values_check(value, actual[i], unknown[i] if isinstance(unknown, list) and i < len(unknown) else False,
                         specification[i] if isinstance(specification, list) else specification, label + "/" + str(i))
    else:
        check(not unknown, "PG5 unknown configured value " + label)
        if label.endswith(("/policy", "/assume_role_policy", "/definition", "/event_pattern", "/input")):
            try:
                check(isinstance(actual, str) and strict_json(actual) == strict_json(expected), "PG5 reviewed JSON content " + label)
            except (ValueError, TypeError):
                raise Rejected("PG5 invalid JSON content " + label)
        else:
            check(actual == expected, "PG5 reviewed source value " + label)


def normalize_unknown(value, unknown):
    # HashiCorp JSON values representation may omit unknown leaves or encode
    # them as null. Only leaves explicitly marked unknown may be normalized.
    if unknown is True:
        check(value is None, "PG2 unknown leaf has concrete value")
        return "P3A_UNKNOWN_LEAF"
    if isinstance(value, dict):
        unknown = unknown if isinstance(unknown, dict) else {}
        return {key: normalize_unknown(value.get(key), unknown.get(key, False)) for key in set(value) | {k for k, v in unknown.items() if v}}
    if isinstance(value, list):
        return [normalize_unknown(v, unknown[i] if isinstance(unknown, list) and i < len(unknown) else False) for i, v in enumerate(value)]
    return value


def changed_leaves(before, after, path=""):
    if isinstance(before, dict) and isinstance(after, dict):
        check(set(before) == set(after), "PG4 drift object keys")
        return [item for key in sorted(before) for item in changed_leaves(before[key], after[key], path + "/" + key)]
    if isinstance(before, list) and isinstance(after, list) and len(before) == len(after):
        return [item for i, (a, b) in enumerate(zip(before, after)) for item in changed_leaves(a, b, path + "/" + str(i))]
    return [] if type(before) is type(after) and before == after else [(path, before, after)]


def computed_unknown(base_address, change, configuration_resource, key):
    """True when `key` of a new resource is planned unknown as a provider-computed
    setting the reviewed source leaves unset: the exact address and attribute
    are listed, the whole attribute is unknown, it has no planned value, and the
    configuration does not set it. Any other unknown of a checked attribute is
    rejected; False when it is not unknown at all."""
    unknown = change.get("after_unknown", {}).get(key, False)
    if not unknown:
        return False
    label = base_address + "/" + key
    check(key in COMPUTED_UNKNOWN.get(base_address, ()), "PG5 unexpected unknown " + label)
    check(unknown is True, "PG5 partially unknown computed setting " + label)
    check(change.get("after", {}).get(key) in (None, []), "PG5 computed setting with a planned value " + label)
    check(key not in (configuration_resource.get("expressions") or {}), "PG5 computed setting configured " + label)
    return True


def drift_check(plan):
    prior = indexed(resources(plan.get("prior_state", {}).get("values", {}).get("root_module", {})), "PG4 prior")
    changes = indexed(plan.get("resource_changes", []), "PG4 changes")
    drifts = indexed(plan.get("resource_drift", []), "PG4 duplicate drift")
    rules = ADDRESSES["MEASUREMENT_DRIFT_RULES"]
    for address, drift in drifts.items():
        check(address in DRIFT and address not in NEW, "PG4 unexpected drift")
        change = drift.get("change", {})
        check(change.get("actions") == ["update"] and not change.get("after_unknown") and
              not change.get("importing") and not drift.get("previous_address"), "PG4 drift action/unknown")
        before, after = change.get("before"), change.get("after")
        check(isinstance(before, dict) and isinstance(after, dict), "PG4 drift shape")
        check(prior.get(address, {}).get("values") == after and
              changes.get(address, {}).get("change", {}).get("actions") == ["no-op"] and
              changes[address]["change"].get("before") == changes[address]["change"].get("after") == after,
              "PG4 drift refreshed no-op binding")
        leaves = changed_leaves(before, after)
        check(bool(leaves), "PG4 empty drift")
        changed = {key for key in set(before) | set(after) if before.get(key) != after.get(key)}
        check(changed <= set(DRIFT[address]), "PG4 unexpected drift fields")
        rule = rules.get(address)
        if not rule:
            # Preserve the existing OD/RDS/EIP field boundary. New resources
            # and every unlisted field remain rejected, including all IAM.
            continue
        if "null_to_empty" in rule:
            check(all(path in rule["null_to_empty"] and a is None and b == [] for path, a, b in leaves), "PG4 exact null-to-empty normalization")
        elif "observed_inline_policy" in rule:
            check(changed == {"inline_policy"} and before["inline_policy"] == [] and
                  isinstance(after["inline_policy"], list) and len(after["inline_policy"]) == 1 and
                  isinstance(after["inline_policy"][0], dict), "PG4 inline observation shape")
            observation = after["inline_policy"][0]
            policy_address = rule["observed_inline_policy"]
            policy = prior.get(policy_address, {}).get("values", {})
            policy_change = changes.get(policy_address, {}).get("change", {})
            check(set(observation) == {"name", "policy"} and observation["name"] == policy.get("name") == rule["policy_name"] and
                  policy.get("role") == after.get("name") and
                  policy_change.get("actions") == ["no-op"] and policy_change.get("before") == policy_change.get("after") == policy,
                  "PG4 inline separate-policy binding")
            check(strict_json(observation["policy"]) == strict_json(policy["policy"]), "PG4 inline policy content")
            config = indexed(plan.get("configuration", {}).get("root_module", {}).get("resources", []), "PG4 config")
            check("inline_policy" not in config.get(address.split("[")[0], {}).get("expressions", {}), "PG4 configured inline policy")
        else:
            check(changed == {"start_time"} and all(after.get(k) == rule[k] for k in ("recurrence", "time_zone")) and
                  after.get("min_size") == 0 and after.get("max_size") == 1 and after.get("desired_capacity") == 0 and
                  after.get("end_time") is None, "PG4 backstop schedule contract")
            config = indexed(plan.get("configuration", {}).get("root_module", {}).get("resources", []), "PG4 config")
            expressions = config.get(address.split("[")[0], {}).get("expressions", {})
            check("start_time" not in expressions and "end_time" not in expressions and
                  expressions.get("recurrence") == {"constant_value": rule["recurrence"]} and
                  expressions.get("time_zone") == {"constant_value": rule["time_zone"]}, "PG4 backstop unconfigured time")
            timestamp = stamp(plan.get("timestamp"))
            old, new = stamp(before["start_time"]), stamp(after["start_time"])
            candidate = datetime.datetime.fromtimestamp(timestamp, datetime.timezone.utc).replace(minute=30, second=0, microsecond=0)
            while candidate.timestamp() <= timestamp or (candidate.hour + 9) % 24 not in (*range(12), *range(16, 24)):
                candidate += datetime.timedelta(hours=1)
            old_time = datetime.datetime.fromtimestamp(old, datetime.timezone.utc)
            check(old <= timestamp < new and new == candidate.timestamp() and old_time.minute == 30 and old_time.second == 0 and
                  old_time.microsecond == 0 and (old_time.hour + 9) % 24 in (*range(12), *range(16, 24)), "PG4 backstop next occurrence")


def plan_format_check(plan):
    check(plan.get("format_version") == "1.2" and plan.get("terraform_version") == "1.16.0", "PG0 plan format/version")
    check(plan.get("complete") is True, "PG0 incomplete plan")
    check(plan.get("errored") is False, "PG0 errored plan")
    check(plan.get("applyable") is True, "PG0 non-applyable plan")


def validate(plan, rendered):
    plan_format_check(plan)
    changes = indexed(plan.get("resource_changes", []), "PG1 changes")
    managed = {address: value for address, value in changes.items() if value.get("mode") == "managed"}
    creates = {address for address, value in managed.items() if value.get("change", {}).get("actions") != ["no-op"]}
    check(creates == NEW and len(NEW) == 25, "PG1 exact 25 creates")
    for address in NEW:
        check(managed[address]["change"]["actions"] == ["create"] and managed[address]["change"].get("before") is None, "PG1 replace/delete/update")
        check(not managed[address]["change"].get("importing") and not managed[address].get("previous_address"), "PG1 import/move")
    prior = indexed(resources(plan.get("prior_state", {}).get("values", {}).get("root_module", {})), "PG2 prior")
    prior_managed = {address: value for address, value in prior.items() if value.get("mode") == "managed"}
    check(EXISTING <= set(prior_managed), "PG2 wrong/incomplete root")
    check(set(managed) == set(prior_managed) | NEW, "PG2 all prior resources represented")
    for address, resource in prior_managed.items():
        change = managed[address]["change"]
        check(change.get("actions") == ["no-op"] and change.get("before") == change.get("after") == resource.get("values"), "PG2 existing changed " + address)
        check(not change.get("after_unknown") and not managed[address].get("previous_address") and not change.get("importing"), "PG2 existing unknown/moved")
    planned = indexed(resources(plan.get("planned_values", {}).get("root_module", {})), "PG2 planned")
    check({a for a, r in planned.items() if r.get("mode") == "managed"} == set(managed), "PG2 planned resource coverage")
    for address, resource in managed.items():
        unknown = resource["change"].get("after_unknown", {})
        check(normalize_unknown(planned[address].get("values"), unknown) == normalize_unknown(resource["change"].get("after"), unknown), "PG2 planned value inconsistency")
    outputs = plan.get("output_changes")
    check(isinstance(outputs, dict) and all(value.get("actions") == ["no-op"] and value.get("before") == value.get("after") and not value.get("after_unknown") for value in outputs.values()), "PG3 output changed")
    check(plan.get("planned_values", {}).get("outputs", {}) == plan.get("prior_state", {}).get("values", {}).get("outputs", {}), "PG3 output snapshot changed")
    drift_check(plan)
    check(set(rendered["resources"]) == NEW, "PG5 actual source resource count")
    configuration = indexed(plan.get("configuration", {}).get("root_module", {}).get("resources", []), "PG5 configuration")
    for address, expected in rendered["resources"].items():
        base_address = address.split("[")[0]
        configuration_resource = configuration.get(base_address, {})
        config_check(rendered["expressions"][base_address], configuration_resource.get("expressions"), expected, address)
        check(configuration_resource.get("provider_config_key") == "aws" and configuration_resource.get("mode") == "managed", "PG5 configuration provider/mode")
        if "[" in address:
            for_each = "local.runtime_workflows" if base_address == "aws_sfn_state_machine.runtime" else "local.runtime_orchestration_schedules"
            check(exporter.canonical_refs(configuration_resource.get("for_each_expression", {}).get("references", [])) == [for_each] and "count_expression" not in configuration_resource, "PG5 for_each mapping")
        change = managed[address]["change"]
        values_check(expected, change.get("after"), change.get("after_unknown", {}), rendered["expressions"][base_address], address)
        actual = change["after"]
        if base_address.split(".")[0] in INERT_TYPES:
            check(actual.get("state") == "DISABLED" and expected.get("state") == "DISABLED" and
                  not change.get("after_unknown", {}).get("state"), "PG5 new schedule/rule not DISABLED")
        if base_address.startswith("aws_iam_role."):
            # AWS provider 6.62.0 schema: managed_policy_arns alone is
            # Optional+Computed. A new role without that source attribute can
            # legitimately expose an unknown observational attachment set.
            # Exact configuration matching above proves it is unconfigured.
            # Inline policies and boundaries have no such computed exemption.
            managed_policies = actual.get("managed_policy_arns")
            managed_unknown = change.get("after_unknown", {}).get("managed_policy_arns", False)
            computed_observation = managed_policies is None and managed_unknown is True
            no_managed_grant = (managed_policies is None or managed_policies == []) and (not managed_unknown or computed_observation)
            # inline_policy is Optional+Computed too; it may be unknown only as
            # computed_unknown allows, and never carry a planned policy.
            check(no_managed_grant and not any(actual.get(k) or (change.get("after_unknown", {}).get(k) and not computed_unknown(base_address, change, configuration_resource, k))
                                               for k in ("inline_policy", "permissions_boundary", "force_detach_policies")), "PG5 role extra permissions")
        if base_address == "aws_sfn_state_machine.runtime":
            logging = actual.get("logging_configuration") or []
            tracing = actual.get("tracing_configuration") or []
            logging_off = logging == [] or (isinstance(logging, list) and len(logging) == 1 and logging[0].get("level") == "OFF" and logging[0].get("include_execution_data") is False and not logging[0].get("log_destination") and set(logging[0]) <= {"level", "include_execution_data", "log_destination"})
            tracing_off = tracing == [] or (isinstance(tracing, list) and len(tracing) == 1 and tracing[0] == {"enabled": False})
            encryption = actual.get("encryption_configuration") or []
            encryption_default = encryption == [] or (isinstance(encryption, list) and len(encryption) == 1 and encryption[0].get("type") == "AWS_OWNED_KEY" and not encryption[0].get("kms_key_id") and not encryption[0].get("kms_data_key_reuse_period_seconds") and set(encryption[0]) <= {"type", "kms_key_id", "kms_data_key_reuse_period_seconds"})
            check(not actual.get("publish") and not actual.get("version_description") and logging_off and tracing_off and encryption_default and
                  not any(change.get("after_unknown", {}).get(k) and not computed_unknown(base_address, change, configuration_resource, k)
                          for k in ("publish", "version_description", "logging_configuration", "tracing_configuration", "encryption_configuration")), "PG5 SM logging/tracing/version")
        if base_address == "aws_dynamodb_table.runtime_control":
            pitr = actual.get("point_in_time_recovery") or []
            pitr_off = pitr == [] or (isinstance(pitr, list) and len(pitr) == 1 and pitr[0].get("enabled") is False and pitr[0].get("recovery_period_in_days", 35) == 35 and set(pitr[0]) <= {"enabled", "recovery_period_in_days"})
            check(pitr_off and not any(actual.get(key) or (change.get("after_unknown", {}).get(key) and not computed_unknown(base_address, change, configuration_resource, key))
                                       for key in ("stream_enabled", "replica", "global_secondary_index", "local_secondary_index")) and
                  not (change.get("after_unknown", {}).get("point_in_time_recovery") and not computed_unknown(base_address, change, configuration_resource, "point_in_time_recovery")), "PG5 table extras")
        if base_address.startswith("aws_ssm_document."):
            check(not actual.get("permissions") and not change.get("after_unknown", {}).get("permissions"), "PG5 shared SSM document")
        if base_address.startswith("aws_cloudwatch_event_target."):
            check(not actual.get("dead_letter_config") and not actual.get("retry_policy"), "PG5 target extras")
    return {"result": "PASS", "mode": "p3a", "creates": 25, "changes": 0, "destroys": 0,
            "scope": "saved-plan gate only; apply still requires separate approval"}


def unknown_leaves(unknown, path=""):
    """The paths marked unknown. Terraform also writes empty structures here for
    nested blocks, and those say nothing about any value."""
    if unknown is True:
        return {path}
    if isinstance(unknown, dict):
        items = unknown.items()
    elif isinstance(unknown, list):
        items = enumerate(unknown)
    else:
        return set()
    return {leaf for key, child in items for leaf in unknown_leaves(child, path + "/" + str(key))}


def p3a2_update(managed, prior, address, unknown):
    resource = managed[address]
    change = resource["change"]
    check(change.get("actions") == ["update"], "P3A2 update action " + address)
    check(not change.get("importing") and not resource.get("previous_address"), "P3A2 update import/move " + address)
    check(change.get("before") == prior[address].get("values"), "P3A2 update not bound to refreshed state " + address)
    check(unknown_leaves(change.get("after_unknown")) == unknown, "P3A2 update unknown " + address)
    return change["before"], change["after"]


def p3a2_changed_keys(before, after):
    return {key for key in set(before) | set(after) if before.get(key) != after.get(key)}


def p3a2_user_data(before, after, allocation):
    """The rendered loader differs in the allocation line and nowhere else, so the
    pinned bundle version, its digest, the group and the hook cannot move with it."""
    old, new = [base64.b64decode(value, validate=True).decode().split("\n") for value in (before, after)]
    check(len(old) == len(new), "P3A2 loader line count")
    changed = [pair for pair in zip(old, new) if pair[0] != pair[1]]
    check(changed == [(P3A2_ALLOCATION_LINE + '"' + allocation + '"', P3A2_ALLOCATION_LINE + '""')], "P3A2 loader change")


def validate_p3a2(plan):
    plan_format_check(plan)
    changes = indexed(plan.get("resource_changes", []), "P3A2 changes")
    managed = {address: value for address, value in changes.items() if value.get("mode") == "managed"}
    changed = {address for address, value in managed.items() if value.get("change", {}).get("actions") != ["no-op"]}
    check(changed == P3A2_CHANGED, "P3A2 exact 2 updates and 1 delete")
    prior = indexed(resources(plan.get("prior_state", {}).get("values", {}).get("root_module", {})), "P3A2 prior")
    prior_managed = {address: value for address, value in prior.items() if value.get("mode") == "managed"}
    check(EXISTING | NEW <= set(prior_managed), "P3A2 wrong/incomplete root")
    check(set(managed) == set(prior_managed), "P3A2 all prior resources represented")
    for address, resource in prior_managed.items():
        if address in P3A2_CHANGED:
            continue
        change = managed[address]["change"]
        check(change.get("before") == change.get("after") == resource.get("values"), "P3A2 existing changed " + address)
        check(not change.get("after_unknown") and not managed[address].get("previous_address") and not change.get("importing"), "P3A2 existing unknown/moved")

    before, after = p3a2_update(managed, prior, P3A2_TEMPLATE, {"/latest_version"})
    check(p3a2_changed_keys(before, after) == {"user_data", "latest_version"}, "P3A2 template changed fields")
    check(before.get("latest_version") == P3A2_VERSION and after.get("latest_version") is None, "P3A2 template version")
    p3a2_user_data(before["user_data"], after["user_data"], prior["aws_eip.ec2_origin"]["values"]["allocation_id"])

    before, after = p3a2_update(managed, prior, P3A2_GROUP, {"/launch_template/0/version"})
    check(p3a2_changed_keys(before, after) == {"capacity_rebalance", "launch_template"}, "P3A2 group changed fields")
    check(before.get("capacity_rebalance") is True and after.get("capacity_rebalance") is False, "P3A2 capacity rebalance")
    check((after.get("min_size"), after.get("desired_capacity"), after.get("max_size")) == (0, 0, 2), "P3A2 group capacity")
    old, new = before["launch_template"], after["launch_template"]
    check(len(old) == len(new) == 1 and old[0].get("version") == str(P3A2_VERSION) and new[0].get("version") is None and
          {key: value for key, value in old[0].items() if key != "version"} == {key: value for key, value in new[0].items() if key != "version"},
          "P3A2 group template reference")

    policy = managed[P3A2_POLICY]
    change = policy["change"]
    check(change.get("actions") == ["delete"] and change.get("after") is None and policy.get("action_reason") == "delete_because_no_resource_config", "P3A2 policy delete")
    check(change.get("before") == prior[P3A2_POLICY].get("values") and change["before"].get("name") == "origin-eip-promotion" and
          change["before"].get("role") == "ec-portfolio-demo-ecs-spot", "P3A2 policy identity")
    configuration = indexed(plan.get("configuration", {}).get("root_module", {}).get("resources", []), "P3A2 configuration")
    check(P3A2_POLICY not in configuration, "P3A2 policy still configured")

    planned = indexed(resources(plan.get("planned_values", {}).get("root_module", {})), "P3A2 planned")
    check({a for a, r in planned.items() if r.get("mode") == "managed"} == set(managed) - {P3A2_POLICY}, "P3A2 planned resource coverage")
    for address, resource in planned.items():
        if resource.get("mode") == "managed":
            unknown = managed[address]["change"].get("after_unknown", {})
            check(normalize_unknown(resource.get("values"), unknown) == normalize_unknown(managed[address]["change"].get("after"), unknown), "P3A2 planned value inconsistency")

    outputs = plan.get("output_changes")
    version = outputs.get(P3A2_OUTPUT) if isinstance(outputs, dict) else None
    check(isinstance(version, dict) and version.get("actions") == ["update"] and version.get("before") == P3A2_VERSION and version.get("after_unknown") is True, "P3A2 version output")
    check(all(value.get("actions") == ["no-op"] and value.get("before") == value.get("after") and not value.get("after_unknown")
              for name, value in outputs.items() if name != P3A2_OUTPUT), "P3A2 output changed")
    others = lambda values: {name: value for name, value in values.items() if name != P3A2_OUTPUT}
    check(others(plan.get("planned_values", {}).get("outputs", {})) == others(plan.get("prior_state", {}).get("values", {}).get("outputs", {})), "P3A2 output snapshot changed")
    drift_check(plan)
    return {"result": "PASS", "mode": "p3a2", "creates": 0, "changes": 2, "destroys": 1,
            "scope": "saved-plan gate only; apply still requires separate approval"}


def regular_file(value, code):
    path = Path(value)
    check(path.is_file() and not path.is_symlink(), code)
    return path


def saved_plan_json(saved_plan):
    """`terraform show -json` of the saved plan, read in the initialized Demo directory.

    It only reads the plan file and the provider schemas; AWS variables are
    dropped so no credential is reachable from it.
    """
    environment = {key: value for key, value in os.environ.items() if not key.startswith("AWS_")}
    result = subprocess.run([exporter.TF_DEFAULT, "show", "-json", str(saved_plan)], cwd=exporter.DEMO, env=environment,
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
    check(result.returncode == 0, "PG0 terraform show of the saved plan failed")
    return strict_json(result.stdout.decode())


def source_commit():
    """The commit the plan was made from. The Demo root must have no uncommitted change."""
    def git(*arguments):
        result = subprocess.run(["git", "-C", str(exporter.ROOT), *arguments], stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        check(result.returncode == 0, "PG0 Git source state unreadable")
        return result.stdout.decode()
    commit = git("rev-parse", "HEAD").strip()
    check(re.fullmatch(r"[0-9a-f]{40}", commit), "PG0 source commit")
    check(git("status", "--porcelain=v1", "--untracked-files=all", "--", DEMO_PATH) == "", "PG0 uncommitted Demo source")
    return commit


def gate(saved_value, plan_value, approved_account_sha, mode="p3a"):
    saved = regular_file(saved_value, "PG0 saved plan is not a regular file")
    path = regular_file(plan_value, "PG0 plan JSON is not a regular file")
    saved_sha, plan_sha = sha(saved), sha(path)
    commit = source_commit()
    plan = load(path)
    check(saved_plan_json(saved) == plan, "PG0 plan JSON is not the saved plan")
    context = context_from_plan(plan, approved_account_sha)
    result = validate_p3a2(plan) if mode == "p3a2" else validate(plan, exporter.export(context))
    check(sha(saved) == saved_sha and sha(path) == plan_sha, "PG0 plan changed during the gate")
    check(source_commit() == commit, "PG0 source changed during the gate")
    result.update(saved_plan_sha256=saved_sha, plan_json_sha256=plan_sha, source_commit=commit,
                  approved_account_sha256=approved_account_sha, terraform_version=plan["terraform_version"],
                  next_step="before apply: cold-standby-plan-gate.sh verify <saved.tfplan> <saved_plan_sha256> <source_commit>")
    return result


def verify(saved_value, saved_sha, commit):
    """Run right before apply: the file to apply is the reviewed one, from the reviewed commit."""
    saved = regular_file(saved_value, "PG0 saved plan is not a regular file")
    check(re.fullmatch(r"[0-9a-f]{64}", saved_sha or "") and sha(saved) == saved_sha, "PG0 saved plan changed since review")
    check(re.fullmatch(r"[0-9a-f]{40}", commit or "") and source_commit() == commit, "PG0 source commit changed since review")
    return {"result": "VERIFIED", "saved_plan_sha256": saved_sha, "source_commit": commit,
            "scope": "the saved plan may now be applied; Terraform itself refuses it if the state changed since the plan"}


def main(argv):
    if len(argv) != 5 or argv[1] not in ("p3a", "p3a2", "verify"):
        print(USAGE, file=sys.stderr)
        return 2
    try:
        result = verify(*argv[2:]) if argv[1] == "verify" else gate(*argv[2:], mode=argv[1])
        print(json.dumps(result, sort_keys=True))
        return 0
    except (Rejected, ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as error:
        message = str(error) if isinstance(error, Rejected) else "NOT VERIFIED: missing/invalid plan or source evidence"
        print("[cold-standby-plan-gate] REJECT " + message, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
