#!/usr/bin/env python3
"""Real-source offline fixtures and guard mutations. All plan evidence is MOCK.

Only Terraform console is called, in a provider-free temporary directory. No
Terraform plan/init/apply, AWS client, backend, credentials or state is used.
"""
import ast
import base64
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


ORIGINAL = module("p3a_gate_test_subject", HERE / "cold-standby-plan-gate.py")
G = ORIGINAL
RENDERED = None
PLAN = None
FIXTURE_CHECKS = 0
ACCOUNT_SHA = hashlib.sha256(b"000000000000").hexdigest()


def cfg(specification, expected):
    if isinstance(specification, list):
        return [cfg(child, expected[i]) for i, child in enumerate(specification)]
    if set(specification) == {"refs"}:
        return {"references": specification["refs"]} if specification["refs"] else {"constant_value": expected}
    return {key: cfg(value, expected[key]) for key, value in specification.items()}


def make_plan(rendered):
    context = ORIGINAL.exporter.fixture_context()
    prior = {}
    for address in ORIGINAL.EXISTING:
        prior[address] = {"address": address, "mode": "managed", "type": address.split(".")[0], "values": {"MOCK": "existing immutable resource"}}
    for resource_type, names in context.items():
        if resource_type == "data":
            continue
        for name, attributes in names.items():
            address = resource_type + "." + name
            prior[address] = {"address": address, "mode": "managed", "type": resource_type, "values": attributes}
    changes = [{"address": address, "mode": "managed", "type": resource["type"], "change": {"actions": ["no-op"], "before": resource["values"], "after": resource["values"], "after_unknown": {}}} for address, resource in prior.items()]
    configuration = {}
    for address, values in rendered["resources"].items():
        base = address.split("[")[0]
        changes.append({"address": address, "mode": "managed", "type": address.split(".")[0], "change": {"actions": ["create"], "before": None, "after": values, "after_unknown": {}}})
        configuration[base] = {"address": base, "mode": "managed", "provider_config_key": "aws", "expressions": cfg(rendered["expressions"][base], values)}
        if "[" in address:
            configuration[base]["for_each_expression"] = {"references": ["local.runtime_workflows" if base == "aws_sfn_state_machine.runtime" else "local.runtime_orchestration_schedules"]}
    plan = {"MOCK": "OFFLINE FIXTURE NOT AN AWS PLAN", "format_version": "1.2", "terraform_version": "1.16.0", "complete": True, "errored": False, "applyable": True,
            "resource_changes": changes, "resource_drift": [], "output_changes": {},
            "prior_state": {"values": {"root_module": {"resources": list(prior.values())}, "outputs": {}}},
            "planned_values": {"root_module": {"resources": [{"address": r["address"], "mode": "managed", "type": r["type"], "values": r["change"]["after"]} for r in changes]}, "outputs": {}},
            "configuration": {"root_module": {"resources": list(configuration.values())}}}
    # Terraform 1.16 keeps already-read data in refreshed prior_state and may
    # omit it from planned_values and resource_changes entirely.
    plan["prior_state"]["values"]["root_module"]["resources"].append({"address": "data.aws_caller_identity.current", "mode": "data", "values": {"account_id": "000000000000"}})
    plan["configuration"]["root_module"]["resources"].append({"address": "data.aws_caller_identity.current", "mode": "data", "provider_config_key": "aws"})
    plan["configuration"]["provider_config"] = {"aws": {"full_name": "registry.terraform.io/hashicorp/aws", "expressions": {
        "region": {"references": ["local.aws_region"]}, "default_tags": [{"tags": {"references": ["local.common_tags"]}}]}}}
    plan["timestamp"] = "2026-10-21T00:00:01Z"
    return plan


def resource(plan, address):
    return next(r for r in plan["resource_changes"] if r["address"] == address)


def after(plan, address):
    return resource(plan, address)["change"]["after"]


def synchronize(plan):
    data = [r for r in plan["planned_values"]["root_module"]["resources"] if r.get("mode") == "data"]
    plan["planned_values"]["root_module"]["resources"] = [{"address": r["address"], "mode": r["mode"], "type": r["type"], "values": r["change"].get("after")} for r in plan["resource_changes"]] + data


def configuration(plan, address):
    return next(r for r in plan["configuration"]["root_module"]["resources"] if r["address"] == address)


def bind_refreshed(plan, address, values):
    for r in plan["prior_state"]["values"]["root_module"]["resources"]:
        if r["address"] == address:
            r["values"] = copy.deepcopy(values)
    resource(plan, address)["change"].update(before=copy.deepcopy(values), after=copy.deepcopy(values))
    if "planned_values" in plan:
        synchronize(plan)


# The after_unknown AWS provider 6.62.0 gave the 25 creates of the real P3-a
# saved plan (booleans only; no planned value of that plan is kept).
PROVIDER_SHAPE = json.loads((HERE / "fixtures/provider662-p3a-create-unknown.json").read_text())["after_unknown"]


def unknown_to_null(value, unknown):
    """The planned value as the provider leaves it: null wherever it is unknown."""
    if unknown is True:
        return None
    if isinstance(unknown, dict):
        value = dict(value) if isinstance(value, dict) else {}
        for key, child in unknown.items():
            if child is True or child not in ({}, [], False):
                value[key] = unknown_to_null(value.get(key), child)
        return value
    if isinstance(unknown, list) and isinstance(value, list):
        return [unknown_to_null(v, unknown[i]) if i < len(unknown) else v for i, v in enumerate(value)]
    return value


def provider_plan():
    """The fixture plan with the real provider's unknown structure on the 25 creates."""
    plan = copy.deepcopy(PLAN)
    for address, unknown in PROVIDER_SHAPE.items():
        change = resource(plan, address)["change"]
        change["after_unknown"] = copy.deepcopy(unknown)
        change["after"] = unknown_to_null(change["after"], unknown)
    synchronize(plan)
    return plan


