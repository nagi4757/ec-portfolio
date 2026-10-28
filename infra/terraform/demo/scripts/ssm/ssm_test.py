#!/usr/bin/env python3
"""Offline document, host-fixture and mutation checks; zero subprocess AWS calls.

Mutation runs the same behavioural fixtures against altered production code.
All transport/command access is replaced by FakeHost, never a real Host.
"""
import ast
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import types
import unittest
from unittest import mock

sys.dont_write_bytecode = True
import ssm_documents as documents
import ssm_runtime as runtime

ROOT = Path(__file__).resolve().parents[2]
MODULE = runtime
FIXTURE_ACCOUNT = "000000000000"
ENV = {"SSM_expectedImageSha": "a" * 40,
       "SSM_expectedImageRepository": FIXTURE_ACCOUNT + ".dkr.ecr.ap-northeast-1.amazonaws.com/ec-portfolio-demo-api",
       "SSM_expectedTaskDefinitionArn": "arn:aws:ecs:ap-northeast-1:" + FIXTURE_ACCOUNT + ":task-definition/ec-portfolio-demo-api:23",
       "SSM_checkMode": "local", "SSM_cloudFrontDomain": "dexample.cloudfront.net"}
TOKEN = "MOCK_SECRET_MUST_NEVER_BE_LOGGED_123456789"
CONTAINER_ID = "abcdef012345"


class FakeHost:
    def __init__(self):
        self.calls = []
        self.converge = "Result=success\nExecMainStatus=0\nExecMainStartTimestampMonotonic=100\nActiveState=inactive\n"
        self.api = {"State": {"Running": True}, "Config": {"Image": ENV["SSM_expectedImageRepository"] + ":" + "a" * 40,
                    "Labels": {"com.amazonaws.ecs.cluster": "ec-portfolio-demo", "com.amazonaws.ecs.task-definition-family": "ec-portfolio-demo-api",
                               "com.amazonaws.ecs.task-definition-version": "23"}},
                    "NetworkSettings": {"Ports": {"8080/tcp": [{"HostIp": "127.0.0.1", "HostPort": "8080"}]}},
                    "HostConfig": {"NetworkMode": "host"}}
        self.valkey = {"State": {"Running": True}, "NetworkSettings": {"Ports": {"6379/tcp": None}}}
        self.docker_ids = CONTAINER_ID + "\n"
        self.markers = True
        self.fail_command = None
        self.http80 = ""
        self.ipv4 = {}
        self.ipv6 = ""
        self.health = {"status": "UP", "components": {"readinessState": {"status": "UP"}, "db": {"status": "UP"}, "redis": {"status": "UP"}}}
        self.readiness_status = 200
        self.origin_denied = 403
        self.origin_invalid = 403
        self.origin_valid = 200
        self.origin_tls = True
        self.public_status = 200
        self.public_body = "[]"
        self.echo = True
        self.duplicate_echo = False
        self.log_present = True
        self.log_duplicate = False
        self.log_change = {}
        self.log_delay = 0
        self.log_reads = 0
        self.last_correlation = ""
        self.inspect_shape = None

    def command(self, argv, timeout=20):
        self.calls.append(("command", argv))
        if self.fail_command and self.fail_command in argv:
            raise MODULE.CheckFailure("mock-command-failed")
        if argv[:2] == ["systemctl", "show"]:
            return self.converge
        if argv[:2] == ["systemctl", "is-active"]:
            return ""
        if argv[:2] == ["docker", "ps"]:
            return self.docker_ids
        if argv[:2] == ["docker", "inspect"]:
            if self.inspect_shape is not None:
                return json.dumps(self.inspect_shape)
            return json.dumps([self.valkey if argv[2] == "ec-portfolio-demo-valkey" else self.api])
        if argv[:2] == ["docker", "logs"]:
            self.log_reads += 1
            if not self.log_present or self.log_reads <= self.log_delay:
                return ""
            record = {"correlationId": self.last_correlation, "httpMethod": "GET", "requestPath": "/api/public/categories", "httpStatus": 200, "message": "HTTP request completed"}
            record.update(self.log_change)
            result = json.dumps(record) + "\n"
            return result * (2 if self.log_duplicate else 1)
        if argv[0] == "ss":
            port = argv[-1].split(":")[-1]
            if port == "80":
                return self.http80
            if "-ltn6" in argv:
                return self.ipv6
            return self.ipv4.get(port, "LISTEN 0 100 127.0.0.1:" + port + " 0.0.0.0:*\n")
        raise AssertionError("Unmocked command: " + repr(argv))

    def exists(self, path):
        self.calls.append(("exists", path))
        return self.markers

    def token(self):
        self.calls.append(("token",))
        return TOKEN

    def pause(self):
        self.calls.append(("pause",))

    def request(self, domain, path, headers=None, local_tls=False):
        # Only the fixed, reviewed HTTP routes may be used by production code.
        self.calls.append(("request", domain, path, local_tls))
        assert domain in ("127.0.0.1", "origin-demo.yoonec.dev", "dexample.cloudfront.net")
        assert path == "/actuator/health/readiness" or path.startswith("/api/public/categories?p3probe=")
        if local_tls:
            if not self.origin_tls:
                raise MODULE.CheckFailure("mock-tls-failed")
            if (headers or {}).get("X-Origin-Verify") != TOKEN:
                return (self.origin_invalid if headers else self.origin_denied), [], "DENIED"
            return self.origin_valid, [], json.dumps(self.health)
        if path.startswith("/api/public/categories"):
            self.last_correlation = headers["X-Correlation-ID"]
            echoed = [("X-Correlation-ID", self.last_correlation if self.echo else "wrong-host")]
            if self.duplicate_echo:
                echoed *= 2
            return self.public_status, echoed, self.public_body
        return self.readiness_status, [], json.dumps(self.health)


