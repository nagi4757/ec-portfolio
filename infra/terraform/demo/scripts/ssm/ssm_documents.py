#!/usr/bin/env python3
"""Build the two JSON-subset YAML documents without a YAML dependency.

Only offline source generation. No SSM, shell command or network execution.
The approved shell contains no SSM textual interpolation; ENV_VAR support is
required (SSM Agent >=3.3.2746.0). An older agent leaves required vars unset and
fails before Python instead of falling back to interpolated shell text.
"""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PARAMETERS = {
    "expectedImageSha": {"type": "String", "description": "Exact live production TD immutable API image SHA", "allowedPattern": "^[0-9a-f]{40}$", "interpolationType": "ENV_VAR"},
    "expectedImageRepository": {"type": "String", "description": "Exact production ECR repository from the reviewed runtime definition", "allowedPattern": "^[0-9]{12}\\.dkr\\.ecr\\.ap-northeast-1\\.amazonaws\\.com/ec-portfolio-demo-api$", "interpolationType": "ENV_VAR"},
    "expectedTaskDefinitionArn": {"type": "String", "description": "Exact currently live production ECS task definition revision", "allowedPattern": "^arn:aws:ecs:ap-northeast-1:[0-9]{12}:task-definition/ec-portfolio-demo-api:[1-9][0-9]{0,9}$", "interpolationType": "ENV_VAR"},
    "checkMode": {"type": "String", "description": "local before promotion; endToEnd only after EIP association", "allowedValues": ["local", "endToEnd"], "default": "local", "interpolationType": "ENV_VAR"},
    "cloudFrontDomain": {"type": "String", "description": "Reviewed distribution domain, supplied by the state machine, never an arbitrary URL", "allowedPattern": "^d[a-z0-9]{1,62}\\.cloudfront\\.net$", "interpolationType": "ENV_VAR"},
}


def document(kind):
    assert kind in ("od", "spot")
    source = (Path(__file__).resolve().with_name("ssm_runtime.py")).read_text()
    parameters = " ".join('SSM_' + name + '="$SSM_' + name + '"' for name in PARAMETERS)
    command = ("set -eu\n"
               "# No fallback textual interpolation, eval, secret output or host mutation.\n"
               "exec env -i PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin HOME=/root LANG=C.UTF-8 " +
               parameters + " python3 -I - " + kind + " <<'P3A_REVIEWED_PYTHON'\n" + source +
               "P3A_REVIEWED_PYTHON\n")
    return {"schemaVersion": "2.2", "description": "Demo " + kind + ": read-only exact image/TLS/origin/CloudFront readiness; no repair or deployment",
            "parameters": PARAMETERS,
            "mainSteps": [{"action": "aws:runShellScript", "name": "readiness", "precondition": {"StringEquals": ["platformType", "Linux"]},
                           "inputs": {"timeoutSeconds": "300", "runCommand": [command]}}]}


def main():
    for kind, name in (("od", "od-readiness.yaml"), ("spot", "spot-smoke.yaml")):
        destination = ROOT / "ssm-documents" / name
        destination.write_text(json.dumps(document(kind), indent=2) + "\n")
        print("generated " + str(destination.relative_to(ROOT)))


if __name__ == "__main__":
    main()