class FixtureTests(unittest.TestCase):
    def reject(self, mutate, prefix=None, sync=True, context=False, base=None):
        global FIXTURE_CHECKS
        FIXTURE_CHECKS += 1
        plan = copy.deepcopy(PLAN if base is None else base)
        mutate(plan)
        if sync:
            synchronize(plan)
        try:
            (G.context_from_plan(plan, ACCOUNT_SHA) if context else G.validate(plan, RENDERED))
        except G.Rejected as error:
            if prefix:
                self.assertTrue(str(error).startswith(prefix), str(error))
        except (KeyError, TypeError, ValueError, IndexError, AttributeError):
            # Removing a redundant shape check may still reject in a later
            # parser/index operation. That is fail-closed, not a killed mutant.
            pass
        else:
            self.fail("invalid offline fixture accepted")

    def test_positive_real_hcl_console_render_and_fixed_addresses(self):
        self.assertEqual(len(RENDERED["resources"]), 25)
        self.assertEqual(set(RENDERED["resources"]), ORIGINAL.NEW)
        self.assertEqual(G.validate(copy.deepcopy(PLAN), RENDERED)["result"], "PASS")
        self.assertEqual(G.context_from_plan(PLAN, ACCOUNT_SHA), ORIGINAL.exporter.fixture_context())
        for address, values in RENDERED["resources"].items():
            if address.startswith("aws_sfn_state_machine"):
                definition = json.loads(values["definition"])
                self.assertEqual(definition["QueryLanguage"], "JSONata")
                self.assertNotIn("Draft.NotImplemented", values["definition"])
            if address.startswith(("aws_scheduler_schedule.", "aws_cloudwatch_event_rule.")):
                self.assertEqual(values["state"], "DISABLED")

    def test_pg0_complete_errored_applyable_format_version(self):
        for key, value in (("complete", False), ("errored", True), ("applyable", False), ("format_version", "unknown"), ("terraform_version", "0.0.0")):
            with self.subTest(key=key):
                self.reject(lambda p: p.update({key: value}), "PG0")

    def test_pg1_exact_create_set_and_no_replace_update_destroy_import_move(self):
        address = "aws_ssm_document.od_readiness"
        for actions in (["delete", "create"], ["create", "delete"], ["update"], ["delete"], ["no-op"]):
            self.reject(lambda p: resource(p, address)["change"].update(actions=actions), "PG1")
        self.reject(lambda p: p["resource_changes"].pop(), "PG1")
        self.reject(lambda p: p["resource_changes"].append({"address": "aws_lambda_function.evil", "mode": "managed", "type": "aws_lambda_function", "change": {"actions": ["create"], "before": None, "after": {}}}), "PG1")
        self.reject(lambda p: resource(p, address)["change"].update(before={"existing": True}), "PG1")
        self.reject(lambda p: resource(p, address)["change"].update(importing={"id": "MOCK"}), "PG1")
        self.reject(lambda p: resource(p, address).update(previous_address="aws_ssm_document.old"), "PG1")

    def test_duplicates_modes_and_all_existing_resources_present(self):
        self.reject(lambda p: p["resource_changes"].append(copy.deepcopy(p["resource_changes"][0])), "PG1")
        self.reject(lambda p: resource(p, "aws_ssm_document.od_readiness").update(mode="data"), "PG1")
        self.reject(lambda p: p["prior_state"]["values"]["root_module"]["resources"].pop(0), "PG2")
        self.reject(lambda p: p["resource_changes"].remove(resource(p, "aws_instance.demo")), "PG2")
        self.reject(lambda p: after(p, "aws_instance.demo").update(id="i-00000000000000002"), "PG2")
        self.reject(lambda p: resource(p, "aws_instance.demo")["change"].update(after_unknown={"id": True}), "PG2")
        self.reject(lambda p: resource(p, "aws_instance.demo").update(previous_address="aws_instance.old"), "PG2")
        def missing_from_both(p):
            address = "aws_budgets_budget.monthly_cost"
            p["prior_state"]["values"]["root_module"]["resources"] = [r for r in p["prior_state"]["values"]["root_module"]["resources"] if r["address"] != address]
            p["resource_changes"].remove(resource(p, address))
        self.reject(missing_from_both, "PG2")
        self.reject(lambda p: p["resource_changes"].append({"address": "aws_instance.extra", "mode": "managed", "type": "aws_instance", "change": {"actions": ["no-op"], "before": {}, "after": {}, "after_unknown": {}}}), "PG2")

    def test_pg2_planned_values_are_independent_consistent_snapshot(self):
        self.reject(lambda p: p["planned_values"]["root_module"]["resources"].pop(0), "PG2", sync=False)
        self.reject(lambda p: p["planned_values"]["root_module"]["resources"][0]["values"].update(MOCK="tampered"), "PG2", sync=False)
        self.reject(lambda p: p["planned_values"]["root_module"]["resources"].append({"address": "aws_instance.extra", "mode": "managed", "values": {}}), "PG2", sync=False)

    def test_pg3_outputs_unchanged_and_known(self):
        for change in ({"actions": ["update"], "before": 1, "after": 2}, {"actions": ["no-op"], "before": 1, "after": 2}, {"actions": ["no-op"], "before": 1, "after": 1, "after_unknown": True}):
            self.reject(lambda p: p.update(output_changes={"MOCK": change}), "PG3")
        self.reject(lambda p: p["planned_values"].update(outputs={"MOCK": {"value": "extra"}}), "PG3")

    def test_pg4_only_exact_drift_fields(self):
        plan = copy.deepcopy(PLAN)
        value = copy.deepcopy(after(plan, "aws_instance.demo"))
        plan["resource_drift"] = [{"address": "aws_instance.demo", "change": {"actions": ["update"], "before": dict(value, instance_state="running"), "after": dict(value, instance_state="stopped")}}]
        bind_refreshed(plan, "aws_instance.demo", dict(value, instance_state="stopped"))
        self.assertEqual(G.validate(plan, RENDERED)["result"], "PASS")
        self.reject(lambda p: p.update(resource_drift=[{"address": "aws_instance.unexpected", "change": {"before": {}, "after": {}}}]), "PG4")
        def bad_field(p):
            value = copy.deepcopy(after(p, "aws_instance.demo"))
            p["resource_drift"] = [{"address": "aws_instance.demo", "change": {"actions": ["update"], "before": dict(value, instance_type="t3a.medium"), "after": dict(value, instance_type="m7i.48xlarge")}}]
            bind_refreshed(p, "aws_instance.demo", dict(value, instance_type="m7i.48xlarge"))
        self.reject(bad_field, "PG4")

    def test_pg5_schedule_rule_table_document_content(self):
        cases = [("aws_scheduler_schedule.runtime_orchestration[\"day_open\"]", "state", "ENABLED"),
                 ("aws_scheduler_schedule.runtime_orchestration[\"day_close\"]", "schedule_expression", "cron(0 0 * * ? *)"),
                 ("aws_cloudwatch_event_rule.origin_guard_signals", "state", "ENABLED"),
                 ("aws_dynamodb_table.runtime_control", "deletion_protection_enabled", False),
                 ("aws_ssm_document.od_readiness", "document_type", "Automation"),
                 ("aws_ssm_document.spot_smoke", "content", "{}")]
        for address, key, value in cases:
            self.reject(lambda p: after(p, address).update({key: value}), "PG5")
        self.reject(lambda p: after(p, "aws_ssm_document.od_readiness").update(permissions={"type": "Share"}), "PG5")
        self.reject(lambda p: after(p, "aws_dynamodb_table.runtime_control").update(stream_enabled=True), "PG5")
        self.reject(lambda p: after(p, "aws_cloudwatch_event_target.spot_capacity_unavailable").update(dead_letter_config=[{"arn": "MOCK"}]), "PG5")
        self.reject(lambda p: after(p, "aws_iam_role.runtime_events")["tags"].update(Name="unreviewed"), "PG5")

    def test_pg5_real_asl_exactness_arming_write_fence_and_target_scope(self):
        for address in sorted(a for a in ORIGINAL.NEW if a.startswith("aws_sfn_state_machine")):
            def mutate(p):
                definition = json.loads(after(p, address)["definition"])
                definition["StartAt"] = "UnreviewedBypass"
                after(p, address)["definition"] = json.dumps(definition)
            self.reject(mutate, "PG5")
        self.reject(lambda p: after(p, "aws_sfn_state_machine.runtime[\"origin_guard\"]").update(role_arn="arn:aws:iam::000000000000:role/ec-portfolio-demo-runtime-orchestrator"), "PG5")
        self.reject(lambda p: after(p, "aws_sfn_state_machine.runtime[\"day_open\"]").update(publish=True), "PG5")
        self.reject(lambda p: after(p, "aws_sfn_state_machine.runtime[\"day_open\"]").update(logging_configuration=[{"level": "ALL"}]), "PG5")
        self.reject(lambda p: after(p, "aws_cloudwatch_event_target.origin_guard_signals_origin_guard").update(arn="arn:aws:states:ap-northeast-1:000000000000:stateMachine:unreviewed"), "PG5")

    def test_pg5_iam_json_exactness_no_wildcard_no_extra_resource_or_action(self):
        for address, key in (("aws_iam_role_policy.runtime_orchestrator", "policy"), ("aws_iam_role_policy.runtime_eip_writer", "policy"), ("aws_iam_role.runtime_events", "assume_role_policy")):
            def mutate(p):
                policy = json.loads(after(p, address)[key])
                policy["Statement"].append({"Effect": "Allow", "Action": "*", "Resource": "*"})
                after(p, address)[key] = json.dumps(policy)
            self.reject(mutate, "PG5")
        self.reject(lambda p: after(p, "aws_iam_role_policy.runtime_events").update(policy="not JSON"), "PG5")
        def duplicate_policy_key(p):
            policy = after(p, "aws_iam_role_policy.runtime_events")["policy"]
            after(p, "aws_iam_role_policy.runtime_events")["policy"] = '{"Statement":[{"Effect":"Allow","Action":"*","Resource":"*"}],' + policy[1:]
        self.reject(duplicate_policy_key, "PG0 duplicate JSON key")

    def test_pg5_configuration_refs_cannot_be_satisfied_by_unknown_flags(self):
        plan = copy.deepcopy(PLAN)
        address = "aws_sfn_state_machine.runtime[\"day_open\"]"
        after(plan, address)["role_arn"] = None
        resource(plan, address)["change"]["after_unknown"] = {"role_arn": True}
        synchronize(plan)
        self.assertEqual(G.validate(plan, RENDERED)["result"], "PASS")
        for value in ({"references": ["aws_iam_role.unreviewed.arn"]}, {"constant_value": "unreviewed"}):
            self.reject(lambda p: configuration(p, "aws_sfn_state_machine.runtime")["expressions"].update(role_arn=value), "PG5")
        self.reject(lambda p: configuration(p, "aws_sfn_state_machine.runtime").update(provider_config_key="aws.other"), "PG5")
        self.reject(lambda p: configuration(p, "aws_sfn_state_machine.runtime").update(for_each_expression={"references": ["local.unreviewed"]}), "PG5")
        self.reject(lambda p: configuration(p, "aws_cloudwatch_event_rule.origin_guard_signals")["expressions"]["state"].update(constant_value="ENABLED"), "PG5")
        self.reject(lambda p: configuration(p, "aws_scheduler_schedule.runtime_orchestration")["expressions"].update(target=[]), "PG5")
        self.reject(lambda p: configuration(p, "aws_scheduler_schedule.runtime_orchestration")["expressions"]["target"].append({}), "PG5")
        self.reject(lambda p: configuration(p, "aws_iam_role.runtime_events")["expressions"].pop("assume_role_policy"), "PG5")
        self.reject(lambda p: configuration(p, "aws_iam_role.runtime_events")["expressions"].update(permissions_boundary={"constant_value": "MOCK"}), "PG5")
        def unknown_policy(p):
            after(p, "aws_iam_role_policy.runtime_orchestrator")["policy"] = None
            resource(p, "aws_iam_role_policy.runtime_orchestrator")["change"]["after_unknown"] = {"policy": True}
        self.reject(unknown_policy, "PG5")

    def test_unknown_omitted_or_null_and_disabled_provider_defaults(self):
        plan = copy.deepcopy(PLAN)
        address = "aws_sfn_state_machine.runtime[\"day_open\"]"
        after(plan, address)["role_arn"] = None
        resource(plan, address)["change"]["after_unknown"] = {"role_arn": True}
        after(plan, address).update(logging_configuration=[{"level": "OFF", "include_execution_data": False, "log_destination": ""}], tracing_configuration=[{"enabled": False}], encryption_configuration=[{"type": "AWS_OWNED_KEY", "kms_key_id": None, "kms_data_key_reuse_period_seconds": None}])
        after(plan, "aws_dynamodb_table.runtime_control")["point_in_time_recovery"] = [{"enabled": False, "recovery_period_in_days": 35}]
        synchronize(plan)
        target = next(r for r in plan["planned_values"]["root_module"]["resources"] if r["address"] == address)
        target["values"] = copy.deepcopy(after(plan, address))
        target["values"].pop("role_arn")
        self.assertEqual(G.validate(plan, RENDERED)["result"], "PASS")
        target["values"]["role_arn"] = "concrete-unreviewed-value"
        with self.assertRaises(G.Rejected):
            G.validate(plan, RENDERED)
        for key, value in (("logging_configuration", [{"level": "OFF", "include_execution_data": True}]),
                           ("tracing_configuration", [{"enabled": True}]),
                           ("encryption_configuration", [{"type": "CUSTOMER_MANAGED_KMS_KEY", "kms_key_id": "MOCK"}])):
            self.reject(lambda p: after(p, address).update({key: value}), "PG5")
        self.reject(lambda p: after(p, "aws_dynamodb_table.runtime_control").update(point_in_time_recovery=[{"enabled": True, "recovery_period_in_days": 35}]), "PG5")
        for key in ("managed_policy_arns", "inline_policy", "permissions_boundary"):
            self.reject(lambda p: after(p, "aws_iam_role.runtime_events").update({key: ["MOCK_UNREVIEWED_GRANT"]}), "PG5")

    def test_only_schema_computed_unconfigured_role_attachment_observation_may_be_unknown(self):
        plan = copy.deepcopy(PLAN)
        address = "aws_iam_role.runtime_events"
        after(plan, address)["managed_policy_arns"] = None
        resource(plan, address)["change"]["after_unknown"] = {"managed_policy_arns": True}
        synchronize(plan)
        target = next(r for r in plan["planned_values"]["root_module"]["resources"] if r["address"] == address)
        target["values"] = copy.deepcopy(after(plan, address))
        target["values"].pop("managed_policy_arns")
        self.assertEqual(G.validate(plan, RENDERED)["result"], "PASS")
        # inline_policy is the one other role setting the provider computes; it
        # may be unknown as a whole with no planned policy. Boundaries and
        # force-detach have no such exception.
        inline = copy.deepcopy(plan)
        after(inline, address)["inline_policy"] = None
        resource(inline, address)["change"]["after_unknown"]["inline_policy"] = True
        synchronize(inline)
        self.assertEqual(G.validate(inline, RENDERED)["result"], "PASS")
        for field in ("permissions_boundary", "force_detach_policies"):
            def unknown(p):
                after(p, address)[field] = None
                resource(p, address)["change"]["after_unknown"] = {field: True}
            self.reject(unknown, "PG5")
        self.reject(lambda p: configuration(p, address)["expressions"].update(managed_policy_arns={"references": ["aws_iam_policy.unreviewed.arn"]}), "PG5")

    def test_real_provider_662_unknown_shape_passes(self):
        listed = {(base, key) for base, keys in G.COMPUTED_UNKNOWN.items() for key in keys}
        seen = {(address.split("[")[0], key) for address, unknown in PROVIDER_SHAPE.items() for key, value in unknown.items() if value is True}
        self.assertTrue(listed <= seen, sorted(listed - seen))
        self.assertEqual(set(PROVIDER_SHAPE), G.NEW)
        self.assertEqual(G.validate(provider_plan(), RENDERED)["result"], "PASS")

    def test_provider_computed_unknown_only_as_listed_whole_and_unplanned(self):
        base = provider_plan()
        machine = 'aws_sfn_state_machine.runtime["day_open"]'
        table = "aws_dynamodb_table.runtime_control"
        def unknown(address, key, value=None, mark=True):
            def mutate(p):
                after(p, address)[key] = value
                resource(p, address)["change"]["after_unknown"][key] = mark
            return mutate
        for address, key in ((machine, "publish"), (table, "stream_enabled"), (table, "local_secondary_index"), (table, "replica"),
                             ("aws_iam_role.runtime_events", "permissions_boundary"), ("aws_iam_role.runtime_orchestrator", "force_detach_policies")):
            self.reject(unknown(address, key), "PG5 unexpected unknown " + address.split("[")[0] + "/" + key, base=base)
        self.reject(unknown(machine, "tracing_configuration", [], [{"enabled": True}]), "PG5 partially unknown computed setting", base=base)
        # An unknown setting with a planned value is already rejected as an
        # unknown leaf with a concrete value, before the setting checks.
        self.reject(unknown(machine, "logging_configuration", [{"level": "OFF", "include_execution_data": False}]), "PG2 unknown leaf has concrete value", base=base)
        self.reject(unknown("aws_iam_role.runtime_eip_writer", "inline_policy", [{"name": "MOCK", "policy": "{}"}]), "PG2 unknown leaf has concrete value", base=base)
        self.reject(unknown(table, "global_secondary_index", [{"name": "MOCK", "hash_key": "pk", "projection_type": "ALL"}]), "PG2 unknown leaf has concrete value", base=base)
        self.reject(lambda p: configuration(p, "aws_sfn_state_machine.runtime")["expressions"].update(logging_configuration=[{"level": {"constant_value": "OFF"}}]), "PG5", base=base)
        self.reject(lambda p: configuration(p, table)["expressions"].update(point_in_time_recovery=[{"enabled": {"constant_value": False}}]), "PG5", base=base)

    def test_enabled_logging_tracing_kms_pitr_index_stream_and_grants_reject(self):
        base = provider_plan()
        machine = 'aws_sfn_state_machine.runtime["origin_guard"]'
        table = "aws_dynamodb_table.runtime_control"
        role = "aws_iam_role.runtime_orchestrator"
        def known(address, key, value):
            def mutate(p):
                after(p, address)[key] = value
                resource(p, address)["change"]["after_unknown"].pop(key, None)
            return mutate
        for address, key, value in ((machine, "logging_configuration", [{"level": "ALL", "include_execution_data": True, "log_destination": "arn:aws:logs:MOCK"}]),
                                    (machine, "tracing_configuration", [{"enabled": True}]),
                                    (machine, "encryption_configuration", [{"type": "CUSTOMER_MANAGED_KMS_KEY", "kms_key_id": "MOCK"}]),
                                    (machine, "publish", True), (machine, "version_description", "MOCK"),
                                    (table, "point_in_time_recovery", [{"enabled": True, "recovery_period_in_days": 35}]),
                                    (table, "global_secondary_index", [{"name": "MOCK", "hash_key": "pk", "projection_type": "ALL"}]),
                                    (table, "local_secondary_index", [{"name": "MOCK", "range_key": "sk", "projection_type": "ALL"}]),
                                    (table, "stream_enabled", True), (table, "replica", [{"region_name": "us-east-1"}]),
                                    (role, "inline_policy", [{"name": "MOCK", "policy": "{\"Statement\":[]}"}]),
                                    (role, "permissions_boundary", "arn:aws:iam::aws:policy/MOCK"),
                                    (role, "managed_policy_arns", ["arn:aws:iam::aws:policy/MOCK"])):
            self.reject(known(address, key, value), "PG5", base=base)

    def test_pg4_database_restorable_time_drifts_only_with_the_listed_fields(self):
        value = copy.deepcopy(after(PLAN, "aws_db_instance.demo"))
        before = dict(value, status="stopped", latest_restorable_time="2026-10-21T08:00:00Z")
        refreshed = dict(value, status="available", latest_restorable_time="2026-10-29T02:10:00Z")
        def drift(extra=None, actions=None):
            def mutate(p):
                b, a = dict(before), dict(refreshed)
                if extra:
                    b[extra[0]], a[extra[0]] = extra[1], extra[2]
                p["resource_drift"] = [{"address": "aws_db_instance.demo", "change": {"actions": ["update"], "before": b, "after": a}}]
                bind_refreshed(p, "aws_db_instance.demo", a)
                if actions:
                    resource(p, "aws_db_instance.demo")["change"]["actions"] = actions
            return mutate
        plan = copy.deepcopy(PLAN)
        drift()(plan)
        self.assertEqual(G.validate(plan, RENDERED)["result"], "PASS")
        for extra in (("engine_version", "10.11.9", "10.11.10"), ("allocated_storage", 20, 30), ("publicly_accessible", False, True)):
            self.reject(drift(extra), "PG4 unexpected drift fields")
        self.reject(drift(actions=["update"]), "PG1")

    def test_context_rejects_missing_account_identity_targets_and_resource_scope(self):
        prior = lambda p, a: next(r["values"] for r in p["prior_state"]["values"]["root_module"]["resources"] if r["address"] == a)
        for address, key, value in (("aws_iam_role.scheduler", "arn", "arn:aws:iam::000000000000:role/evil"),
                                     ("aws_instance.demo", "id", "i-unreviewed"), ("aws_instance.demo", "primary_network_interface_id", "eni-unreviewed"),
                                     ("aws_eip.ec2_origin", "allocation_id", "eipalloc-unreviewed"), ("aws_db_instance.demo", "identifier", "measurement"),
                                     ("aws_autoscaling_group.ecs_spot", "name", "ec-portfolio-demo-ecs-measure"),
                                     ("aws_ecr_repository.demo_api", "repository_url", "attacker/repo"), ("aws_cloudfront_distribution.api", "domain_name", "attacker.test")):
            self.reject(lambda p: prior(p, address).update({key: value}), "PG0", context=True)
        self.reject(lambda p: prior(p, "aws_instance.demo").pop("primary_network_interface_id"), "PG0", context=True)
        with self.assertRaises(G.Rejected):
            G.context_from_plan(PLAN, hashlib.sha256(b"111111111111").hexdigest())
        self.reject(lambda p: p["planned_values"]["root_module"]["resources"].append({"address": "data.aws_caller_identity.current", "mode": "data", "values": {"account_id": "111111111111"}}), "PG0", context=True)