class HostChecks(unittest.TestCase):
    def run_check(self, kind="od", host=None, mode="local", env=None):
        values = dict(ENV if env is None else env)
        values["SSM_checkMode"] = mode
        return MODULE.check(kind, values, host or FakeHost(), now=1700000000)

    def reject(self, mutate, kind="od", mode="local", code=None):
        host = FakeHost()
        mutate(host)
        with self.assertRaises(MODULE.CheckFailure) as err:
            self.run_check(kind, host, mode)
        if code:
            self.assertEqual(str(err.exception), code)

    def test_local_and_e2e_success_both_hosts(self):
        for kind in ("od", "spot"):
            for mode in ("local", "endToEnd"):
                with self.subTest(kind=kind, mode=mode):
                    host = FakeHost()
                    result = self.run_check(kind, host, mode)
                    self.assertEqual(result["result"], "PASS")
                    self.assertEqual(result["imageSha"], "a" * 40)
                    self.assertEqual(any(c[0] == "command" and c[1][:2] == ["docker", "logs"] for c in host.calls), mode == "endToEnd")
                    self.assertNotIn(TOKEN, json.dumps(result))

    def test_missing_env_every_parameter(self):
        for key in ENV:
            env = dict(ENV)
            del env[key]
            with self.subTest(key=key), self.assertRaises(MODULE.CheckFailure):
                MODULE.parameters(env)

    def test_parameter_injections(self):
        for key in ENV:
            for value in ("$(touch /tmp/P3A-MUST-NOT-EXIST)", "'; exit 0; #", "value\nextra", ""):
                env = dict(ENV, **{key: value})
                with self.subTest(key=key, value=value), self.assertRaises(MODULE.CheckFailure):
                    MODULE.parameters(env)

    def test_parameters_exact_scope(self):
        for key, value in (("SSM_expectedImageSha", "A" * 40), ("SSM_expectedImageSha", "a" * 41),
                           ("SSM_expectedImageRepository", ENV["SSM_expectedImageRepository"].replace("-api", "-api-measure")),
                           ("SSM_expectedTaskDefinitionArn", ENV["SSM_expectedTaskDefinitionArn"].replace("000000000000", "111111111111")),
                           ("SSM_expectedTaskDefinitionArn", ENV["SSM_expectedTaskDefinitionArn"].replace(":23", ":0")),
                           ("SSM_cloudFrontDomain", "https://dexample.cloudfront.net"), ("SSM_cloudFrontDomain", "dexample.cloudfront.net.attacker.test")):
            with self.subTest(key=key, value=value), self.assertRaises(MODULE.CheckFailure):
                MODULE.parameters(dict(ENV, **{key: value}))

    def test_convergence_failed_not_completed_or_never_ran(self):
        for before, after in (("Result=success", "Result=exit-code"), ("ExecMainStatus=0", "ExecMainStatus=1"),
                              ("Monotonic=100", "Monotonic=0"), ("ActiveState=inactive", "ActiveState=activating")):
            self.reject(lambda h: setattr(h, "converge", h.converge.replace(before, after)), code="convergence-not-successful-this-boot")

    def test_convergence_duplicate_field(self):
        self.reject(lambda h: setattr(h, "converge", h.converge + "Result=success\n"))
        self.reject(lambda h: setattr(h, "converge", h.converge + "not-a-property\n"))

    def test_invalid_kind_and_inspect_shape(self):
        with self.assertRaises(MODULE.CheckFailure):
            self.run_check("measure")
        for shape in ([], [{}, {}], {}):
            self.reject(lambda h: setattr(h, "inspect_shape", shape))

    def test_images_must_match_exact_repository_and_sha(self):
        for kind in ("od", "spot"):
            for image in (ENV["SSM_expectedImageRepository"] + ":" + "b" * 40, "attacker/image:" + "a" * 40):
                self.reject(lambda h: h.api["Config"].update(Image=image), kind, code="running-image-mismatch")

    def test_running_and_valkey(self):
        self.reject(lambda h: h.api["State"].update(Running=False), code="api-not-running")
        self.reject(lambda h: h.valkey["State"].update(Running=False), code="valkey-not-running")
        self.reject(lambda h: h.valkey["NetworkSettings"]["Ports"].update({"6379/tcp": [{"HostIp": "0.0.0.0", "HostPort": "6379"}]}), code="valkey-public-port")

    def test_api_port_binding(self):
        for binding in (None, [], [{"HostIp": "0.0.0.0", "HostPort": "8080"}], [{"HostIp": "127.0.0.1", "HostPort": "8081"}]):
            self.reject(lambda h: h.api["NetworkSettings"]["Ports"].update({"8080/tcp": binding}), code="api-non-loopback-binding")
        self.reject(lambda h: h.api["NetworkSettings"]["Ports"].update({"9999/tcp": [{"HostIp": "0.0.0.0", "HostPort": "9999"}]}), code="api-extra-published-port")

    def test_spot_markers_agent_count_and_td(self):
        self.reject(lambda h: setattr(h, "markers", False), "spot", code="spot-bootstrap-not-ready")
        self.reject(lambda h: setattr(h, "fail_command", "ecs"), "spot")
        for ids in ("", CONTAINER_ID + "\n" + CONTAINER_ID + "\n", "$(shell)"):
            self.reject(lambda h: setattr(h, "docker_ids", ids), "spot", code="ecs-api-count-or-identifier")
        for key, value, code in (("com.amazonaws.ecs.cluster", "ec-portfolio-demo-measure", "ecs-cluster-mismatch"),
                                  ("com.amazonaws.ecs.task-definition-family", "ec-portfolio-demo-api-measure", "ecs-task-definition-mismatch"),
                                  ("com.amazonaws.ecs.task-definition-version", "22", "ecs-task-definition-mismatch")):
            self.reject(lambda h: h.api["Config"]["Labels"].update({key: value}), "spot", code=code)
        self.reject(lambda h: h.api["HostConfig"].update(NetworkMode="bridge"), "spot", code="ecs-network-mode")

    def test_spot_loopback_exact(self):
        for port in ("8080", "6379"):
            for listing in ("", "LISTEN 0 100 0.0.0.0:" + port + " 0.0.0.0:*\n", "LISTEN 0 100 127.0.0.1:" + port + " 0.0.0.0:*\n" * 2):
                self.reject(lambda h: h.ipv4.update({port: listing}), "spot", code="ecs-non-loopback-listener")
        self.reject(lambda h: setattr(h, "ipv6", "LISTEN 0 10 [::]:8080 [::]:*\n"), "spot", code="ecs-non-loopback-listener")

    def test_readiness_all_components(self):
        self.reject(lambda h: setattr(h, "readiness_status", 503), code="readiness-http-status")
        self.reject(lambda h: h.health.update(status="DOWN"), code="readiness-not-up")
        self.reject(lambda h: h.health["components"]["db"].update(status="DOWN"), code="readiness-component-not-up")
        self.reject(lambda h: h.health["components"]["redis"].update(status="DOWN"), code="readiness-component-not-up")
        self.reject(lambda h: h.health.update(components=[]), code="readiness-components-shape")
        self.reject(lambda h: h.health.update(components={}), code="readiness-components-contract")

    def test_origin_security_and_tls(self):
        self.reject(lambda h: setattr(h, "http80", "LISTEN 0 100 *:80 *:*\n"), code="origin-http-listener")
        self.reject(lambda h: setattr(h, "fail_command", "nginx"))
        self.reject(lambda h: setattr(h, "origin_tls", False), code="mock-tls-failed")
        self.reject(lambda h: setattr(h, "origin_denied", 200), code="origin-no-header-not-denied")
        self.reject(lambda h: setattr(h, "origin_invalid", 200), code="origin-invalid-header-not-denied")
        self.reject(lambda h: setattr(h, "origin_valid", 403), code="readiness-http-status")

    def test_e2e_cannot_accept_remote200_without_localproof(self):
        self.reject(lambda h: setattr(h, "echo", False), mode="endToEnd", code="cloudfront-correlation-mismatch")
        self.reject(lambda h: setattr(h, "duplicate_echo", True), mode="endToEnd", code="cloudfront-correlation-mismatch")
        self.reject(lambda h: setattr(h, "public_status", 403), mode="endToEnd", code="cloudfront-public-read-failed")
        self.reject(lambda h: setattr(h, "public_body", "{}"), mode="endToEnd", code="cloudfront-public-read-failed")
        self.reject(lambda h: setattr(h, "log_present", False), mode="endToEnd", code="local-correlation-not-proven")
        self.reject(lambda h: setattr(h, "log_duplicate", True), mode="endToEnd", code="local-correlation-not-proven")
        for key, value in (("httpMethod", "POST"), ("requestPath", "/other"), ("httpStatus", 500), ("message", "other")):
            self.reject(lambda h: h.log_change.update({key: value}), mode="endToEnd", code="local-correlation-request-mismatch")

    def test_e2e_logging_lag_is_bounded(self):
        host = FakeHost()
        host.log_delay = 4
        self.run_check(host=host, mode="endToEnd")
        self.assertEqual(host.log_reads, 5)
        host = FakeHost()
        host.log_delay = 5
        with self.assertRaises(MODULE.CheckFailure):
            self.run_check(host=host, mode="endToEnd")
        self.assertEqual(host.log_reads, 5)

    def test_json_duplicate_rejected(self):
        with self.assertRaises(MODULE.CheckFailure):
            MODULE.strict_json('{"status":"DOWN","status":"UP"}')

    def test_environment_has_no_identity_endpoint_proxy_trust_hooks(self):
        with mock.patch.dict(os.environ, {"AWS_ACCESS_KEY_ID": "MOCK", "HTTPS_PROXY": "attacker", "SSL_CERT_FILE": "/attacker", "PYTHONPATH": "/attacker"}):
            env = MODULE.clean_environment()
        for name in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "HTTPS_PROXY", "SSL_CERT_FILE", "PYTHONPATH", "AWS_ENDPOINT_URL"):
            self.assertNotIn(name, env)
        self.assertEqual(env["AWS_SHARED_CREDENTIALS_FILE"], "/dev/null")
        self.assertEqual(env["AWS_CONFIG_FILE"], "/dev/null")
        self.assertEqual(env["AWS_MAX_ATTEMPTS"], "1")


