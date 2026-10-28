#!/usr/bin/env python3
"""Reviewed, read-only host checks embedded verbatim in both SSM documents.

The generator and offline tests import this module; production executes the
same source under Python -I. It never deploys, changes TLS, starts/stops a host,
or writes an AWS resource. Missing evidence fails the SSM command.
"""
import http.client
import json
import os
import re
import socket
import ssl
import subprocess
import sys
import time
import uuid

ORIGIN = "origin-demo.yoonec.dev"
READINESS = "/actuator/health/readiness"
PUBLIC_READ = "/api/public/categories"
MIN_TLS_SECONDS = 14 * 86400
MAX_RESPONSE = 1048576
REGION = "ap-northeast-1"


class CheckFailure(Exception):
    pass


def require(value, code):
    if not value:
        raise CheckFailure(code)


def strict_json(text):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "duplicate-json-key")
            result[key] = value
        return result
    try:
        return json.loads(text, object_pairs_hook=pairs)
    except (ValueError, TypeError):
        raise CheckFailure("invalid-json")


def parameters(env):
    names = ("expectedImageSha", "expectedImageRepository", "expectedTaskDefinitionArn", "checkMode", "cloudFrontDomain")
    p = {name: env.get("SSM_" + name, "") for name in names}
    require(re.fullmatch(r"[0-9a-f]{40}", p["expectedImageSha"]), "invalid-image-sha")
    repo = re.fullmatch(r"([0-9]{12})\.dkr\.ecr\.ap-northeast-1\.amazonaws\.com/ec-portfolio-demo-api", p["expectedImageRepository"])
    require(repo, "invalid-image-repository")
    td = re.fullmatch(r"arn:aws:ecs:ap-northeast-1:([0-9]{12}):task-definition/ec-portfolio-demo-api:([1-9][0-9]{0,9})", p["expectedTaskDefinitionArn"])
    require(td and td[1] == repo[1], "invalid-task-definition")
    require(p["checkMode"] in ("local", "endToEnd"), "invalid-check-mode")
    require(re.fullmatch(r"d[a-z0-9]{1,62}\.cloudfront\.net", p["cloudFrontDomain"]), "invalid-cloudfront-domain")
    p["revision"] = td[2]
    p["image"] = p["expectedImageRepository"] + ":" + p["expectedImageSha"]
    return p


def clean_environment():
    # No inherited credentials, endpoints, proxies, trust-store or Python hooks.
    return {"PATH": "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/root", "LANG": "C.UTF-8",
            "AWS_REGION": REGION, "AWS_DEFAULT_REGION": REGION,
            "AWS_CONFIG_FILE": "/dev/null", "AWS_SHARED_CREDENTIALS_FILE": "/dev/null",
            "AWS_PAGER": "", "AWS_MAX_ATTEMPTS": "1", "AWS_IGNORE_CONFIGURED_ENDPOINT_URLS": "true"}


class Host:
    def command(self, argv, timeout=20):
        try:
            result = subprocess.run(argv, env=clean_environment(), stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, timeout=timeout, check=False)
        except (OSError, subprocess.TimeoutExpired):
            raise CheckFailure("command-unavailable-or-timeout:" + argv[0])
        require(result.returncode == 0, "command-failed:" + argv[0])
        require(len(result.stdout) <= 4 * MAX_RESPONSE, "oversized-command-result")
        try:
            return result.stdout.decode("utf-8")
        except UnicodeError:
            raise CheckFailure("non-utf8-command-result")

    def exists(self, path):
        return os.path.isfile(path)

    def request(self, domain, path, headers=None, local_tls=False):
        # The local handshake validates the *served* certificate and its SNI
        # hostname. It does not assume a certificate file path or trust a marker.
        connection = None
        try:
            if domain == "127.0.0.1":
                connection = http.client.HTTPConnection(domain, 8080, timeout=10)
            else:
                context = ssl.create_default_context()
                context.minimum_version = ssl.TLSVersion.TLSv1_2
                connection = http.client.HTTPSConnection(domain, timeout=10, context=context)
                if local_tls:
                    sock = socket.create_connection(("127.0.0.1", 443), timeout=10)
                    try:
                        connection.sock = context.wrap_socket(sock, server_hostname=domain)
                    except Exception:
                        sock.close()
                        raise
                else:
                    connection.connect()
                cert = connection.sock.getpeercert()
                expires = ssl.cert_time_to_seconds(cert["notAfter"])
                if local_tls:
                    require(expires - time.time() >= MIN_TLS_SECONDS, "tls-expires-before-14-days")
            connection.request("GET", path, headers=headers or {})
            response = connection.getresponse()
            body = response.read(MAX_RESPONSE + 1)
            require(len(body) <= MAX_RESPONSE, "oversized-http-result")
            return response.status, response.getheaders(), body.decode("utf-8")
        except CheckFailure:
            raise
        except Exception:
            # Exception strings can contain URLs, headers or response material.
            raise CheckFailure("http-or-tls-check-failed")
        finally:
            if connection is not None:
                connection.close()

    def token(self):
        raw = self.command(["aws", "ssm", "get-parameter", "--name", "/ec-portfolio/demo/origin/verify-token",
                            "--with-decryption", "--query", "Parameter.Value", "--output", "text",
                            "--region", REGION, "--cli-connect-timeout", "5", "--cli-read-timeout", "10"], timeout=20).strip()
        require(re.fullmatch(r"[A-Za-z0-9_-]{32,128}", raw), "invalid-origin-token")
        return raw

    def pause(self):
        time.sleep(1)