class RevisionTests(unittest.TestCase):
    def view(self):
        return G.load(HERE / "fixtures/terraform116-measurement-drift.json")

    def deny(self, plan, mutation, prefix="PG4"):
        global REVISION_NEGATIVES
        candidate = copy.deepcopy(plan)
        mutation(candidate)
        REVISION_NEGATIVES += 1
        with self.assertRaises(G.Rejected) as rejected:
            G.drift_check(candidate)
        self.assertTrue(str(rejected.exception).startswith(prefix), str(rejected.exception))

    def test_prior_only_caller_layout_and_approved_account_binding(self):
        self.assertFalse(any(r.get("mode") == "data" for r in PLAN["planned_values"]["root_module"]["resources"]))
        self.assertEqual(G.context_from_plan(PLAN, ACCOUNT_SHA), G.exporter.fixture_context())
        for approved in (None, "", "f" * 64, ACCOUNT_SHA.upper(), ACCOUNT_SHA[:-1], "000000000000"):
            with self.assertRaises(G.Rejected):
                G.context_from_plan(PLAN, approved)
        wrong_sha = hashlib.sha256(b"111111111111").hexdigest()
        with self.assertRaises(G.Rejected):
            G.context_from_plan(PLAN, wrong_sha)
        plan = copy.deepcopy(PLAN)
        caller = next(r for r in plan["prior_state"]["values"]["root_module"]["resources"] if r["address"] == "data.aws_caller_identity.current")
        caller["values"]["account_id"] = "111111111111"
        with self.assertRaises(G.Rejected):
            G.context_from_plan(plan, ACCOUNT_SHA)

    def test_provider_overrides_and_aliases_rejected(self):
        for name in ("profile", "access_key", "secret_key", "assume_role", "endpoints", "shared_credentials_files"):
            plan = copy.deepcopy(PLAN)
            plan["configuration"]["provider_config"]["aws"]["expressions"][name] = {"constant_value": "MOCK"}
            with self.assertRaises(G.Rejected):
                G.context_from_plan(plan, ACCOUNT_SHA)
        plan = copy.deepcopy(PLAN)
        plan["configuration"]["provider_config"]["aws.other"] = {}
        with self.assertRaises(G.Rejected):
            G.context_from_plan(plan, ACCOUNT_SHA)
        plan = copy.deepcopy(PLAN)
        configuration(plan, "data.aws_caller_identity.current")["provider_config_key"] = "aws.other"
        with self.assertRaises(G.Rejected):
            G.context_from_plan(plan, ACCOUNT_SHA)

    def test_real_drift_projection_all_five_and_integrated_25_create_plan(self):
        view = self.view()
        self.assertEqual(len(view["resource_drift"]), 5)
        G.drift_check(view)
        plan = copy.deepcopy(PLAN)
        for row in view["prior_state"]["values"]["root_module"]["resources"]:
            bind_refreshed(plan, row["address"], row["values"])
        plan["configuration"]["root_module"]["resources"] += view["configuration"]["root_module"]["resources"]
        plan.update(resource_drift=view["resource_drift"], timestamp=view["timestamp"])
        self.assertEqual(G.validate(plan, RENDERED)["result"], "PASS")
        # A historical convergence plan does not acquire 25 new resources.
        plan["resource_changes"] = [r for r in plan["resource_changes"] if r["address"] not in G.NEW]
        with self.assertRaises(G.Rejected):
            G.validate(plan, RENDERED)

    def test_normalization_only_exact_path_direction_and_shape(self):
        view = self.view()
        group = "aws_autoscaling_group.ecs_spot_measurement[0]"
        drift = lambda p: next(r["change"] for r in p["resource_drift"] if r["address"] == group)
        for value in (["Launch"], {}, "", False):
            def mutation(p):
                drift(p)["after"]["suspended_processes"] = value
                bind_refreshed(p, group, drift(p)["after"])
            self.deny(view, mutation)
        def reverse(p):
            drift(p)["before"]["enabled_metrics"] = []
            drift(p)["after"]["enabled_metrics"] = None
            bind_refreshed(p, group, drift(p)["after"])
        self.deny(view, reverse)
        def hidden_sg(p):
            row = next(r for r in p["resource_drift"] if r["address"].startswith("aws_launch_template."))
            for side in ("before", "after"):
                row["change"][side]["network_interfaces"][0]["security_groups"] = ["sg-" + side]
            bind_refreshed(p, row["address"], row["change"]["after"])
        self.deny(view, hidden_sg)

    def test_drift_unknown_duplicate_new_address_and_action_rejected(self):
        view = self.view()
        for actions in (["delete"], ["create"], ["delete", "create"], ["no-op"]):
            self.deny(view, lambda p: p["resource_drift"][0]["change"].update(actions=actions))
        self.deny(view, lambda p: p["resource_drift"][0]["change"].update(after_unknown={"name": True}))
        self.deny(view, lambda p: p["resource_drift"].append(copy.deepcopy(p["resource_drift"][0])))
        self.deny(view, lambda p: p["resource_drift"][0].update(address=next(iter(G.NEW))))
        self.deny(view, lambda p: p["resource_drift"][0].update(previous_address="aws_instance.old"))

    def test_inline_observation_requires_existing_exact_separate_policy(self):
        view = self.view()
        address = "aws_iam_role.ecs_spot_measurement[0]"
        drift = lambda p: next(r["change"] for r in p["resource_drift"] if r["address"] == address)
        def extra_grant(p):
            policy = json.loads(drift(p)["after"]["inline_policy"][0]["policy"])
            policy["Statement"].append({"Effect": "Allow", "Action": "*", "Resource": "*"})
            drift(p)["after"]["inline_policy"][0]["policy"] = json.dumps(policy)
            bind_refreshed(p, address, drift(p)["after"])
        self.deny(view, extra_grant)
        self.deny(view, lambda p: drift(p)["before"].update(inline_policy=[{"name": "old-policy", "policy": "{}"}]))
        self.deny(view, lambda p: p["prior_state"]["values"]["root_module"]["resources"].pop(-1))
        def changed_policy(p):
            resource(p, "aws_iam_role_policy.ecs_spot_measurement[0]")["change"]["actions"] = ["update"]
        self.deny(view, changed_policy)
        self.deny(view, lambda p: configuration(p, address.split("[")[0])["expressions"].update(inline_policy=[]))
        def wrong_name(p):
            drift(p)["after"]["inline_policy"][0]["name"] = "other"
            bind_refreshed(p, address, drift(p)["after"])
        self.deny(view, wrong_name)

    def test_backstop_next_occurrence_not_arbitrary_timestamp(self):
        view = self.view()
        address = "aws_autoscaling_schedule.ecs_spot_measurement_backstop[0]"
        drift = lambda p: next(r["change"] for r in p["resource_drift"] if r["address"] == address)
        for value in ("2026-10-15T00:31:00Z", "2026-10-15T01:30:00Z", "2026-10-14T23:30:00Z", "2026-10-15T03:30:00Z"):
            def mutation(p):
                drift(p)["after"]["start_time"] = value
                bind_refreshed(p, address, drift(p)["after"])
            self.deny(view, mutation)
        self.deny(view, lambda p: configuration(p, address.split("[")[0])["expressions"].update(start_time={"constant_value": "MOCK"}))
        for key, value in (("recurrence", "* * * * *"), ("time_zone", "UTC"), ("desired_capacity", 1)):
            def mutation(p):
                drift(p)["after"][key] = value
                bind_refreshed(p, address, drift(p)["after"])
            self.deny(view, mutation)
        def wrong_capacity_observation(p):
            drift(p)["before"]["desired_capacity"] = 1
            drift(p)["after"]["desired_capacity"] = 1
            bind_refreshed(p, address, drift(p)["after"])
        self.deny(view, wrong_capacity_observation)

    def test_refresh_noop_must_match_every_allowed_observation(self):
        view = self.view()
        for row in view["resource_drift"]:
            address = row["address"]
            for actions in (["update"], ["delete"], ["create", "delete"]):
                self.deny(view, lambda p: resource(p, address)["change"].update(actions=actions))