class DocumentChecks(unittest.TestCase):
    def test_documents_match_reviewed_generator_and_limits(self):
        for kind, name in (("od", "od-readiness.yaml"), ("spot", "spot-smoke.yaml")):
            path = ROOT / "ssm-documents" / name
            content = path.read_text()
            doc = json.loads(content)
            self.assertEqual(doc, documents.document(kind))
            self.assertLess(len(content.encode()), 65536)
            self.assertEqual(doc["schemaVersion"], "2.2")
            self.assertNotIn("permissions", doc)
            self.assertEqual(len(doc["mainSteps"]), 1)
            self.assertEqual(doc["mainSteps"][0]["action"], "aws:runShellScript")
            command = doc["mainSteps"][0]["inputs"]["runCommand"][0]
            self.assertNotIn("{{", command)
            self.assertIn("exec env -i ", command)
            self.assertIn("python3 -I - " + kind, command)
            self.assertEqual(subprocess.run(["/bin/sh", "-n"], input=command.encode(), stdout=subprocess.PIPE, stderr=subprocess.PIPE).returncode, 0)
            for param in doc["parameters"].values():
                self.assertEqual(param["interpolationType"], "ENV_VAR")

    def test_source_has_no_resource_write_or_shell_eval(self):
        source = (Path(__file__).resolve().with_name("ssm_runtime.py")).read_text()
        ast.parse(source)
        for forbidden in ("shell=True", "eval(", "exec(", "start-instances", "stop-instances", "associate-address", "modify-network-interface", "put-parameter", "sync-origin-tls", "deploy-api-from-ssm.sh"):
            self.assertNotIn(forbidden, source)

    def test_envvar_shell_boundary_does_not_execute_parameter_text(self):
        # Execute only the generated env boundary, replacing the whole host
        # program with a stdlib environment echo. No host command or network.
        command = documents.document("od")["mainSteps"][0]["inputs"]["runCommand"][0]
        prefix = command.split(" python3 -I - od <<", 1)[0]
        script = prefix + " python3 -I -c 'import json,os;print(json.dumps(dict(os.environ)))'\n"
        env = dict(os.environ)
        for name in documents.PARAMETERS:
            env["SSM_" + name] = "$(printf MUST_NOT_EXECUTE); ' \" `printf MUST_NOT_EXECUTE`\nvalue"
        env.update(SSL_CERT_FILE="/MOCK_UNTRUSTED", HTTPS_PROXY="MOCK_UNTRUSTED", AWS_ACCESS_KEY_ID="MOCK_UNTRUSTED", PYTHONPATH="/MOCK_UNTRUSTED")
        result = subprocess.run(["/bin/sh", "-c", script], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 0)
        received = json.loads(result.stdout)
        for name in documents.PARAMETERS:
            self.assertEqual(received["SSM_" + name], env["SSM_" + name])
        for name in ("SSL_CERT_FILE", "HTTPS_PROXY", "AWS_ACCESS_KEY_ID", "PYTHONPATH"):
            self.assertNotIn(name, received)

    def test_token_only_uses_readonly_instance_credentials_and_never_leaks_errors(self):
        success = types.SimpleNamespace(returncode=0, stdout=(TOKEN + "\n").encode(), stderr=b"")
        with mock.patch.object(MODULE.subprocess, "run", return_value=success) as invoke:
            self.assertEqual(MODULE.Host().token(), TOKEN)
            argv = invoke.call_args[0][0]
            self.assertEqual(argv[:3], ["aws", "ssm", "get-parameter"])
            self.assertEqual(argv[argv.index("--name") + 1], "/ec-portfolio/demo/origin/verify-token")
            self.assertNotIn("shell", invoke.call_args[1])
            self.assertEqual(invoke.call_args[1]["env"]["AWS_CONFIG_FILE"], "/dev/null")
        failure = types.SimpleNamespace(returncode=1, stdout=TOKEN.encode(), stderr=TOKEN.encode())
        with mock.patch.object(MODULE.subprocess, "run", return_value=failure):
            with self.assertRaises(MODULE.CheckFailure) as error:
                MODULE.Host().token()
            self.assertNotIn(TOKEN, str(error.exception))
        for token in ("None", "x" * 31, "x" * 129, "x" * 32 + "\nattack", "x" * 32 + ":"):
            success.stdout = token.encode()
            with mock.patch.object(MODULE.subprocess, "run", return_value=success):
                with self.assertRaises(MODULE.CheckFailure):
                    MODULE.Host().token()

    def test_tls_checks_served_cert_and_14day_boundary(self):
        # Fully fake socket/SSL/HTTP classes: exercises production TLS logic
        # without opening a socket, reading a cert, or sending a real request.
        for remaining, accepted in ((1209599, False), (1209600, True), (1209601, True)):
            conn = mock.MagicMock()
            response = mock.MagicMock()
            response.status = 403
            response.read.return_value = b"DENIED"
            response.getheaders.return_value = []
            conn.getresponse.return_value = response
            wrapped = mock.MagicMock()
            wrapped.getpeercert.return_value = {"notAfter": "MOCK-DATE"}
            context = mock.MagicMock()
            context.wrap_socket.return_value = wrapped
            with mock.patch.object(runtime.ssl, "create_default_context", return_value=context), mock.patch.object(runtime.socket, "create_connection"), mock.patch.object(runtime.http.client, "HTTPSConnection", return_value=conn), mock.patch.object(runtime.ssl, "cert_time_to_seconds", return_value=100 + remaining), mock.patch.object(runtime.time, "time", return_value=100):
                if accepted:
                    self.assertEqual(MODULE.Host().request(runtime.ORIGIN, runtime.READINESS, local_tls=True)[0], 403)
                else:
                    with self.assertRaises(MODULE.CheckFailure):
                        MODULE.Host().request(runtime.ORIGIN, runtime.READINESS, local_tls=True)
                context.wrap_socket.assert_called_once()
                self.assertEqual(context.wrap_socket.call_args[1]["server_hostname"], runtime.ORIGIN)
                conn.close.assert_called_once()