def ready(response):
    status, headers, body = response
    require(status == 200, "readiness-http-status")
    health = strict_json(body)
    require(isinstance(health, dict) and health.get("status") == "UP", "readiness-not-up")
    # The current demo group is readinessState,db,redis. Component details may
    # be hidden to unauthenticated clients; if present no component may be DOWN.
    if "components" in health:
        require(isinstance(health["components"], dict), "readiness-components-shape")
        require(set(health["components"]) == {"readinessState", "db", "redis"}, "readiness-components-contract")
        require(all(isinstance(v, dict) and v.get("status") == "UP" for v in health["components"].values()), "readiness-component-not-up")


def inspect_container(host, identifier):
    data = strict_json(host.command(["docker", "inspect", identifier]))
    require(isinstance(data, list) and len(data) == 1 and isinstance(data[0], dict), "container-inspect-shape")
    return data[0]


def container_for(host, kind, p):
    if kind == "od":
        # Parse property names, not positional --value output; systemd property
        # order is not an API contract. A positive monotonic start proves it ran
        # this boot, instead of accepting the default Result=success.
        values = host.command(["systemctl", "show", "ec-portfolio-api-converge.service",
                               "--property=Result,ExecMainStatus,ExecMainStartTimestampMonotonic,ActiveState"]).splitlines()
        fields = {}
        for line in values:
            require("=" in line, "convergence-result-shape")
            key, value = line.split("=", 1)
            require(key not in fields, "convergence-result-duplicate")
            fields[key] = value
        require(fields.get("Result") == "success" and fields.get("ExecMainStatus") == "0" and
                fields.get("ActiveState") == "inactive" and fields.get("ExecMainStartTimestampMonotonic", "").isdigit() and
                int(fields["ExecMainStartTimestampMonotonic"]) > 0, "convergence-not-successful-this-boot")
        identifier = "ec-portfolio-demo-api"
        container = inspect_container(host, identifier)
        valkey = inspect_container(host, "ec-portfolio-demo-valkey")
        require(valkey.get("State", {}).get("Running") is True, "valkey-not-running")
        valkey_ports = valkey.get("NetworkSettings", {}).get("Ports", {})
        require(isinstance(valkey_ports, dict) and all(v is None for v in valkey_ports.values()), "valkey-public-port")
        binding = container.get("NetworkSettings", {}).get("Ports", {}).get("8080/tcp")
        require(binding == [{"HostIp": "127.0.0.1", "HostPort": "8080"}], "api-non-loopback-binding")
        require(all(k == "8080/tcp" or v is None for k, v in container["NetworkSettings"]["Ports"].items()), "api-extra-published-port")
    else:
        require(host.exists("/run/ec-portfolio-demo/spot-serving-ready") and host.exists("/run/ec-portfolio-demo/spot-continue-accepted"), "spot-bootstrap-not-ready")
        host.command(["systemctl", "is-active", "--quiet", "ecs"])
        identifiers = host.command(["docker", "ps", "--quiet", "--filter", "label=com.amazonaws.ecs.container-name=api"]).splitlines()
        require(len(identifiers) == 1 and re.fullmatch(r"[0-9a-f]{12,64}", identifiers[0]), "ecs-api-count-or-identifier")
        identifier = identifiers[0]
        container = inspect_container(host, identifier)
        labels = container.get("Config", {}).get("Labels", {})
        require(labels.get("com.amazonaws.ecs.cluster") in ("ec-portfolio-demo", "arn:aws:ecs:ap-northeast-1:" + p["expectedTaskDefinitionArn"].split(":")[4] + ":cluster/ec-portfolio-demo"), "ecs-cluster-mismatch")
        require(labels.get("com.amazonaws.ecs.task-definition-family") == "ec-portfolio-demo-api" and
                labels.get("com.amazonaws.ecs.task-definition-version") == p["revision"], "ecs-task-definition-mismatch")
        require(container.get("HostConfig", {}).get("NetworkMode") == "host", "ecs-network-mode")
        for port in (8080, 6379):
            ipv4 = host.command(["ss", "-H", "-ltn4", "sport = :" + str(port)]).splitlines()
            ipv6 = host.command(["ss", "-H", "-ltn6", "sport = :" + str(port)]).splitlines()
            require(len(ipv4) == 1 and len(ipv4[0].split()) >= 4 and ipv4[0].split()[3] == "127.0.0.1:" + str(port) and not ipv6, "ecs-non-loopback-listener")
    require(container.get("State", {}).get("Running") is True, "api-not-running")
    require(container.get("Config", {}).get("Image") == p["image"], "running-image-mismatch")
    return identifier