def p3a2_plan():
    """The P3-a2 plan: the 25 P3-a resources now exist, and only the template, the
    group and the promotion policy change. Values are MOCK; the shape is the state
    Terraform 1.16 and AWS provider 6.62 keep for these resources."""
    plan = copy.deepcopy(PLAN)
    allocation = ORIGINAL.exporter.fixture_context()["aws_eip"]["ec2_origin"]["allocation_id"]
    prior = plan["prior_state"]["values"]["root_module"]["resources"]
    for entry in plan["resource_changes"]:
        if entry["address"] in ORIGINAL.NEW:
            values = entry["change"]["after"]
            entry["change"] = {"actions": ["no-op"], "before": values, "after": values, "after_unknown": {}}
            prior.append({"address": entry["address"], "mode": "managed", "type": entry["type"], "values": values})
    loader = lambda value: base64.b64encode(("#!/bin/bash\nreadonly BUNDLE=\"v1\"\nreadonly EIP_ALLOCATION_ID_VALUE=\"" + value + "\"\nexit 0\n").encode()).decode()
    template = {"name": "ec-portfolio-demo-ecs-spot", "latest_version": 4, "default_version": 1, "user_data": loader(allocation), "block_device_mappings": []}
    group = {**resource(plan, ORIGINAL.P3A2_GROUP)["change"]["before"], "name": "ec-portfolio-demo-ecs-spot", "capacity_rebalance": True, "min_size": 0, "desired_capacity": 0, "max_size": 2,
             "launch_template": [{"id": "lt-MOCK", "name": "ec-portfolio-demo-ecs-spot", "version": "4"}], "tag": []}
    policy = {"name": "origin-eip-promotion", "role": "ec-portfolio-demo-ecs-spot", "policy": "{}"}
    bind_refreshed(plan, ORIGINAL.P3A2_TEMPLATE, template)
    bind_refreshed(plan, ORIGINAL.P3A2_GROUP, group)
    bind_refreshed(plan, ORIGINAL.P3A2_POLICY, policy)
    change = resource(plan, ORIGINAL.P3A2_TEMPLATE)["change"]
    change.update(actions=["update"], after={**{k: v for k, v in template.items() if k != "latest_version"}, "user_data": loader("")},
                  after_unknown={"latest_version": True, "block_device_mappings": []})
    change = resource(plan, ORIGINAL.P3A2_GROUP)["change"]
    change.update(actions=["update"], after={**group, "capacity_rebalance": False, "launch_template": [{"id": "lt-MOCK", "name": "ec-portfolio-demo-ecs-spot"}]},
                  after_unknown={"launch_template": [{"version": True}], "tag": []})
    entry = resource(plan, ORIGINAL.P3A2_POLICY)
    entry["action_reason"] = "delete_because_no_resource_config"
    entry["change"].update(actions=["delete"], after=None, after_unknown={})
    plan["output_changes"] = {ORIGINAL.P3A2_OUTPUT: {"actions": ["update"], "before": 4, "after_unknown": True},
                              "ecs_spot_launch_template_id": {"actions": ["no-op"], "before": "lt-MOCK", "after": "lt-MOCK", "after_unknown": False}}
    plan["prior_state"]["values"]["outputs"] = {ORIGINAL.P3A2_OUTPUT: {"value": 4}, "ecs_spot_launch_template_id": {"value": "lt-MOCK"}}
    plan["configuration"]["root_module"]["resources"] = [r for r in plan["configuration"]["root_module"]["resources"] if r["address"] != ORIGINAL.P3A2_POLICY]
    p3a2_sync(plan)
    return plan


def p3a2_sync(plan):
    data = [r for r in plan["planned_values"]["root_module"]["resources"] if r.get("mode") == "data"]
    planned = [{"address": r["address"], "mode": r["mode"], "type": r["type"], "values": r["change"].get("after")}
               for r in plan["resource_changes"] if r["change"]["actions"] != ["delete"]]
    plan["planned_values"]["root_module"]["resources"] = planned + data
    plan["planned_values"]["outputs"] = {"ecs_spot_launch_template_id": {"value": "lt-MOCK"}}