def run_suite(cls, stream):
    return unittest.TextTestRunner(stream=stream, verbosity=1).run(unittest.defaultTestLoader.loadTestsFromTestCase(cls))


def mutation_test():
    global MODULE
    source = (Path(__file__).resolve().with_name("ssm_runtime.py")).read_text()
    # Each selected production guard is independently disabled. All mutants
    # must be killed by the same behavioural suite, including success controls.
    tree = ast.parse(source)
    guards = [node for node in ast.walk(tree) if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "require" and len(node.args) == 2 and isinstance(node.args[1], ast.Constant)]
    excluded = {"root-required", "invalid-argument-count", "oversized-command-result", "non-utf8-command-result", "command-failed:", "command-unavailable-or-timeout:", "oversized-http-result"}
    killed, survived = [], []
    for guard in guards:
        code = guard.args[1].value
        if not isinstance(code, str) or code in excluded:
            continue
        start = sum(len(line) for line in source.splitlines(keepends=True)[:guard.args[0].lineno - 1]) + guard.args[0].col_offset
        end = sum(len(line) for line in source.splitlines(keepends=True)[:guard.args[0].end_lineno - 1]) + guard.args[0].end_col_offset
        mutated = source[:start] + "True" + source[end:]
        module = types.ModuleType("mutant_ssm_runtime")
        exec(compile(mutated, "<offline-mutant>", "exec"), module.__dict__)
        MODULE = module
        suite = unittest.TestSuite([unittest.defaultTestLoader.loadTestsFromTestCase(HostChecks),
                                   unittest.defaultTestLoader.loadTestsFromTestCase(DocumentChecks)])
        result = unittest.TextTestRunner(stream=io.StringIO(), verbosity=0).run(suite)
        (killed if not result.wasSuccessful() else survived).append(code)
    MODULE = runtime
    require_control = run_suite(HostChecks, io.StringIO())
    assert require_control.wasSuccessful(), "unmutated behavioural control failed"
    print("SSM mutation: %d/%d killed" % (len(killed), len(killed) + len(survived)))
    if survived:
        print("SURVIVED: " + ", ".join(survived))
        return 1
    return 0


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite([
        unittest.defaultTestLoader.loadTestsFromTestCase(HostChecks),
        unittest.defaultTestLoader.loadTestsFromTestCase(DocumentChecks)]))
    if not result.wasSuccessful():
        sys.exit(1)
    sys.exit(mutation_test())