def end_to_end(host, p, container_id, now):
    # Successful health probes are deliberately absent from the API request log.
    # Categories is an existing public GET, logged by CorrelationIdFilter. A
    # unique ID echoed by CloudFront AND observed on this host proves the holder,
    # whereas a remote 200 alone could come from the previous EIP holder/cache.
    correlation = str(uuid.uuid4())
    domain = p["cloudFrontDomain"]
    ready(host.request(domain, READINESS))
    response = host.request(domain, PUBLIC_READ + "?p3probe=" + correlation,
                            {"X-Correlation-ID": correlation, "Cache-Control": "no-cache"})
    status, headers, body = response
    require(status == 200 and isinstance(strict_json(body), list), "cloudfront-public-read-failed")
    echoed = [v for k, v in headers if k.lower() == "x-correlation-id"]
    require(echoed == [correlation], "cloudfront-correlation-mismatch")
    found = []
    # Logging can lag the completed HTTP response. Only bounded read retries;
    # never substitute a remote 200 for proof on this host.
    for attempt in range(5):
        logs = host.command(["docker", "logs", "--since", str(int(now)), "--tail", "1000", container_id], timeout=20)
        found = []
        for line in logs.splitlines():
            try:
                record = strict_json(line)
            except CheckFailure:
                continue
            if isinstance(record, dict) and record.get("correlationId") == correlation:
                found.append(record)
        if found:
            break
        if attempt < 4:
            host.pause()
    require(len(found) == 1, "local-correlation-not-proven")
    record = found[0]
    require(record.get("httpMethod") == "GET" and record.get("requestPath") == PUBLIC_READ and
            record.get("httpStatus") == 200 and record.get("message") == "HTTP request completed", "local-correlation-request-mismatch")


def check(kind, env=None, host=None, now=None):
    require(kind in ("od", "spot"), "invalid-document-kind")
    p = parameters(os.environ if env is None else env)
    h = Host() if host is None else host
    began = time.time() if now is None else now
    identifier = container_for(h, kind, p)
    ready(h.request("127.0.0.1", READINESS))
    h.command(["systemctl", "is-active", "--quiet", "nginx"])
    # No HTTP listener may bypass the origin TLS contract.
    require(not h.command(["ss", "-H", "-ltn", "sport = :80"]).strip(), "origin-http-listener")
    require(h.request(ORIGIN, READINESS, local_tls=True)[0] == 403, "origin-no-header-not-denied")
    require(h.request(ORIGIN, READINESS, {"X-Origin-Verify": "invalid"}, local_tls=True)[0] == 403, "origin-invalid-header-not-denied")
    token = h.token()
    ready(h.request(ORIGIN, READINESS, {"X-Origin-Verify": token}, local_tls=True))
    del token
    if p["checkMode"] == "endToEnd":
        end_to_end(h, p, identifier, began)
    return {"result": "PASS", "document": kind, "checkMode": p["checkMode"], "imageSha": p["expectedImageSha"]}


def main():
    try:
        require(len(sys.argv) == 2, "invalid-argument-count")
        require(os.geteuid() == 0, "root-required")
        print(json.dumps(check(sys.argv[1]), sort_keys=True))
        return 0
    except CheckFailure as exc:
        print("FAIL " + str(exc), file=sys.stderr)
        return 1
    except Exception:
        print("FAIL unexpected-response-shape", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