class P3a2Tests(unittest.TestCase):
    """validate_p3a2 on the exact 0 / 2 / 1 plan and on one violation at a time."""

    def reject(self, mutate, prefix, sync=True):
        global FIXTURE_CHECKS
        FIXTURE_CHECKS += 1
        plan = p3a2_plan()
        mutate(plan)
        if sync:
            p3a2_sync(plan)
        with self.assertRaises(G.Rejected) as caught:
            G.validate_p3a2(plan)
        self.assertTrue(str(caught.exception).startswith(prefix), str(caught.exception))

    @staticmethod
    def change(plan, address):
        return resource(plan, address)["change"]

    def test_positive_exact_plan(self):
        result = G.validate_p3a2(p3a2_plan())
        self.assertEqual((result["mode"], result["creates"], result["changes"], result["destroys"]), ("p3a2", 0, 2, 1))

    def test_plan_format_is_shared_with_p3a(self):
        for key, value, prefix in (("terraform_version", "1.15.0", "PG0 plan format/version"), ("complete", False, "PG0 incomplete plan"),
                                   ("errored", True, "PG0 errored plan"), ("applyable", False, "PG0 non-applyable plan")):
            self.reject(lambda plan, k=key, v=value: plan.update({k: v}), prefix)

    def test_exact_changed_set(self):
        address = "aws_instance.demo"
        self.reject(lambda p: self.change(p, address).update(actions=["update"]), "P3A2 exact 2 updates and 1 delete")
        self.reject(lambda p: self.change(p, ORIGINAL.P3A2_POLICY).update(actions=["no-op"]), "P3A2 exact 2 updates and 1 delete")
        self.reject(lambda p: self.change(p, 'aws_scheduler_schedule.runtime_orchestration["day_open"]').update(actions=["update"]), "P3A2 exact 2 updates and 1 delete")
        self.reject(lambda p: p["resource_changes"].append({"address": "aws_iam_role_policy.extra", "mode": "managed", "type": "aws_iam_role_policy", "change": {"actions": ["create"], "before": None, "after": {}, "after_unknown": {}}}), "P3A2 exact 2 updates and 1 delete")

    def test_root_and_existing_resources(self):
        def remove_prior(plan, address):
            plan["prior_state"]["values"]["root_module"]["resources"] = [r for r in plan["prior_state"]["values"]["root_module"]["resources"] if r["address"] != address]
        self.reject(lambda p: remove_prior(p, "aws_instance.demo"), "P3A2 wrong/incomplete root")
        self.reject(lambda p: p["resource_changes"].append({"address": "aws_x.unknown", "mode": "managed", "type": "aws_x", "change": {"actions": ["no-op"], "before": {}, "after": {}, "after_unknown": {}}}), "P3A2 all prior resources represented")
        self.reject(lambda p: p["resource_changes"].remove(resource(p, "aws_instance.demo")), "P3A2 all prior resources represented")
        self.reject(lambda p: self.change(p, "aws_instance.demo").update(after={"MOCK": "other"}), "P3A2 existing changed aws_instance.demo", sync=False)
        self.reject(lambda p: self.change(p, "aws_instance.demo").update(after_unknown={"arn": True}), "P3A2 existing unknown/moved", sync=False)
        self.reject(lambda p: resource(p, "aws_instance.demo").update(previous_address="aws_instance.old"), "P3A2 existing unknown/moved", sync=False)

    def test_update_is_in_place_bound_and_exactly_unknown(self):
        for address in (ORIGINAL.P3A2_TEMPLATE, ORIGINAL.P3A2_GROUP):
            self.reject(lambda p, a=address: self.change(p, a).update(actions=["delete", "create"]), "P3A2 update action " + address)
            self.reject(lambda p, a=address: resource(p, a).update(previous_address="aws_x.old"), "P3A2 update import/move " + address)
            self.reject(lambda p, a=address: self.change(p, a).update(importing={"id": "x"}), "P3A2 update import/move " + address)
            self.reject(lambda p, a=address: self.change(p, a)["before"].update(name="stale"), "P3A2 update not bound to refreshed state " + address)
            self.reject(lambda p, a=address: self.change(p, a)["after_unknown"].update(name=True), "P3A2 update unknown " + address)

    def test_template_changes_only_the_allocation_line(self):
        t = ORIGINAL.P3A2_TEMPLATE
        encode = lambda text: base64.b64encode(text.encode()).decode()
        allocation = ORIGINAL.exporter.fixture_context()["aws_eip"]["ec2_origin"]["allocation_id"]
        self.reject(lambda p: self.change(p, t)["after"].update(default_version=5), "P3A2 template changed fields")
        self.reject(lambda p: self.change(p, t)["after"].update(user_data=self.change(p, t)["before"]["user_data"]), "P3A2 template changed fields")
        self.reject(lambda p: (self.change(p, t)["before"].update(latest_version=5), bind_refreshed_only(p, t)), "P3A2 template version")
        self.reject(lambda p: self.change(p, t)["after"].update(latest_version=5), "P3A2 template version", sync=False)
        extra = "#!/bin/bash\nreadonly BUNDLE=\"v1\"\nreadonly EIP_ALLOCATION_ID_VALUE=\"\"\nexit 0\nmore\n"
        self.reject(lambda p: self.change(p, t)["after"].update(user_data=encode(extra)), "P3A2 loader line count")
        bundle = "#!/bin/bash\nreadonly BUNDLE=\"v2\"\nreadonly EIP_ALLOCATION_ID_VALUE=\"\"\nexit 0\n"
        self.reject(lambda p: self.change(p, t)["after"].update(user_data=encode(bundle)), "P3A2 loader change")
        other = "#!/bin/bash\nreadonly BUNDLE=\"v1\"\nreadonly EIP_ALLOCATION_ID_VALUE=\"eipalloc-other\"\nexit 0\n"
        self.reject(lambda p: self.change(p, t)["after"].update(user_data=encode(other)), "P3A2 loader change")
        self.assertTrue(allocation)

    def test_group_changes_only_rebalance_and_version(self):
        g = ORIGINAL.P3A2_GROUP
        self.reject(lambda p: self.change(p, g)["after"].update(capacity_rebalance=True), "P3A2 group changed fields")
        self.reject(lambda p: self.change(p, g)["after"].update(health_check_type="ELB"), "P3A2 group changed fields")
        self.reject(lambda p: self.change(p, g)["after"].update(desired_capacity=1), "P3A2 group changed fields")
        def rebalance_off_before(plan):
            self.change(plan, g)["before"]["capacity_rebalance"] = False
            self.change(plan, g)["after"]["capacity_rebalance"] = True
            bind_refreshed_only(plan, g)
        self.reject(rebalance_off_before, "P3A2 capacity rebalance")
        def wrong_capacity(plan):
            for side in ("before", "after"):
                self.change(plan, g)[side]["max_size"] = 3
            bind_refreshed_only(plan, g)
        self.reject(wrong_capacity, "P3A2 group capacity")
        self.reject(lambda p: self.change(p, g)["after"]["launch_template"][0].update(id="lt-other"), "P3A2 group template reference")
        self.reject(lambda p: self.change(p, g)["after"]["launch_template"][0].update(version="5"), "P3A2 group template reference", sync=False)
        def old_reference(plan):
            self.change(plan, g)["before"]["launch_template"][0]["version"] = "3"
            bind_refreshed_only(plan, g)
        self.reject(old_reference, "P3A2 group template reference")

    def test_only_the_promotion_policy_is_removed_from_the_source(self):
        a = ORIGINAL.P3A2_POLICY
        self.reject(lambda p: resource(p, a).update(action_reason="delete_because_count_index"), "P3A2 policy delete")
        self.reject(lambda p: self.change(p, a).update(after={"name": "x"}), "P3A2 policy delete")
        self.reject(lambda p: self.change(p, a)["before"].update(name="stale"), "P3A2 policy identity")
        def other_policy(plan):
            self.change(plan, a)["before"]["name"] = "session-manager-core"
            bind_refreshed_only(plan, a)
        self.reject(other_policy, "P3A2 policy identity")
        def other_role(plan):
            self.change(plan, a)["before"]["role"] = "ec-portfolio-demo-ec2"
            bind_refreshed_only(plan, a)
        self.reject(other_role, "P3A2 policy identity")
        self.reject(lambda p: p["configuration"]["root_module"]["resources"].append({"address": a, "mode": "managed"}), "P3A2 policy still configured")

    def test_planned_values_are_consistent(self):
        def remove_planned(plan):
            plan["planned_values"]["root_module"]["resources"] = [r for r in plan["planned_values"]["root_module"]["resources"] if r["address"] != "aws_instance.demo"]
        self.reject(remove_planned, "P3A2 planned resource coverage", sync=False)
        def keep_policy(plan):
            plan["planned_values"]["root_module"]["resources"].append({"address": ORIGINAL.P3A2_POLICY, "mode": "managed", "type": "aws_iam_role_policy", "values": {}})
        self.reject(keep_policy, "P3A2 planned resource coverage", sync=False)
        def inconsistent(plan):
            next(r for r in plan["planned_values"]["root_module"]["resources"] if r["address"] == "aws_instance.demo")["values"] = {"MOCK": "other"}
        self.reject(inconsistent, "P3A2 planned value inconsistency", sync=False)

    def test_outputs(self):
        o = ORIGINAL.P3A2_OUTPUT
        self.reject(lambda p: p["output_changes"].pop(o), "P3A2 version output")
        self.reject(lambda p: p["output_changes"][o].update(actions=["no-op"]), "P3A2 version output")
        self.reject(lambda p: p["output_changes"][o].update(before=3), "P3A2 version output")
        self.reject(lambda p: p["output_changes"][o].update(after_unknown=False), "P3A2 version output")
        self.reject(lambda p: p["output_changes"]["ecs_spot_launch_template_id"].update(actions=["update"]), "P3A2 output changed")
        self.reject(lambda p: p["output_changes"]["ecs_spot_launch_template_id"].update(after="lt-other"), "P3A2 output changed")
        self.reject(lambda p: p["output_changes"]["ecs_spot_launch_template_id"].update(after_unknown=True), "P3A2 output changed")
        def snapshot(plan):
            plan["planned_values"]["outputs"]["ecs_spot_launch_template_id"] = {"value": "lt-other"}
        self.reject(snapshot, "P3A2 output snapshot changed", sync=False)

    def test_drift_is_still_checked(self):
        def drift(plan):
            plan["resource_drift"] = [{"address": "aws_iam_role.ecs_spot", "change": {"actions": ["update"], "before": {}, "after": {}, "after_unknown": {}}}]
        self.reject(drift, "PG4 unexpected drift")

    def test_only_true_leaves_count_as_unknown(self):
        self.assertEqual(G.unknown_leaves({"a": [{"b": True}, {}], "c": False, "d": {}, "e": True}), {"/a/0/b", "/e"})
        self.assertEqual(G.unknown_leaves(None), set())


FIRST_REFRESH = json.loads((HERE / "fixtures/terraform116-provider662-p3a2-first-refresh-drift.json").read_text())
FIRST_REFRESH_ADDRESSES = {"aws_iam_role.runtime_eip_writer", "aws_iam_role.runtime_events", "aws_iam_role.runtime_orchestrator",
                           "aws_ssm_document.od_readiness", "aws_ssm_document.spot_smoke"}


def add_first_refresh(plan, address):
    """The first-refresh observation in the shape of the real rejected plan: its
    attribute names and changed values, with the MOCK values of this plan."""
    shape = FIRST_REFRESH["resources"][address]
    current = resource(plan, address)["change"]["after"]
    values = {name: current.get(name, "MOCK") for name in shape["attributes"]}
    before, refreshed = dict(values, **shape["before"]), dict(values)
    if address.startswith("aws_iam_role."):
        policy = after(plan, ORIGINAL.P3A2_DRIFT_RULES[address]["observed_inline_policy"])
        refreshed["inline_policy"] = [{"name": name, "policy": policy["policy"]} for name in shape["after_observed_policy_names"]]
    else:
        refreshed.update(shape["after"])
    plan["resource_drift"].append({"address": address, "mode": "managed", "type": shape["type"], "name": shape["name"],
                                   "change": {"actions": shape["actions"], "before": before, "after": refreshed, "after_unknown": {}}})
    bind_refreshed(plan, address, refreshed)
    p3a2_sync(plan)


def add_approved_refresh(plan):
    """The three drifts the rejected plan had that the gate already allowed: the
    host and the database stopped, and the measurement backstop's next occurrence."""
    measurement = json.loads((HERE / "fixtures/terraform116-measurement-drift.json").read_text())
    address = "aws_autoscaling_schedule.ecs_spot_measurement_backstop[0]"
    row = next(r for r in measurement["resource_drift"] if r["address"] == address)
    plan["resource_drift"].append(copy.deepcopy(row))
    plan["timestamp"] = measurement["timestamp"]
    plan["configuration"]["root_module"]["resources"].append(copy.deepcopy(next(r for r in measurement["configuration"]["root_module"]["resources"] if r["address"] == address.split("[")[0])))
    bind_refreshed(plan, address, row["change"]["after"])
    for name, attributes in (("aws_db_instance.demo", {"status": ("available", "stopped"), "latest_restorable_time": ("2026-10-21T08:00:00Z", "2026-10-29T02:10:00Z")}),
                             ("aws_instance.demo", {"instance_state": ("running", "stopped")})):
        current = resource(plan, name)["change"]["after"]
        before, refreshed = dict(current), dict(current)
        for key, (old, new) in attributes.items():
            before[key], refreshed[key] = old, new
        plan["resource_drift"].append({"address": name, "mode": "managed", "type": name.split(".")[0], "change": {"actions": ["update"], "before": before, "after": refreshed, "after_unknown": {}}})
        bind_refreshed(plan, name, refreshed)
    p3a2_sync(plan)


