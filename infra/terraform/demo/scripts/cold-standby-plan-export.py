#!/usr/bin/env python3
"""Provider-free evaluation of the actual P3-a HCL expressions.

This is a deliberately narrow HCL block/attribute splitter, not an HCL
evaluator. Terraform console itself evaluates every expression, jsonencode and
templatefile. No provider, backend, init, plan, apply or state mutation is used.
Unsupported source syntax fails instead of being approximated.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

DEMO = Path(__file__).resolve().parent.parent
ROOT = DEMO.parents[2]
# The Terraform that renders the reviewed expressions. The saved plan itself is
# checked for 1.16.0 by the gate; a different renderer can only make the exact
# comparison fail, never pass.
TF_DEFAULT = os.environ.get("COLD_STANDBY_TERRAFORM") or shutil.which("terraform") or "terraform"
NEW_FILES = ("runtime_orchestration.tf", "runtime_iam.tf", "runtime_documents.tf")
REF = re.compile(r'(?:data\.[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*|aws_[A-Za-z0-9_]+\.[A-Za-z_][A-Za-z0-9_]*|local\.[A-Za-z_][A-Za-z0-9_]*|each\.(?:value|key)|path\.module)(?:\[(?:"[^"\n]+"|[0-9]+)\]|\.[A-Za-z_][A-Za-z0-9_]*)*')


def skip(text, pos):
    while pos < len(text):
        if text[pos].isspace():
            pos += 1
        elif text.startswith("#", pos) or text.startswith("//", pos):
            end = text.find("\n", pos)
            pos = len(text) if end < 0 else end + 1
        elif text.startswith("/*", pos):
            end = text.find("*/", pos + 2)
            if end < 0:
                raise ValueError("unclosed HCL comment")
            pos = end + 2
        else:
            break
    return pos


def expression(text, pos, closing=None):
    start = pos
    stack, quoted, escaped = [], False, False
    while pos < len(text):
        char = text[pos]
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
        elif text.startswith("#", pos) or text.startswith("//", pos):
            end = text.find("\n", pos)
            if not stack:
                return text[start:pos].strip(), len(text) if end < 0 else end + 1
            pos = len(text) if end < 0 else end
            continue
        elif char in "([{":
            stack.append(char)
        elif char in ")]}":
            if not stack:
                if closing == char:
                    return text[start:pos].strip(), pos
                raise ValueError("unbalanced HCL expression")
            expected = {"(": ")", "[": "]", "{": "}"}[stack.pop()]
            if expected != char:
                raise ValueError("mismatched HCL expression")
        elif char == "\n" and not stack:
            return text[start:pos].strip(), pos + 1
        pos += 1
    if quoted or stack:
        raise ValueError("unclosed HCL expression")
    return text[start:pos].strip(), pos


def body(text):
    attributes, blocks = {}, []
    pos = 0
    while True:
        pos = skip(text, pos)
        if pos >= len(text):
            return attributes, blocks
        found = re.match(r"[A-Za-z_][A-Za-z0-9_-]*", text[pos:])
        if not found:
            raise ValueError("unsupported HCL body near " + text[pos:pos + 30])
        name = found[0]
        pos = skip(text, pos + len(name))
        if pos < len(text) and text[pos] == "=":
            if name in attributes:
                raise ValueError("duplicate HCL attribute " + name)
            value, pos = expression(text, skip(text, pos + 1))
            attributes[name] = value
            continue
        labels = []
        while pos < len(text) and text[pos] == '"':
            decoder = json.JSONDecoder()
            value, length = decoder.raw_decode(text[pos:])
            labels.append(value)
            pos = skip(text, pos + length)
        if pos >= len(text) or text[pos] != "{":
            raise ValueError("unsupported HCL block " + name)
        value, end = expression(text, pos)
        # expression() includes the balanced brace and ends at newline.
        if not value.startswith("{") or not value.endswith("}"):
            raise ValueError("malformed HCL block " + name)
        blocks.append((name, labels, body(value[1:-1])))
        pos = end


def source():
    locals_list, resources = [], []
    for name in NEW_FILES:
        attrs, blocks = body((DEMO / name).read_text())
        if attrs:
            raise ValueError("unexpected root attributes")
        for kind, labels, contents in blocks:
            if kind == "locals" and not labels:
                if contents[1]:
                    raise ValueError("nested locals blocks")
                locals_list.append(contents[0])
            elif kind == "resource" and len(labels) == 2:
                resources.append((labels[0] + "." + labels[1], contents))
            else:
                raise ValueError("unexpected new source block " + kind)
    return locals_list, resources


def canonical_refs(refs):
    unique = set(refs)
    return sorted(r for r in unique if not any(other.startswith(r + ".") or other.startswith(r + "[") for other in unique if other != r))


def refs(expr):
    return canonical_refs(REF.findall(expr))


def replace_external(expr):
    return re.sub(r"(?<![A-Za-z0-9_])(?:data\.[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*|aws_[A-Za-z0-9_]+\.[A-Za-z_][A-Za-z0-9_]*)", lambda m: "local.context." + m[0], expr)


def object_expression(contents):
    attributes, blocks = contents
    result = [json.dumps(key) + " = " + replace_external(value) for key, value in attributes.items() if key not in ("for_each", "depends_on")]
    grouped = {}
    for name, labels, nested in blocks:
        if name == "lifecycle":
            continue
        if labels or name == "dynamic":
            raise ValueError("unsupported labelled/dynamic resource block")
        grouped.setdefault(name, []).append(object_expression(nested))
    result += [json.dumps(name) + " = [" + ",".join(items) + "]" for name, items in grouped.items()]
    return "{\n" + "\n".join(result) + "\n}"


def expression_contract(contents):
    attrs, blocks = contents
    result = {key: {"refs": refs(value)} for key, value in attrs.items() if key not in ("for_each", "depends_on")}
    for name, labels, nested in blocks:
        if name != "lifecycle":
            result.setdefault(name, []).append(expression_contract(nested))
    return result


def one_line(text):
    result, quoted, escaped, pos = [], False, False, 0
    while pos < len(text):
        char = text[pos]
        if not quoted and (char == "#" or text.startswith("//", pos)):
            end = text.find("\n", pos)
            pos = len(text) if end < 0 else end
            continue
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
        result.append(" " if char == "\n" else char)
        pos += 1
    return "".join(result)


def fixture_context(account="000000000000"):
    arn = lambda service, resource: "arn:aws:" + service + ":ap-northeast-1:" + account + ":" + resource
    return {
        "data": {"aws_partition": {"current": {"partition": "aws"}}, "aws_caller_identity": {"current": {"account_id": account}}},
        "aws_instance": {"demo": {"id": "i-00000000000000001", "arn": arn("ec2", "instance/i-00000000000000001"), "primary_network_interface_id": "eni-00000000000000001"}},
        "aws_eip": {"ec2_origin": {"allocation_id": "eipalloc-00000000000000001", "public_ip": "192.0.2.1"}},
        "aws_db_instance": {"demo": {"identifier": "ec-portfolio-demo-mariadb", "arn": arn("rds", "db:ec-portfolio-demo-mariadb")}},
        "aws_ecs_cluster": {"demo": {"arn": arn("ecs", "cluster/ec-portfolio-demo")}},
        "aws_ecs_service": {"api": {"id": arn("ecs", "service/ec-portfolio-demo/ec-portfolio-demo-api"), "name": "ec-portfolio-demo-api"}},
        "aws_autoscaling_group": {"ecs_spot": {"name": "ec-portfolio-demo-ecs-spot", "arn": arn("autoscaling", "autoScalingGroup:00000000-0000-0000-0000-000000000000:autoScalingGroupName/ec-portfolio-demo-ecs-spot")}},
        "aws_iam_instance_profile": {"ecs_spot": {"arn": "arn:aws:iam::" + account + ":instance-profile/ec-portfolio-demo-ecs-spot"}, "ec2": {"arn": "arn:aws:iam::" + account + ":instance-profile/ec-portfolio-demo-ec2"}},
        "aws_ecr_repository": {"demo_api": {"repository_url": account + ".dkr.ecr.ap-northeast-1.amazonaws.com/ec-portfolio-demo-api"}},
        "aws_cloudfront_distribution": {"api": {"domain_name": "dexample.cloudfront.net"}},
        "aws_ssm_parameter": {"deploy_desired_image_sha": {"name": "/ec-portfolio/demo/deploy/desired-image-sha", "arn": arn("ssm", "parameter/ec-portfolio/demo/deploy/desired-image-sha")}},
        "aws_scheduler_schedule_group": {"runtime": {"name": "ec-portfolio-demo-runtime"}},
        "aws_iam_role": {"scheduler": {"arn": "arn:aws:iam::" + account + ":role/ec-portfolio-demo-scheduler"}},
        "aws_sns_topic": {"alerts": {"arn": arn("sns", "ec-portfolio-demo-alerts")}},
    }


def complete_context(context):
    context = json.loads(json.dumps(context))
    account = context["data"]["aws_caller_identity"]["current"]["account_id"]
    for key, suffix in (("runtime_orchestrator", "orchestrator"), ("runtime_eip_writer", "eip-writer"), ("runtime_events", "events")):
        context.setdefault("aws_iam_role", {})[key] = {"id": "ec-portfolio-demo-runtime-" + suffix, "arn": "arn:aws:iam::" + account + ":role/ec-portfolio-demo-runtime-" + suffix}
    keys = ("day_open", "ready_check", "day_close", "origin_guard", "od_standby")
    context["aws_sfn_state_machine"] = {"runtime": {key: {"arn": "arn:aws:states:ap-northeast-1:" + account + ":stateMachine:ec-portfolio-demo-" + key.replace("_", "-")} for key in keys}}
    context["aws_cloudwatch_event_rule"] = {key: {"name": "ec-portfolio-demo-" + key.replace("_", "-")} for key in ("origin_guard_signals", "spot_capacity_unavailable", "runtime_orchestration_failed")}
    return context


def export(context, terraform=TF_DEFAULT):
    locals_list, resources = source()
    # These are the actual existing HCL declarations used by new expressions.
    base = {}
    for filename, wanted in (("locals.tf", {"name_prefix", "aws_region", "ecs_spot_name"}), ("ecs_application.tf", {"ecs_api_image_sha"})):
        _, blocks = body((DEMO / filename).read_text())
        for kind, labels, contents in blocks:
            if kind == "locals":
                base.update({k: v for k, v in contents[0].items() if k in wanted})
    if set(base) != {"name_prefix", "aws_region", "ecs_spot_name", "ecs_api_image_sha"}:
        raise ValueError("missing actual base locals")
    context = complete_context(context)
    fragments = ["locals {\n context = jsondecode(" + json.dumps(json.dumps(context)) + ")\n" + "\n".join(k + " = " + v for k, v in base.items()) + "\n}"]
    for values in locals_list:
        fragments.append("locals {\n" + "\n".join(k + " = " + replace_external(v) for k, v in values.items()) + "\n}")
    outputs, expressions = [], {}
    for address, contents in resources:
        attrs = contents[0]
        object_expr = object_expression(contents)
        if "for_each" in attrs:
            object_expr = re.sub(r"\beach\.value\b", "value", object_expr)
            object_expr = re.sub(r"\beach\.key\b", "key", object_expr)
            outputs.append("[for key, value in " + attrs["for_each"] + " : { address = format(" + json.dumps(address + "[%s]") + ", jsonencode(key)), values = " + object_expr + " }]")
        else:
            outputs.append("[{ address = " + json.dumps(address) + ", values = " + object_expr + " }]")
        expressions[address] = expression_contract(contents)
    fragments.append("locals {\nreviewed_output = flatten([" + ",".join(outputs) + "])\n}\n")
    query = "jsonencode(local.reviewed_output)\n"
    with tempfile.TemporaryDirectory(prefix="p3a-providerless-console-") as temporary:
        directory = Path(temporary)
        for asset in ("state-machines", "ssm-documents"):
            shutil.copytree(DEMO / asset, directory / asset)
        (directory / "main.tf").write_text("\n".join(fragments))
        environment = {"PATH": "/usr/bin:/bin", "HOME": str(directory), "TF_IN_AUTOMATION": "1", "TF_CLI_CONFIG_FILE": str(directory / "empty.tfrc"), "AWS_EC2_METADATA_DISABLED": "true", "HTTPS_PROXY": "http://127.0.0.1:9", "HTTP_PROXY": "http://127.0.0.1:9"}
        (directory / "empty.tfrc").write_text("disable_checkpoint = true\n")
        result = subprocess.run([terraform, "console", "-no-color"], input=query.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=directory, env=environment, timeout=60)
        if result.returncode or b"Error:" in result.stderr:
            raise ValueError("provider-free source evaluation failed; no expected contract produced")
        if list(directory.glob("*.tfstate*")) or (directory / ".terraform").exists():
            raise ValueError("unexpected state/provider artifact from console")
        values = json.loads(json.loads(result.stdout.decode()))
    return {"resources": {entry["address"]: entry["values"] for entry in values}, "expressions": expressions}


if __name__ == "__main__":
    import sys
    if len(sys.argv) == 2 and sys.argv[1] == "fixture":
        print(json.dumps(export(fixture_context()), indent=2, sort_keys=True))
    else:
        raise SystemExit("Usage: cold-standby-plan-export.py fixture (offline only)")