class P3a2FirstRefreshTests(unittest.TestCase):
    """The drift of the first plan that refreshes the P3-a resources: exactly five
    addresses, each with one exact value change, and only in the p3a2 mode."""

    def plan(self, *addresses):
        plan = p3a2_plan()
        for address in addresses:
            add_first_refresh(plan, address)
        return plan

    def assert_rejected(self, plan, code, direct=False):
        global FIXTURE_CHECKS
        FIXTURE_CHECKS += 1
        with self.assertRaises(G.Rejected) as caught:
            G.drift_check(plan, G.P3A2_DRIFT_RULES) if direct else G.validate_p3a2(plan)
        self.assertEqual(str(caught.exception), code)

    def refreshed(self, address, change, code):
        """Change the observation, keep it bound to the refreshed no-op, and expect `code`."""
        plan = self.plan(address)
        row = next(r for r in plan["resource_drift"] if r["address"] == address)
        change(row["change"])
        bind_refreshed(plan, address, row["change"]["after"])
        p3a2_sync(plan)
        self.assert_rejected(plan, code)

    def test_rules_are_exactly_the_five_addresses_and_separate_from_the_general_allowlist(self):
        self.assertEqual(set(G.P3A2_DRIFT_RULES), FIRST_REFRESH_ADDRESSES)
        self.assertEqual(set(FIRST_REFRESH["resources"]), FIRST_REFRESH_ADDRESSES)
        self.assertLessEqual(FIRST_REFRESH_ADDRESSES, G.NEW)
        self.assertFalse(FIRST_REFRESH_ADDRESSES & set(G.DRIFT))
        self.assertFalse(FIRST_REFRESH_ADDRESSES & set(G.ADDRESSES["MEASUREMENT_DRIFT_RULES"]))
        self.assertEqual(len(G.DRIFT), 8)
        self.assertEqual(len(G.ADDRESSES["MEASUREMENT_DRIFT_RULES"]), 5)
        for address, rule in G.P3A2_DRIFT_RULES.items():
            self.assertEqual(rule["fields"], ["inline_policy" if ".runtime_" in address and "iam_role" in address else "permissions"])

    def test_positive_all_five_alone_and_with_the_approved_three(self):
        for addresses in [FIRST_REFRESH_ADDRESSES, *[{address} for address in sorted(FIRST_REFRESH_ADDRESSES)]]:
            result = G.validate_p3a2(self.plan(*sorted(addresses)))
            self.assertEqual((result["result"], result["creates"], result["changes"], result["destroys"]), ("PASS", 0, 2, 1))
        plan = self.plan(*sorted(FIRST_REFRESH_ADDRESSES))
        add_approved_refresh(plan)
        self.assertEqual({r["address"] for r in plan["resource_drift"]}, set(FIRST_REFRESH["resource_drift_order"]))
        plan["resource_drift"].sort(key=lambda r: FIRST_REFRESH["resource_drift_order"].index(r["address"]))
        self.assertEqual(G.validate_p3a2(plan)["result"], "PASS")
        changed = {r["address"]: r["change"]["actions"] for r in plan["resource_changes"] if r["change"]["actions"] != ["no-op"]}
        self.assertEqual(changed, {G.P3A2_TEMPLATE: ["update"], G.P3A2_GROUP: ["update"], G.P3A2_POLICY: ["delete"]})

    def test_observed_inline_policy_must_be_the_one_separate_policy(self):
        role = "aws_iam_role.runtime_eip_writer"
        policy_address = G.P3A2_DRIFT_RULES[role]["observed_inline_policy"]
        def name(change):
            change["after"]["inline_policy"][0]["name"] = "other"
        self.refreshed(role, name, "PG4 inline separate-policy binding")
        def grant(change):
            document = json.loads(change["after"]["inline_policy"][0]["policy"])
            document["Statement"].append({"Effect": "Allow", "Action": "*", "Resource": "*"})
            change["after"]["inline_policy"][0]["policy"] = json.dumps(document)
        self.refreshed(role, grant, "PG4 inline policy content")
        def second(change):
            change["after"]["inline_policy"].append(dict(change["after"]["inline_policy"][0], name="second"))
        self.refreshed(role, second, "PG4 inline observation shape")
        def no_policy(change):
            change["after"]["inline_policy"] = []
        self.refreshed(role, no_policy, "PG4 empty drift")
        def stored_before(change):
            change["before"]["inline_policy"] = [{"name": "old", "policy": "{}"}]
        self.refreshed(role, stored_before, "PG4 inline observation shape")
        def extra_key(change):
            change["after"]["inline_policy"][0]["path"] = "/"
        self.refreshed(role, extra_key, "PG4 inline separate-policy binding")
        def bind_policy(plan, **values):
            bind_refreshed(plan, policy_address, dict(after(plan, policy_address), **values))
            p3a2_sync(plan)
        plan = self.plan(role)
        bind_policy(plan, role="ec-portfolio-demo-ecs-spot")
        self.assert_rejected(plan, "PG4 inline separate-policy binding")
        # The separate policy and the observation agree, on a name the rule does not know.
        plan = self.plan(role)
        bind_policy(plan, name="other")
        row = next(r for r in plan["resource_drift"] if r["address"] == role)
        row["change"]["after"]["inline_policy"][0]["name"] = "other"
        bind_refreshed(plan, role, row["change"]["after"])
        p3a2_sync(plan)
        self.assert_rejected(plan, "PG4 inline separate-policy binding")
        plan = self.plan(role)
        configuration(plan, role)["expressions"]["inline_policy"] = []
        self.assert_rejected(plan, "PG4 configured inline policy")

    def test_separate_policy_and_observed_resource_stay_no_op(self):
        role = "aws_iam_role.runtime_events"
        plan = self.plan(role)
        resource(plan, G.P3A2_DRIFT_RULES[role]["observed_inline_policy"])["change"]["actions"] = ["update"]
        self.assert_rejected(plan, "P3A2 exact 2 updates and 1 delete")
        plan = self.plan(role)
        resource(plan, G.P3A2_DRIFT_RULES[role]["observed_inline_policy"])["change"]["actions"] = ["update"]
        self.assert_rejected(plan, "PG4 inline separate-policy binding", direct=True)
        for address in FIRST_REFRESH_ADDRESSES:
            plan = self.plan(address)
            resource(plan, address)["change"]["actions"] = ["update"]
            self.assert_rejected(plan, "P3A2 exact 2 updates and 1 delete")
            plan = self.plan(address)
            resource(plan, address)["change"]["actions"] = ["update"]
            self.assert_rejected(plan, "PG4 drift refreshed no-op binding", direct=True)
            plan = self.plan(address)
            next(r for r in plan["resource_drift"] if r["address"] == address)["change"]["after_unknown"] = {"name": True}
            self.assert_rejected(plan, "PG4 drift action/unknown")
            plan = self.plan(address)
            next(r for r in plan["resource_drift"] if r["address"] == address)["change"]["actions"] = ["delete"]
            self.assert_rejected(plan, "PG4 drift action/unknown")

    def test_no_other_field_of_a_role_or_document_may_drift(self):
        role_fields = {"permissions_boundary": ("", "arn:aws:iam::000000000000:policy/other"), "assume_role_policy": ("{}", "{\"Version\":\"2012-10-17\"}"),
                       "managed_policy_arns": ([], ["arn:aws:iam::aws:policy/AdministratorAccess"]), "max_session_duration": (3600, 43200), "path": ("/", "/other/")}
        document_fields = {"content": ("{}", "{\"changed\":true}"), "document_version": ("1", "2"), "default_version": ("1", "2"), "latest_version": ("1", "2"), "hash": ("a", "b"), "status": ("Active", "Failed")}
        for address in FIRST_REFRESH_ADDRESSES:
            for name, (old, new) in (role_fields if "iam_role" in address else document_fields).items():
                def change(row, name=name, old=old, new=new):
                    row["before"][name], row["after"][name] = old, new
                self.refreshed(address, change, "PG4 unexpected drift fields")

    def test_document_permissions_are_exactly_null_to_empty(self):
        for address in ("aws_ssm_document.od_readiness", "aws_ssm_document.spot_smoke"):
            for value in ({"type": "Share", "account_ids": "all"}, {"type": "Share", "account_ids": "111111111111"}, {"type": "Share"}, [], "", None):
                def shared(change, value=value):
                    change["after"]["permissions"] = value
                self.refreshed(address, shared, "PG4 document permissions" if value is not None else "PG4 empty drift")
            def stored(change):
                change["before"]["permissions"] = {"type": "Share", "account_ids": "111111111111"}
            self.refreshed(address, stored, "PG4 drift object keys")
            def stored_other_shape(change):
                change["before"]["permissions"] = "Share"
            self.refreshed(address, stored_other_shape, "PG4 document permissions")
            def empty_before(change):
                change["before"]["permissions"] = {}
            self.refreshed(address, empty_before, "PG4 empty drift")
            def missing(change):
                del change["before"]["permissions"]
            self.refreshed(address, missing, "PG4 drift object keys")
            def renamed(change):
                change["after"]["name"] = change["before"]["name"] = "ec-portfolio-demo-other"
            self.refreshed(address, renamed, "PG4 document permissions")
            plan = self.plan(address)
            configuration(plan, address)["expressions"]["permissions"] = {"constant_value": {}}
            self.assert_rejected(plan, "PG4 configured document permissions")

    def test_same_drift_on_any_other_role_document_or_new_resource_rejected(self):
        def foreign(address, source):
            plan = self.plan(source)
            row = plan["resource_drift"][0]
            row["address"] = address
            if not any(r["address"] == address for r in plan["resource_changes"]):
                plan["resource_changes"].append({"address": address, "mode": "managed", "type": address.split(".")[0], "change": {"actions": ["no-op"], "before": row["change"]["after"], "after": row["change"]["after"], "after_unknown": {}}})
                plan["prior_state"]["values"]["root_module"]["resources"].append({"address": address, "mode": "managed", "type": address.split(".")[0], "values": row["change"]["after"]})
            bind_refreshed(plan, address, row["change"]["after"])
            p3a2_sync(plan)
            return plan
        role, document = "aws_iam_role.runtime_events", "aws_ssm_document.spot_smoke"
        for address in ("aws_iam_role.ecs_spot", "aws_iam_role.runtime_other", "aws_iam_role.ec2"):
            self.assert_rejected(foreign(address, role), "PG4 unexpected drift")
        self.assert_rejected(foreign("aws_ssm_document.other", document), "PG4 unexpected drift")
        # Every other P3-a resource stays out: this is not a NEW-wide allowance.
        others = G.NEW - FIRST_REFRESH_ADDRESSES
        self.assertEqual(len(others), 20)
        for address in sorted(others):
            self.assert_rejected(foreign(address, role), "PG4 unexpected drift")

    def test_extra_terraform_change_and_other_refresh_drift_rejected(self):
        plan = self.plan(*sorted(FIRST_REFRESH_ADDRESSES))
        add_approved_refresh(plan)
        plan["resource_changes"].append({"address": "aws_iam_role_policy.extra", "mode": "managed", "type": "aws_iam_role_policy", "change": {"actions": ["create"], "before": None, "after": {}, "after_unknown": {}}})
        self.assert_rejected(plan, "P3A2 exact 2 updates and 1 delete")
        plan = self.plan(*sorted(FIRST_REFRESH_ADDRESSES))
        add_approved_refresh(plan)
        row = next(r for r in plan["resource_drift"] if r["address"] == "aws_instance.demo")
        row["change"]["before"]["instance_type"], row["change"]["after"]["instance_type"] = "t3a.medium", "m7i.48xlarge"
        bind_refreshed(plan, "aws_instance.demo", row["change"]["after"])
        p3a2_sync(plan)
        self.assert_rejected(plan, "PG4 unexpected drift fields")

    def test_guards_hold_if_the_contract_file_is_widened(self):
        role, document = "aws_iam_role.runtime_events", "aws_ssm_document.od_readiness"
        for address, field, old, new, code in ((role, "path", "/", "/other/", "PG4 inline observation shape"), (document, "content", "{}", "{\"changed\":true}", "PG4 document permissions")):
            def change(row, field=field, old=old, new=new):
                row["before"][field], row["after"][field] = old, new
            with mock.patch.dict(G.P3A2_DRIFT_RULES[address], {"fields": [*G.P3A2_DRIFT_RULES[address]["fields"], field]}):
                self.refreshed(address, change, code)
        # A P3-a resource listed in the general allowlist stays rejected there.
        with mock.patch.dict(G.DRIFT, {role: ["inline_policy"]}):
            with self.assertRaises(G.Rejected) as caught:
                G.drift_check(self.plan(role))
            self.assertEqual(str(caught.exception), "PG4 unexpected drift")

    def test_p3a_mode_cannot_use_the_rules(self):
        global FIXTURE_CHECKS
        for address in sorted(FIRST_REFRESH_ADDRESSES):
            refreshed = self.plan(address)
            with self.assertRaises(G.Rejected) as caught:
                G.drift_check(refreshed)
            self.assertEqual(str(caught.exception), "PG4 unexpected drift")
            plan = copy.deepcopy(PLAN)
            plan["resource_drift"] = copy.deepcopy(refreshed["resource_drift"])
            with self.assertRaises(G.Rejected) as caught:
                G.validate(plan, RENDERED)
            self.assertEqual(str(caught.exception), "PG4 unexpected drift")
            FIXTURE_CHECKS += 2


def bind_refreshed_only(plan, address):
    values = resource(plan, address)["change"]["before"]
    for r in plan["prior_state"]["values"]["root_module"]["resources"]:
        if r["address"] == address:
            r["values"] = copy.deepcopy(values)


class EntryTests(unittest.TestCase):
    """The command-line entry points the saved-plan -> review -> apply flow calls.

    `terraform show` and `git` are answered by a stand-in; only the
    provider-free `terraform console` render really runs.
    """
    COMMIT = "a" * 40

    def setUp(self):
        self.real_run = subprocess.run
        self.commits = [self.COMMIT]
        self.status = ""
        self.git_exit = 0
        self.show_plan = PLAN
        self.show_exit = 0

    def fake_run(self, args, *positional, **keywords):
        if args[1:2] == ["console"]:
            return self.real_run(args, *positional, **keywords)
        if args[0] == "git":
            if "rev-parse" in args:
                commit = self.commits[0] if len(self.commits) == 1 else self.commits.pop(0)
                return types.SimpleNamespace(returncode=self.git_exit, stdout=(commit + "\n").encode(), stderr=b"")
            self.assertEqual(args[-2:], ["--", "infra/terraform/demo"])
            return types.SimpleNamespace(returncode=self.git_exit, stdout=self.status.encode(), stderr=b"")
        self.assertEqual(args[1:3], ["show", "-json"])
        self.assertFalse(any(key.startswith("AWS_") for key in keywords["env"]))
        return types.SimpleNamespace(returncode=self.show_exit, stdout=json.dumps(self.show_plan).encode(), stderr=b"")

    def call(self, *argv):
        stdout, stderr = io.StringIO(), io.StringIO()
        with mock.patch.object(G.subprocess, "run", side_effect=self.fake_run), \
                mock.patch.object(sys, "stdout", stdout), mock.patch.object(sys, "stderr", stderr):
            code = G.main(["cold-standby-plan-gate.py", *argv])
        return code, stdout.getvalue(), stderr.getvalue()

    def files(self, temporary, plan):
        saved = Path(temporary) / "p3a.tfplan"
        saved.write_bytes(b"MOCK saved plan bytes")
        path = Path(temporary) / "plan.json"
        path.write_text(json.dumps(plan))
        return saved, path

    def gate(self, plan, account=ACCOUNT_SHA):
        with tempfile.TemporaryDirectory(prefix="p3a-MOCK-plan-") as temporary:
            saved, path = self.files(temporary, plan)
            code, out, err = self.call("p3a", str(saved), str(path), account)
            return code, out, err, hashlib.sha256(saved.read_bytes()).hexdigest(), hashlib.sha256(path.read_bytes()).hexdigest()

    def test_pass_records_saved_plan_plan_json_commit_and_account(self):
        code, out, _, saved_sha, plan_sha = self.gate(PLAN)
        self.assertEqual(code, 0)
        result = json.loads(out)
        self.assertEqual((result["result"], result["creates"], result["changes"], result["destroys"]), ("PASS", 25, 0, 0))
        self.assertEqual((result["saved_plan_sha256"], result["plan_json_sha256"], result["source_commit"],
                          result["approved_account_sha256"], result["terraform_version"]),
                         (saved_sha, plan_sha, self.COMMIT, ACCOUNT_SHA, "1.16.0"))

    def test_plan_json_must_be_the_saved_plan(self):
        shown = copy.deepcopy(PLAN)
        shown["timestamp"] = "2026-10-21T00:00:02Z"
        self.show_plan = shown
        code, out, err, _, _ = self.gate(PLAN)
        self.assertEqual((code, out), (1, ""))
        self.assertIn("PG0 plan JSON is not the saved plan", err)
        self.show_plan, self.show_exit = PLAN, 1
        self.assertIn("PG0 terraform show of the saved plan failed", self.gate(PLAN)[2])

    def test_source_must_be_committed_readable_and_unchanged(self):
        self.status = "?? infra/terraform/demo/extra.tf\n"
        self.assertIn("PG0 uncommitted Demo source", self.gate(PLAN)[2])
        self.status, self.git_exit = "", 1
        self.assertIn("PG0 Git source state unreadable", self.gate(PLAN)[2])
        self.git_exit, self.commits = 0, ["not-a-commit"]
        self.assertIn("PG0 source commit", self.gate(PLAN)[2])
        self.commits = [self.COMMIT, "b" * 40]
        self.assertIn("PG0 source changed during the gate", self.gate(PLAN)[2])

    def test_wrong_account_and_invalid_plan_reject(self):
        self.assertEqual(self.gate(PLAN, hashlib.sha256(b"111111111111").hexdigest())[0], 1)
        plan = copy.deepcopy(PLAN)
        resource(plan, "aws_dynamodb_table.runtime_control")["change"]["actions"] = ["delete", "create"]
        self.show_plan = plan
        code, out, err, _, _ = self.gate(plan)
        self.assertEqual((code, out), (1, ""))
        self.assertIn("REJECT", err)

    def test_source_that_switches_a_schedule_or_rule_on_still_fails(self):
        # The source itself is changed consistently (every instance of the
        # block, its configuration and its rendered value), so only the
        # source-independent inert check can still reject it.
        for base in ("aws_scheduler_schedule.runtime_orchestration", "aws_cloudwatch_event_rule.spot_capacity_unavailable"):
            rendered = copy.deepcopy(RENDERED)
            plan = copy.deepcopy(PLAN)
            for address in [a for a in rendered["resources"] if a.split("[")[0] == base]:
                rendered["resources"][address]["state"] = "ENABLED"
                after(plan, address)["state"] = "ENABLED"
            configuration(plan, base)["expressions"]["state"] = cfg(rendered["expressions"][base]["state"], "ENABLED")
            synchronize(plan)
            with self.assertRaises(G.Rejected) as rejected:
                G.validate(plan, rendered)
            self.assertEqual(str(rejected.exception), "PG5 new schedule/rule not DISABLED")

    def test_p3a2_mode_records_the_same_evidence_and_rejects_the_p3a_plan(self):
        self.show_plan = p3a2_plan()
        with tempfile.TemporaryDirectory(prefix="p3a2-MOCK-plan-") as temporary:
            saved, path = self.files(temporary, self.show_plan)
            code, out, err = self.call("p3a2", str(saved), str(path), ACCOUNT_SHA)
            self.assertEqual((code, err), (0, ""))
            result = json.loads(out)
            self.assertEqual((result["mode"], result["changes"], result["destroys"]), ("p3a2", 2, 1))
            self.assertEqual(result["saved_plan_sha256"], hashlib.sha256(saved.read_bytes()).hexdigest())
            self.assertEqual(result["source_commit"], self.COMMIT)
            code, out, err = self.call("p3a", str(saved), str(path), ACCOUNT_SHA)
            self.assertEqual(code, 1)
        self.show_plan = PLAN
        with tempfile.TemporaryDirectory(prefix="p3a2-MOCK-plan-") as temporary:
            saved, path = self.files(temporary, PLAN)
            code, out, err = self.call("p3a2", str(saved), str(path), ACCOUNT_SHA)
            self.assertEqual(code, 1)
            self.assertIn("P3A2 exact 2 updates and 1 delete", err)

    def test_p3a2_first_refresh_passes_only_in_the_p3a2_mode_and_keeps_the_bindings(self):
        self.show_plan = p3a2_plan()
        for address in sorted(FIRST_REFRESH_ADDRESSES):
            add_first_refresh(self.show_plan, address)
        add_approved_refresh(self.show_plan)
        with tempfile.TemporaryDirectory(prefix="p3a2-MOCK-plan-") as temporary:
            saved, path = self.files(temporary, self.show_plan)
            code, out, err = self.call("p3a2", str(saved), str(path), ACCOUNT_SHA)
            self.assertEqual((code, err), (0, ""))
            result = json.loads(out)
            self.assertEqual((result["creates"], result["changes"], result["destroys"]), (0, 2, 1))
            self.assertEqual(result["saved_plan_sha256"], hashlib.sha256(saved.read_bytes()).hexdigest())
            self.assertEqual(result["plan_json_sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
            self.assertEqual((result["source_commit"], result["approved_account_sha256"]), (self.COMMIT, ACCOUNT_SHA))
            code, out, err = self.call("p3a", str(saved), str(path), ACCOUNT_SHA)
            self.assertEqual(code, 1)
            code, out, err = self.call("p3a2", str(saved), str(path), hashlib.sha256(b"111111111111").hexdigest())
            self.assertEqual(code, 1)
        self.show_plan = PLAN

    def test_verify_before_apply(self):
        with tempfile.TemporaryDirectory(prefix="p3a-MOCK-plan-") as temporary:
            saved, _ = self.files(temporary, PLAN)
            digest = hashlib.sha256(saved.read_bytes()).hexdigest()
            code, out, _ = self.call("verify", str(saved), digest, self.COMMIT)
            self.assertEqual(code, 0)
            self.assertEqual(json.loads(out)["result"], "VERIFIED")
            self.assertIn("PG0 saved plan changed since review", self.call("verify", str(saved), "b" * 64, self.COMMIT)[2])
            self.assertIn("PG0 saved plan changed since review", self.call("verify", str(saved), digest[:-1], self.COMMIT)[2])
            self.assertIn("PG0 source commit changed since review", self.call("verify", str(saved), digest, "b" * 40)[2])
            self.status = " M infra/terraform/demo/runtime_iam.tf\n"
            self.assertIn("PG0 uncommitted Demo source", self.call("verify", str(saved), digest, self.COMMIT)[2])
            saved.write_bytes(b"changed after review")
            self.assertEqual(self.call("verify", str(saved), digest, self.COMMIT)[0], 1)

    def test_usage_and_extra_arguments_rejected(self):
        for argv in ([], ["p3a"], ["p3a", "saved", "plan.json"], ["p3c", "saved", "plan.json", ACCOUNT_SHA],
                     ["p3a", "saved", "plan.json", ACCOUNT_SHA, "--allow"], ["verify", "saved", "a" * 64]):
            self.assertEqual(self.call(*argv)[0], 2)

    def test_symlink_and_missing_files_rejected(self):
        with tempfile.TemporaryDirectory(prefix="p3a-MOCK-plan-") as temporary:
            saved, path = self.files(temporary, PLAN)
            for name, target in (("saved-link.tfplan", saved), ("plan-link.json", path)):
                (Path(temporary) / name).symlink_to(target)
            absent = str(Path(temporary) / "absent")
            self.assertIn("PG0 saved plan is not a regular file", self.call("p3a", str(Path(temporary) / "saved-link.tfplan"), str(path), ACCOUNT_SHA)[2])
            self.assertIn("PG0 plan JSON is not a regular file", self.call("p3a", str(saved), str(Path(temporary) / "plan-link.json"), ACCOUNT_SHA)[2])
            self.assertEqual(self.call("p3a", absent, str(path), ACCOUNT_SHA)[0], 1)
            self.assertIn("PG0 saved plan is not a regular file", self.call("verify", str(Path(temporary) / "saved-link.tfplan"), "a" * 64, self.COMMIT)[2])

    def test_gate_does_not_depend_on_the_p3a_approval_machinery(self):
        source = (HERE / "cold-standby-plan-gate.py").read_text()
        for name in ("capture", "bridge", "live", "trust", "proof", "sdk", "apply-preflight"):
            self.assertNotIn("cold-standby-plan-" + name, source)
        for name in ("capture", "bridge", "live", "trust", "proof", "sdk-worker", "apply-preflight"):
            self.assertFalse((HERE / ("cold-standby-plan-" + name + ".py")).exists())


def suite():
    return unittest.TestSuite([unittest.defaultTestLoader.loadTestsFromTestCase(FixtureTests),
                               unittest.defaultTestLoader.loadTestsFromTestCase(RevisionTests),
                               unittest.defaultTestLoader.loadTestsFromTestCase(P3a2Tests),
                               unittest.defaultTestLoader.loadTestsFromTestCase(P3a2FirstRefreshTests),
                               unittest.defaultTestLoader.loadTestsFromTestCase(EntryTests)])


SCOPE_MUTATIONS = [
    ("the p3a2 mode ignores the rules", 'drift_check(plan, P3A2_DRIFT_RULES)', 'drift_check(plan)'),
    ("the p3a mode uses the rules", '    drift_check(plan)\n', '    drift_check(plan, P3A2_DRIFT_RULES)\n'),
    ("every NEW resource may drift", 'check(address in first_refresh or (address in DRIFT and address not in NEW)', 'check(address in first_refresh or address in NEW or (address in DRIFT and address not in NEW)'),
    ("the rules accept any address", 'check(address in first_refresh or (address in DRIFT and address not in NEW)', 'check(first_refresh or (address in DRIFT and address not in NEW)'),
    ("the general allowlist admits NEW", 'check(address in first_refresh or (address in DRIFT and address not in NEW)', 'check(address in first_refresh or address in DRIFT'),
    ("a sixth address in the rules", 'P3A2_DRIFT_RULES = ADDRESSES["P3A2_DRIFT_RULES"]', 'P3A2_DRIFT_RULES = {**ADDRESSES["P3A2_DRIFT_RULES"], "aws_iam_role.ecs_spot": {"fields": ["inline_policy"], "observed_inline_policy": "aws_iam_role_policy.ecs_spot_origin_eip_promotion", "policy_name": "origin-eip-promotion"}}'),
    ("a rule removed", 'P3A2_DRIFT_RULES = ADDRESSES["P3A2_DRIFT_RULES"]', 'P3A2_DRIFT_RULES = {k: v for k, v in ADDRESSES["P3A2_DRIFT_RULES"].items() if k != "aws_ssm_document.spot_smoke"}'),
    ("the rules allow any field", 'allowed = first_refresh[address]["fields"] if address in first_refresh else DRIFT.get(address, ())', 'allowed = changed if address in first_refresh else DRIFT.get(address, ())'),
    ("inline: more fields than inline_policy", 'check(changed == {"inline_policy"} and before["inline_policy"] == []', 'check(before["inline_policy"] == []'),
    ("inline: a stored policy before", 'changed == {"inline_policy"} and before["inline_policy"] == [] and', 'changed == {"inline_policy"} and'),
    ("inline: more than one policy", 'len(after["inline_policy"]) == 1 and\n', 'len(after["inline_policy"]) >= 1 and\n'),
    ("inline: observation keys", 'check(set(observation) == {"name", "policy"} and ', 'check('),
    ("inline: name against the separate policy", 'observation["name"] == policy.get("name") == rule["policy_name"]', 'policy.get("name") == rule["policy_name"]'),
    ("inline: name against the rule", 'observation["name"] == policy.get("name") == rule["policy_name"]', 'observation["name"] == policy.get("name")'),
    ("inline: the role of the separate policy", 'policy.get("role") == after.get("name") and\n', '\n'),
    ("inline: the separate policy changes", 'policy_change.get("actions") == ["no-op"] and policy_change.get("before")', 'policy_change.get("before")'),
    ("document: more fields than permissions", 'check(changed == {"permissions"} and before.get("permissions") is None and', 'check(before.get("permissions") is None and'),
    ("document: stored permissions before", 'changed == {"permissions"} and before.get("permissions") is None and', 'changed == {"permissions"} and'),
    ("document: any value after", 'after.get("permissions") == {} and after.get("name")', 'after.get("name")'),
    ("document: any name", 'and after.get("name") == rule["empty_permissions_document"], "PG4 document permissions")', ', "PG4 document permissions")'),
]


def mutations():
    global G
    source = (HERE / "cold-standby-plan-gate.py").read_text()
    tree = ast.parse(source)
    # Select every check guard that the behavioural fixtures exercise. A few
    # generic input-shape/duplicate guards are covered by negative fixtures but
    # not mutated when removing them merely causes an earlier Python shape
    # failure. No malformed mutant counts as killed.
    selected = {"PG0 refreshed caller account mismatch", "PG0 caller provider binding", "PG0 provider credential override",
                "PG0 plan JSON is not a regular file", "PG0 saved plan is not a regular file", "PG0 terraform show of the saved plan failed",
                "PG0 plan JSON is not the saved plan", "PG0 Git source state unreadable", "PG0 source commit", "PG0 uncommitted Demo source",
                "PG0 source changed during the gate", "PG0 saved plan changed since review", "PG0 source commit changed since review",
                "PG5 new schedule/rule not DISABLED",
                "PG4 drift action/unknown", "PG4 drift refreshed no-op binding", "PG4 exact null-to-empty normalization", "PG4 inline observation shape",
                "PG4 inline separate-policy binding", "PG4 inline policy content", "PG4 configured inline policy", "PG4 backstop schedule contract", "PG4 backstop unconfigured time", "PG4 backstop next occurrence",
                "PG0 plan format/version", "PG0 incomplete plan", "PG0 errored plan", "PG0 non-applyable plan",
                "PG1 replace/delete/update", "PG1 import/move", "PG2 wrong/incomplete root", "PG2 all prior resources represented",
                "PG2 planned resource coverage", "PG2 planned value inconsistency", "PG3 output changed", "PG3 output snapshot changed",
                "PG4 unexpected drift", "PG4 document permissions", "PG4 configured document permissions",
                "PG4 unexpected drift fields", "PG5 configuration provider/mode", "PG5 for_each mapping", "PG5 SM logging/tracing/version",
                "PG5 table extras", "PG5 shared SSM document", "PG5 target extras", "PG5 role extra permissions", "PG0 instance context", "PG0 ENI context", "PG0 EIP context", "PG0 unapproved account", "PG0 planned caller account mismatch",
                "PG0 database scope", "PG0 ASG scope", "PG0 CloudFront context", "PG2 unknown leaf has concrete value"}
    # "PG5 computed setting with a planned value " and "PG5 computed setting
    # configured " are not mutated: an unknown leaf with a value is rejected by
    # PG2 first, and a configured setting by the exact configuration match and
    # the reviewed values; they stay as a second line.
    prefixes = {"PG2 existing changed ", "PG2 existing unknown/moved", "PG5 configuration references ", "PG5 configuration constant ", "PG5 configuration block ",
                "PG5 unexpected unknown ", "PG5 partially unknown computed setting ",
                "PG5 configuration attributes ", "PG5 unverifiable unknown ", "PG5 reviewed JSON content ", "PG5 reviewed source value ", "PG5 reviewed source collection ", "PG0 scope "}
    chosen = []
    for call in ast.walk(tree):
        if not isinstance(call, ast.Call) or not isinstance(call.func, ast.Name) or call.func.id != "check" or len(call.args) != 2:
            continue
        message = call.args[1]
        code = message.value if isinstance(message, ast.Constant) else message.left.value if isinstance(message, ast.BinOp) and isinstance(message.left, ast.Constant) else None
        if code in selected or code in prefixes or (code or "").startswith("P3A2 "):
            chosen.append((call, code))
    revision_codes = {"PG0 refreshed caller account mismatch", "PG0 caller provider binding", "PG0 provider credential override",
                      "PG4 unexpected drift", "PG4 document permissions", "PG4 configured document permissions",
                      "PG4 drift action/unknown", "PG4 drift refreshed no-op binding", "PG4 exact null-to-empty normalization", "PG4 inline observation shape",
                      "PG4 inline separate-policy binding", "PG4 inline policy content", "PG4 configured inline policy", "PG4 backstop schedule contract", "PG4 backstop unconfigured time", "PG4 backstop next occurrence"}
    killed, survived = [], []
    lines = source.splitlines(keepends=True)
    def run(mutated, code, collection):
        global G
        subject = types.ModuleType("p3a_gate_mutant")
        subject.__file__ = str(HERE / "cold-standby-plan-gate.py")
        exec(compile(mutated, "<syntactically-valid-offline-mutant>", "exec"), subject.__dict__)
        G = subject
        result = unittest.TextTestRunner(stream=io.StringIO(), verbosity=0).run(suite())
        # A killed guard must allow an invalid fixture through (an assertion
        # failure). A mere malformed-shape exception is not a meaningful kill.
        (collection if result.failures else survived).append(code)
    for call, code in chosen:
        condition = call.args[0]
        start = sum(map(len, lines[:condition.lineno - 1])) + condition.col_offset
        end = sum(map(len, lines[:condition.end_lineno - 1])) + condition.end_col_offset
        run(source[:start] + "True" + source[end:], code, killed)
    # The scope of the first-refresh rules and each condition inside their guards,
    # which replacing a whole guard cannot tell apart.
    scope_killed = []
    for label, old, new in SCOPE_MUTATIONS:
        if source.count(old) != 1:
            raise AssertionError("scope mutation does not match once: " + label)
        run(source.replace(old, new), label, scope_killed)
    G = ORIGINAL
    control = unittest.TextTestRunner(stream=io.StringIO(), verbosity=0).run(suite())
    if not control.wasSuccessful():
        raise AssertionError("post-mutation unmodified control failed")
    print("Plan gate mutation: %d/%d killed" % (len(killed), len(chosen)))
    print("First-refresh scope mutation: %d/%d killed" % (len(scope_killed), len(SCOPE_MUTATIONS)))
    print("Original guards: %d/%d; R1 guards: %d/%d" % (
        sum(c not in revision_codes for c in killed), sum(c not in revision_codes for _, c in chosen),
        sum(c in revision_codes for c in killed), sum(c in revision_codes for _, c in chosen)))
    if survived:
        print("SURVIVED: " + ", ".join(survived))
        return 1
    return 0


if __name__ == "__main__":
    def offline_process_audit(event, arguments):
        if event == "subprocess.Popen":
            if arguments[1] != [ORIGINAL.exporter.TF_DEFAULT, "console", "-no-color"]:
                raise RuntimeError("offline tests forbid every subprocess except provider-free Terraform console")
        if event in ("socket.connect", "socket.getaddrinfo"):
            raise RuntimeError("offline tests forbid network access")
    sys.addaudithook(offline_process_audit)
    # Actual HCL is evaluated once; behavioural cases reuse the independent
    # console result. It is not a policy implementation copied into fixtures.
    RENDERED = ORIGINAL.exporter.export(ORIGINAL.exporter.fixture_context())
    PLAN = json.loads(json.dumps(make_plan(RENDERED)))
    REVISION_NEGATIVES = 0
    result = unittest.TextTestRunner(verbosity=2).run(suite())
    print("Fixture negative checks:", FIXTURE_CHECKS)
    print("R1 drift negative checks:", REVISION_NEGATIVES)
    print("Test cases:", suite().countTestCases())
    if not result.wasSuccessful():
        sys.exit(1)
    if len(sys.argv) == 2 and sys.argv[1] == "--mutation":
        sys.exit(mutations())
    if len(sys.argv) != 1:
        raise SystemExit("Only --mutation is accepted; no gate bypass or AWS execution mode")
