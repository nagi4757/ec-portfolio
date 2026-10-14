# Demo Terraform Network and Runtime

<!-- markdownlint-disable MD013 MD060 -->

This root module defines the Tokyo network foundation, Phase 3A Demo runtime, Phase 3B Scheduler/cost/failure guardrails, the Phase 4A deployment foundation, the Phase 4C origin/API distribution, the Phase 5A Store/Admin static hosting, the Phase 5E GitHub frontend deployment identity, the Phase 5F-1 GitHub backend image publication identity, and the Phase 5F-2a runtime state and release guards. Phases 1, 3A/3B, 4A, 4C-2A/2B/3, 5A, 5E, 5F-1, and 5F-2a are applied; their latest approved convergence checks reported `No changes`. Phase 5B uploaded both frontend artifacts, and Phase 5C added both deployed frontend origins to the runtime CORS allowlist without rebuilding the API image. All four schedules exist, the SNS subscription is confirmed, the Scheduler failure alarm is `OK`, alarm-to-SNS delivery is verified, and the tax-inclusive monthly Budget limit is `30.30 USD`.

The Scheduler stop path was verified on 2026-09-01: EC2 was `stopped` after its 17:00 JST invocation and RDS was `stopped` after 17:10. The start path was verified on 2026-09-02: RDS was `available` after 09:50 and EC2 was `running` after 10:00.

Current approved project status: Phase 4C-2A and 4C-2B are `APPLIED / CONVERGED`; Phase 4C-3 is `COMPLETE`; Phase 5A is `APPLIED / CONVERGED`; and the Phase 5B/5C deployment and runtime verification passed. The origin `A` record points to the existing EC2 EIP and has no `AAAA` record. The Let's Encrypt certificate and Nginx HTTPS origin are verified: missing/invalid `X-Origin-Verify` returns `403`, and the valid token returns `200 / UP`; the renewal timer is enabled and active. Phase 5E is `APPLIED / CONVERGED`: its GitHub OIDC provider, exact-subject frontend deploy role, and inline policy were applied as `3 added / 0 changed / 0 destroyed`, the convergence plan reported `No changes`, and every previously applied resource showed zero delta. The `demo-frontend` GitHub Environment exists with its deployment branch policy limited to `main` and its four non-secret variables configured. The `deploy-frontends` CI job completed its first automated deployment of the reviewed `main` commit, and both frontends were verified through CloudFront. Phase 5F-1 is `APPLIED / CONVERGED`: its role, inline policy, and three deployment-state parameters were applied, the convergence plan reported `No changes`, and the `demo-backend` GitHub Environment is configured for `main` only. Its first automated run published an immutable API image, passed the Flyway gate, and recorded the desired image SHA without touching EC2. Phase 5F-2a is `APPLIED / CONVERGED`: its five runtime state parameters and the raised ECR retention were applied as `6 added / 0 changed / 1 destroyed`, and the convergence plan reported `No changes`. All five parameters read back as `String` with values matching the measured Demo runtime, the tagged retention is `30`, and both the last known good and desired API images are still present in ECR.

Architecture sources:

- [Demo AWS Architecture](../../../docs/architecture/aws-demo.md)
- [Production AWS Architecture](../../../docs/architecture/aws-production.md)
- [ADR-001](../../../docs/adr/ADR-001-cost-optimized-demo-aws.md)

## Version contract

- Terraform `~> 1.16.0`
- HashiCorp AWS provider `~> 6.62.0`
- `.terraform.lock.hcl` is committed with official checksums for `darwin_arm64` and `linux_amd64`.

Review and intentionally upgrade these constraints and the lock file together. Do not run an unreviewed provider upgrade during deployment.

Sources: [Terraform install](https://developer.hashicorp.com/terraform/install), [HashiCorp AWS provider](https://registry.terraform.io/providers/hashicorp/aws/latest)

## Network contract

| Network | CIDR | Availability Zone strategy | Routing |
|---|---|---|---|
| VPC | `10.20.0.0/16` | Tokyo only | Local VPC routing |
| Public app | `10.20.0.0/24` | Configured `public_app` AZ | `0.0.0.0/0` to Internet Gateway |
| Private DB A | `10.20.10.0/24` | Configured `private_db_a` AZ | Local VPC routing only |
| Private DB B | `10.20.11.0/24` | Configured `private_db_b` AZ | Local VPC routing only |

The two DB AZ inputs must be distinct. The example uses `ap-northeast-1a` and `ap-northeast-1c`; confirm that the selected AZ names are available to the target account before plan/apply. Stable object keys avoid selecting AZs by a changing API list index.

Automatic public IPv4 assignment is disabled by `aws_subnet.public_app.map_public_ip_on_launch = false`, which is the source of truth. EC2 follows that subnet policy, while the explicit `aws_eip.ec2_origin` allocation provides the stable public origin address. Which instance holds that address is no longer managed by Terraform (see [Phase 6C-5b-1](#phase-6c-5b-1-eip-association-ownership)). The private DB route table has no Internet Gateway, NAT Gateway, or VPC endpoint route.

## Security-group contract

The EC2 origin security group allows only:

- Ingress TCP 443 from the AWS-managed `com.amazonaws.global.cloudfront.origin-facing` prefix list.
- Egress TCP 443 to IPv4 destinations for ECR, SSM, CloudWatch, AWS APIs, and approved HTTPS package repositories.
- Egress TCP 3306 to the RDS security group.

There is no SSH ingress and no public CIDR ingress to TCP 443. Nginx already enforces the origin token; Phase 4C-2B defines its CloudFront header binding without changing any security-group rule.

The RDS security group allows only TCP 3306 ingress from the EC2 origin security group. It has no public ingress and no explicit egress rule because security groups are stateful and response traffic for an allowed inbound connection is automatically permitted.

VPC DNS support and hostnames are enabled, so the future EC2 uses AmazonProvidedDNS. AWS documents that security groups cannot filter traffic to or from the Route 53 Resolver, so adding TCP/UDP 53 rules would not create a DNS security boundary. Domain filtering would require Route 53 Resolver DNS Firewall, which is outside this phase.

Security groups filter by IP, prefix list, protocol, and port; they do not provide FQDN/domain HTTPS egress control. TCP 443 egress therefore permits any IPv4 HTTPS destination. A proxy, firewall, NAT Gateway, or VPC endpoint policy could narrow this in a production design, but those controls are outside this cost-constrained phase.

Source: [Security group rules and Route 53 Resolver limitation](https://docs.aws.amazon.com/vpc/latest/userguide/security-group-rules.html)

The CloudFront managed prefix list has a high security-group quota weight. Keep the origin security group limited to the single prefix-list ingress rule and the explicit runtime egress rules, and verify account quota before apply.

## Tags

The AWS provider applies these tags by default to supported resources:

- `Project = ec-portfolio`
- `Environment = demo`
- `Owner = var.owner`

Each resource also receives an `ec-portfolio-demo-*` `Name` tag. `AutoStop = true` is set directly on the scheduled EC2 and RDS resources only. It is omitted from the VPC, subnets, Internet Gateway, route tables, routes, security groups, Elastic IP, DB subnet group, IAM resources, ECR resources, and SSM parameters because those resources cannot be safely stopped by the runtime schedule.

Removing `AutoStop` from provider default tags is expected to remove that tag from the existing foundation resources in place. Any future plan that proposes replacing the VPC, subnet, Internet Gateway, route, route table, or security group is a blocker and must not be applied. Never place credentials, secrets, personal data, or origin verification values in tags or variable files.

## EC2 runtime contract

- The host is x86_64 `t3a.medium` with Standard CPU credits. Do not reduce it to 2 GiB or switch to ARM64 before the architecture's memory/load and multi-platform image gates pass.
- The AMI is pinned to an exact image ID in `locals.tf`. AWS's public SSM parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64` is no longer used. See the AMI lifecycle section below.
- The instance follows the existing public app subnet's no-auto-public-IP policy and uses only the existing EC2 origin security group. A separately associated Elastic IP provides the stable future CloudFront origin address and continues to incur public IPv4 cost while EC2 is stopped. Do not duplicate the subnet policy with instance-level `associate_public_ip_address = false`: during partial-apply recovery, provider refresh after the explicit EIP association conflicted with the duplicate setting and proposed perpetual instance replacement.
- The encrypted root volume is 20 GiB gp3 with default IOPS/throughput and is deleted on instance termination. No additional data volume is defined.
- IMDSv2 tokens are required, the metadata endpoint is enabled, metadata tags are disabled, and the hop limit is `1`. Phase 3A containers do not need instance metadata. A future container AWS SDK requirement must justify a separately reviewed hop-limit change to `2`.
- This Terraform root defines no EC2 key pair, SSH ingress, or runtime installation/bootstrap. Phase 4C-2A provides the origin token in SSM and its exact read permission. The separate, completed Phase 4C-3 runtime procedure consumes it on the host and configures origin TLS/header enforcement; Phase 4C-2B does not modify that runtime.

AWS-provided AL2023 AMIs normally include SSM Agent, so Phase 3A does not add network-fetched installation user data. Verify the agent is installed and running during the future launch gate. The dedicated instance role trusts only `ec2.amazonaws.com`. Its custom inline policy permits managed-node registration and Session Manager message channels only.

`AmazonSSMManagedInstanceCore` remains intentionally unattached because its wildcard Parameter Store reads are broader than this deployment contract. The existing custom Session Manager policy is unchanged. Phase 4A adds a separate inline runtime policy: only `ecr:GetAuthorizationToken` uses the API-required `Resource = "*"`; the three image-pull actions use the exact Demo API repository ARN, and `ssm:GetParameter` uses only the DB and JWT SecureString ARNs. It grants no ECR push, Parameter Store path/list, Run Command, KMS, S3, Secrets Manager, SQS, SES, or application CloudWatch permissions.

Both SecureStrings use the default AWS-managed `alias/aws/ssm` key. AWS documents that this key's `Decrypt` permission is available to all IAM principals in the account, so adding another broad `kms:Decrypt` statement would not narrow access and is omitted. Exact `ssm:GetParameter` resource permissions are the retrieval boundary for this role. A future customer-managed key would require a separately reviewed key policy and encryption-context-scoped decrypt permission.

Sources: [AWS public AMI parameters](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/finding-an-ami-parameter-store.html), [AL2023 SSM Agent installation](https://docs.aws.amazon.com/systems-manager/latest/userguide/agent-install-al2.html), [Systems Manager instance permissions](https://docs.aws.amazon.com/systems-manager/latest/userguide/setup-instance-permissions.html), [AmazonSSMManagedInstanceCore policy JSON](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonSSMManagedInstanceCore.html), [Parameter Store IAM and default-key permissions](https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-setting-up.html), [ECR IAM action/resource reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ecr.html)

## AMI lifecycle contract

### The AMI is pinned to an exact ID

`local.demo_ami_id` in `locals.tf` holds the exact image the Demo host runs:

| | |
| --- | --- |
| AMI ID | `ami-0794a632d5c1058bf` |
| AMI name | `al2023-ami-2023.12.20260831.0-kernel-6.18-x86_64` |
| Deprecation time | `2026-11-24` |

The AWS-managed `/aws/service/ami-amazon-linux-latest/...` parameter is **not** used. It is a mutable pointer, and `ami` forces replacement on `aws_instance`, so every AL2023 release AWS published turned into a plan that destroys the Demo host. That is not an upgrade policy; it is an unreviewed replacement waiting for whoever runs `plan` next.

**Pinning does not mean the OS stops being updated.** It means an AMI change becomes a deliberate, reviewed act instead of a side effect of the calendar. The pinned image ID is not a secret and is deliberately readable in `plan` output, so a reviewer can see exactly which image is proposed. Do not wrap it in `sensitive()`, and do not use `ignore_changes = [ami]`: that hides the drift rather than resolving it, and leaves the config claiming to track "latest" while telling Terraform not to look.

### `prevent_destroy` on the instance

`aws_instance.demo` carries `lifecycle { prevent_destroy = true }`. The host holds state Terraform does not rebuild:

- the runtime scripts under `/opt/ec-portfolio/runtime/demo/`
- the origin TLS certificate and its private key
- the certbot systemd unit and timer
- Docker images, containers and the `ec-portfolio-demo` network
- the boot convergence installer and `ec-portfolio-api-converge.service` unit

The guard is separate from the pin. The pin removes the cause already encountered; the guard fails the plan closed for causes not yet encountered, such as a change to `subnet_id` or another attribute the provider treats as ForceNew. A plan that requires a replacement will error rather than proceed, which is the intended behaviour.

`prevent_destroy` only stops replacement and destroy. It does not stop a normal in-place update, nor an update the provider performs by stopping and starting the instance. `instance_type` is one of those: the provider changes it in place rather than replacing the instance, so this guard is not what reviews a sizing change.

The guard also does not cover every path to losing the host:

- removing the `aws_instance.demo` block from the configuration removes the `lifecycle` block with it, so the guard cannot protect against its own deletion
- state operations such as `terraform state rm` are outside its scope
- an out-of-band termination through the AWS console or API is outside its scope

Removing the Demo instance resource, running a state operation against it, or terminating it out of band therefore each need their own explicit review.

### Deprecation and the required upgrade cycle

The pinned AMI has a deprecation time of `2026-11-24`. Deprecation makes an image harder to discover for new launches; it does not stop the already-running instance. Even so, **an AMI upgrade and host rebuild cycle should be completed before that date** so the pin does not quietly become the reason the host is years behind on OS updates.

Operational TODO: schedule the next upgrade cycle before `2026-11-24`.

### Upgrade procedure

1. Read the current value of the public `ami-amazon-linux-latest` parameter.
2. Compare it against `local.demo_ami_id` and review what changed between the two images.
3. Review the replacement impact: enumerate what the host holds that Terraform will not restore.
4. Confirm the rebuild runbook is current: `bootstrap-host.sh`, `configure-origin.sh`, `configure-acme.sh`, the four-artifact runtime deployment, and the boot convergence systemd unit installation.
5. Open a PR that changes `local.demo_ami_id` and its name comment, recording the new AMI's name, creation date and the review above.
6. Obtain explicit approval to lift `prevent_destroy`, in that same PR or a companion one.
7. Perform the planned replacement with the runbook at hand.
8. Restore `prevent_destroy` immediately, before touching the host.
9. Re-run host bootstrap and configuration.
10. Run the runtime deployment.
11. Run the smoke and origin checks and confirm end-to-end behaviour.

The guard goes back on at step 8 rather than at the end because everything after it is host-side work that Terraform is not involved in. Leaving the guard lifted through bootstrap and verification would mean that if any of those steps fails, the next `plan` or `apply` someone runs is free to replace the instance again. Restoring it early keeps that window as short as the replacement itself.

`prevent_destroy` is Terraform lifecycle configuration, not infrastructure state. Restoring it takes effect from the next plan once the commit is on `main`; there is nothing to apply for the restore itself.

Steps 6 and 8 are what keep the guard meaningful. Leaving it lifted turns it back into decoration.

## RDS runtime contract

- The DB subnet group contains only `private_db["a"]` and `private_db["b"]`. The public app subnet is excluded.
- MariaDB uses `db.t4g.micro`, Single-AZ, private IPv4, and only the existing RDS security group. The RDS Graviton architecture is independent of the EC2 `linux/amd64` container contract.
- `engine_version = "10.11"`, `auto_minor_version_upgrade = true`, and `allow_major_version_upgrade = false` keep the 10.11 family while allowing RDS-managed security/maintenance patch upgrades. AWS currently lists supported 10.11 patches, including 10.11.18. The version prefix avoids pinning an aging patch; `engine_version_actual` must be reviewed on future plans and major upgrades remain prohibited.
- Storage is encrypted 20 GiB gp3. Storage autoscaling, provisioned IOPS/throughput, Multi-AZ, replicas, Proxy, Performance Insights, Enhanced Monitoring, and DB log exports are not configured.
- Automated backup retention is one day. The plan assumes normal automated backups remain within the RDS backup allowance, but excess automated backup or snapshot storage can cost extra. Long-lived manual snapshots are not created; a destructive migration requires a separate snapshot retention and cost review.
- Deletion protection is enabled. Decommissioning requires explicit PO approval, a reviewed change disabling deletion protection, and a separate destroy review. `skip_final_snapshot = true` avoids an automatic long-lived final-snapshot cost for this disposable Demo database; therefore an approved decommission does not provide a final recovery point unless a separately approved manual snapshot is created first. `prevent_destroy` is intentionally not used.
- The initial database is `ecportfolio` and the non-personal master username is `ecadmin`. Creating a least-privilege application DB user separate from the master is a deployment backlog, not part of Phase 3A.

Source: [RDS MariaDB version management](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/MariaDB.Concepts.VersionMgmt.html), [Terraform `aws_db_instance`](https://registry.terraform.io/providers/hashicorp/aws/6.62.0/docs/resources/db_instance)

## Database credential contract

`db_master_password` is a sensitive ephemeral Terraform input. Terraform 1.16 omits the value from plan and state artifacts, and AWS provider 6.62 marks both `aws_db_instance.password_wo` and `aws_ssm_parameter.value_wo` as sensitive write-only arguments. The same ephemeral value is sent to RDS and to the Standard-tier SecureString `/ec-portfolio/demo/db/master-password`; only the non-secret `db_master_password_version` is persisted.

The input must contain 16-41 printable ASCII characters excluding space and all other whitespace. Slash (`/`), at sign (`@`), double quote (`"`), and single quote (`'`) are also rejected. Non-ASCII input, including Japanese, Korean, and emoji, fails Terraform variable validation before any provider operation.

The SecureString uses the AWS-managed `alias/aws/ssm` key. No secret value is accepted through a committed tfvars file, backend configuration, resource tag, output, or ordinary `password`/`value` argument. Supply it only through an approved ephemeral execution channel that does not log the value. Rotation requires a new secret and an incremented version in the same reviewed operation. If either RDS or SSM update fails, retain the same secret/version securely and retry to convergence rather than incrementing again.

The applied Phase 4A EC2 policy grants `ssm:GetParameter` on this exact parameter and the JWT parameter only. `ssm:GetParameters`, `ssm:GetParametersByPath`, wildcard Parameter Store access, and explicit KMS permissions remain prohibited.

Sources: [Terraform ephemeral variables](https://developer.hashicorp.com/terraform/language/block/variable#ephemeral), [Terraform write-only arguments](https://developer.hashicorp.com/terraform/language/manage-sensitive-data/write-only), [Terraform `aws_ssm_parameter`](https://registry.terraform.io/providers/hashicorp/aws/6.62.0/docs/resources/ssm_parameter)

## Phase 4A deployment foundation

The private `ec-portfolio-demo-api` repository uses immutable tags, AES256 encryption, basic scan-on-push, and `force_delete = false`. Deployment must select an immutable full Git SHA tag and record the resolved digest; it must never depend on `latest`. Enhanced Inspector scanning, cross-Region replication, signing, and deploy automation are outside this phase.

The lifecycle policy retains the thirty newest tagged images for rollback and only the newest untagged image. Phase 5F-2a raised that count from ten because the Demo host is stopped outside a weekday window: a long stop plus frequent publications could otherwise expire the last known good image before it is ever deployed. The provider treats a lifecycle policy change as a replacement, so applying it destroyed and recreated `aws_ecr_lifecycle_policy.demo_api`. That replaces only the policy document: `aws_ecr_repository.demo_api` was untouched and no image was deleted, which the post-apply inventory confirmed. Raising the count also only narrows the expiry set, so it can never widen deletion. Image expiration is asynchronous and count-based: it limits repository growth but does not guarantee a byte-size ceiling. The existing cost model reserves 1 GB, or `$0.10/month` before tax, for ECR. At the stress assumptions, each additional GB is approximately `$0.10 × ¥165/USD × 1.10 = ¥18.15` invoice-equivalent. Same-Region transfer from ECR to EC2 is currently `$0.00/GB`; storage beyond 1 GB consumes the existing variable contingency and must be reviewed before it threatens the ¥5,000 hard ceiling. Free Tier and credits are not assumed.

The Standard SecureString `/ec-portfolio/demo/app/auth-jwt-secret` follows the DB secret's write-only pattern: `auth_jwt_secret` is sensitive and ephemeral, `value_wo` prevents plaintext state storage, and `auth_jwt_secret_version` is the only persisted rotation input. A supplied secret must be at least 32 high-entropy characters. No secret value is committed, tagged, logged, or output; only the parameter name and ARN are non-secret outputs.

The runtime policy is for host-side deployment only. The EC2 host may authenticate to ECR, pull from the exact repository, and fetch the exact DB/JWT parameters with decryption. It must write runtime material to a root-controlled ephemeral location, pass only application values to the container, and remove temporary files after use. The Spring container must not receive AWS credentials or access Instance Metadata/AWS SDK; the IMDS hop limit remains `1`. Phase 4A adds no `user_data`, Docker, Nginx, application install, image push, image pull, or service restart behavior.

Sources: [ECR repository settings](https://registry.terraform.io/providers/hashicorp/aws/6.62.0/docs/resources/ecr_repository), [ECR lifecycle policy properties](https://docs.aws.amazon.com/AmazonECR/latest/userguide/lifecycle_policy_parameters.html), [ECR pricing](https://aws.amazon.com/ecr/pricing/), [Parameter Store SecureString encryption](https://docs.aws.amazon.com/systems-manager/latest/userguide/secure-string-parameter-kms-encryption.html)

## Phase 4C-2A origin foundation

The approved origin hostname is `origin-demo.yoonec.dev` in the existing public Route 53 zone for `yoonec.dev`. Terraform discovers that zone by exact DNS name with `private_zone = false`; a data-source postcondition then requires its ID to equal the runtime-only `route53_public_hosted_zone_id`. A missing zone, duplicate matching public zone, private-only zone, or wrong supplied ID fails the plan rather than selecting a different zone. The hosted zone ID is not hardcoded or output.

One TTL-60 `A` record maps the origin hostname to the existing `aws_eip.ec2_origin.public_ip`. No `AAAA` record, additional EIP, EC2 replacement, subnet change, or security-group change is defined. This prepares public DNS for the existing CloudFront-prefix-list-restricted origin; it does not make the EIP directly reachable from arbitrary Internet sources.

The applied Standard SecureString `/ec-portfolio/demo/origin/verify-token` holds the `X-Origin-Verify` defense-in-depth token. `origin_verify_token` remains sensitive and ephemeral, accepts exactly 32-128 URL-safe `[A-Za-z0-9_-]` characters, and has no default. Together with the unchanged SSM `value_wo`/`value_wo_version` path, this keeps that input and write-only argument out of saved plans and state; only `origin_verify_token_version` is persisted for rotation. No output exposes the value. Phase 4C-2B deliberately introduces a separate non-ephemeral input for the same logical token; the CloudFront copy has the different state boundary documented below. Treat this token as defense in depth layered on the managed prefix-list restriction, not as a DB/JWT-equivalent credential or an application authentication boundary.

Two separate EC2 inline policies preserve reviewable least-privilege boundaries:

- `origin-verification-read` grants only `ssm:GetParameter` on the exact origin-token parameter ARN. It grants no Parameter Store path/list access and no explicit KMS permission.
- `acme-dns-route53` grants `route53:ChangeResourceRecordSets` only on the discovered public zone and only for `TXT`, normalized name `_acme-challenge.origin-demo.yoonec.dev`, and `UPSERT`/`DELETE`. Certbot's Route53 plugin uses `ListHostedZones` to discover the parent zone and `GetChange` to poll propagation; only `ListHostedZones` requires `Resource = "*"`, while `GetChange` is limited to the Route 53 change ARN pattern. The EC2 instance profile supplies short-lived role credentials; no access key or credential file is created.

The AL2023.12 package catalog lists `certbot` and `python3-certbot-dns-route53` in the `2.6.0-4.amzn2023.0.1` package group with Full Support. Certbot upstream documents the three Route 53 API permissions, and its implementation uses `UPSERT` for challenge creation/update, `DELETE` for cleanup, `ListHostedZones` for discovery, and `GetChange` for polling. The separately approved Phase 4C-3 certificate/Nginx setup is complete, with a valid Let's Encrypt certificate and an enabled/active renewal timer. Future maintenance still requires package compatibility and renewal verification under the [runtime runbook](../../runtime/demo/README.md); no package, certificate, private key, timer, or Nginx change is included here.

The existing `yoonec.dev` Route 53 registrar charge is `$17/year`; it is an annual domain cost and is tracked separately from the steady monthly Demo resource subtotal. The existing hosted zone remains `$0.50/month` plus DNS query charges and is already represented by the `$0.54` monthly Route 53 allowance in the architecture cost table. This phase creates neither another hosted zone nor another fixed monthly service. Because the Budget is account-wide, the domain registration or renewal charge can trigger monthly thresholds in its billing month. That expected one-time/annual signal does not change the `30.30 USD` Budget contract.

Sources: [AL2023.12 package list](https://docs.aws.amazon.com/linux/al2023/release-notes/all-packages-AL2023.12.html), [Certbot Route53 plugin](https://certbot-dns-route53.readthedocs.io/en/stable/), [Certbot 2.6.0 Route53 implementation](https://github.com/certbot/certbot/blob/v2.6.0/certbot-dns-route53/certbot_dns_route53/_internal/dns_route53.py), [Route 53 record-level IAM conditions](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/specifying-conditions-route53.html), [Route 53 IAM actions and resources](https://docs.aws.amazon.com/service-authorization/latest/reference/list_route53.html), [Route 53 pricing](https://aws.amazon.com/route53/pricing/)

## Phase 4C-2B CloudFront API distribution

The initial apply created `aws_cloudfront_origin_request_policy.api`, but `CreateDistributionWithTags` returned `InvalidArgument` (HTTP 400): `X-Origin-Verify` was not allowed in both the origin custom header and the origin request policy header configuration. The existing policy must be preserved and updated in place; do not delete it, manually edit AWS resources, or use state removal/import/move to recover. This code-only remediation replaces its header selection with an explicit whitelist before a separately approved distribution creation.

One distribution fronts `origin-demo.yoonec.dev`, never the EIP literal. The custom origin uses HTTPS port 443 and only `TLSv1.2`; the required `http_port = 80` schema field does not enable HTTP origin traffic because `origin_protocol_policy = "https-only"`. The existing origin certificate, DNS, EIP, and CloudFront-prefix-list security group remain unchanged.

The viewer uses the default CloudFront domain/certificate with no alternate domain, ACM viewer certificate, or Route 53 viewer alias. HTTP requests redirect to HTTPS. Viewer IPv6 is enabled without adding an origin `AAAA` record. `PriceClass_200` and the `JP`/`KR` geo allowlist are explicit. Geo restriction is IP-based, is not authentication, and cannot reliably identify a user's physical location or prevent VPN/proxy use. Paid WAF, Shield Advanced, ALB, access-log S3 storage, and frontend hosting are not included. The existing Shield Standard/Nginx guardrails remain important; the prefix list covers CloudFront origin-facing traffic, not exclusively this distribution.

### API cache and forwarding contract

- `CachingDisabled` is referenced by its public AWS-managed policy ID through `data.aws_cloudfront_cache_policy.caching_disabled`; its minimum/default/maximum TTLs are all zero. The required `cached_methods = ["GET", "HEAD"]` field does not enable caching under this policy.
- All seven API methods are allowed: `GET`, `HEAD`, `OPTIONS`, `PUT`, `POST`, `PATCH`, `DELETE`. There is one default behavior and no separately cached API path.
- The explicit `api` origin request policy uses `whitelist`: `Accept`, `Access-Control-Request-Headers`, `Access-Control-Request-Method`, `Authorization`, `Content-Type`, `Origin`, and `X-Correlation-ID`. This preserves bearer authentication, JSON requests, and CORS/preflight inputs. All cookies and query strings are forwarded.
- `X-Correlation-ID` is the only application-specific addition: [CorrelationIdFilter](../../../apps/api/src/main/kotlin/com/nagi4757/ec/api/common/logging/CorrelationIdFilter.kt) validates and reuses a supplied UUID, and [OpenApiConfig](../../../apps/api/src/main/kotlin/com/nagi4757/ec/api/common/config/OpenApiConfig.kt) documents it as an optional request header. Forwarding it preserves existing client-to-server request correlation; no speculative headers are included.
- Viewer `Host` and `X-Origin-Verify` do not appear in the policy header list and are not forwarded. CloudFront generates `Host` from the origin hostname, and only the unchanged origin custom header supplies `X-Origin-Verify` to the origin. A viewer-supplied verification value cannot select the origin token. Do not revert to an all-headers policy or an exclusion list.
- `CachingDisabled` already disables normal and error response caching. The explicit `custom_error_response` settings with `error_caching_min_ttl = 0` are retained as an additional safeguard to pin the API error-cache contract and avoid relying on implicit/default behavior, without rewriting status codes or bodies. CloudFront does not cache `416` responses, so no override is defined for that status.

No application CORS or response-header policy is introduced. Forwarding CORS inputs does not itself permit a browser origin; that remains the application's separately reviewed contract. Post-apply verification must cover authenticated/unauthenticated requests, cookies/query strings, CORS preflight, spoofed verification headers, HTTPS redirection, and JP/KR versus blocked locations. These runtime checks are not claimed by static validation.

Sources: [CloudFront header selection](https://docs.aws.amazon.com/cloudfront/latest/APIReference/API_OriginRequestPolicyHeadersConfig.html), [Custom origin headers and Authorization](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/add-origin-custom-headers.html), [Managed origin request policies and Host](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-origin-request-policies.html), [CachingDisabled](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/using-managed-cache-policies.html), [Error cache TTL](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/custom-error-pages-expiration.html)

### Accepted CloudFront token state boundary

`cloudfront_origin_verify_token` is a new required string: sensitive, **non-ephemeral**, no default, with the same 32-128 URL-safe validation as the existing token. Only `custom_header.value` consumes it. The existing `origin_verify_token` variable and SSM write-only/version arguments are unchanged. No SSM secret data source, generated replacement token, rotation, or secret output is introduced.

Architecture explicitly accepts that the **CloudFront header value is included in encrypted Terraform remote state**. It is also retained in saved plans and readable by appropriately authorized CloudFront configuration readers. `sensitive = true` redacts normal CLI presentation; it does not encrypt a local saved plan or hide plaintext from state readers, `terraform show -json`, or equivalent exports. Protect plan/state files, their backups, and access permissions; never print, upload to PR/CI artifacts, or commit their contents. This is a distinct boundary from the still-ephemeral DB/JWT inputs.

For initial rollout, the operator must supply the same existing Keychain token used by SSM/Nginx to both origin-token inputs through a protected, non-logging channel. Matching these values is an explicit rollout gate; Terraform does not fetch the SSM plaintext to compare them. A mismatch causes Nginx to reject origin requests. No actual value belongs in locals, documentation, examples, tfvars, tags, outputs, or logs. Token rotation remains a separate Architecture/PO operation.

Only `cloudfront_distribution_id` and `cloudfront_distribution_domain_name` remain as non-secret CloudFront outputs; their definitions are unchanged. Recovery expects one distribution create and one in-place origin request policy update, plus the unchanged managed-policy read; a real plan is still required under separate approval. All other previously applied resources, including Phase 4C-2A and Phase 4A, must remain unchanged.

Sources: [Terraform sensitive data boundaries](https://developer.hashicorp.com/terraform/language/manage-sensitive-data), [CloudFront distribution](https://registry.terraform.io/providers/hashicorp/aws/6.62.0/docs/resources/cloudfront_distribution), [CloudFront origin request policy](https://registry.terraform.io/providers/hashicorp/aws/6.62.0/docs/resources/cloudfront_origin_request_policy)

## Runtime schedule contract

All four schedules belong to `ec-portfolio-demo-runtime`, use the `Asia/Tokyo` timezone, are `ENABLED`, and disable the flexible time window. The RDS lead/lag reduces application connection failures during startup and shutdown.

| Operation | Scheduler expression | Universal target | Input shape |
|---|---|---|---|
| RDS start | `cron(50 9 ? * MON-FRI *)` | `arn:aws:scheduler:::aws-sdk:rds:startDBInstance` | `DbInstanceIdentifier = aws_db_instance.demo.identifier` |
| EC2 start | `cron(0 10 ? * MON-FRI *)` | `arn:aws:scheduler:::aws-sdk:ec2:startInstances` | `InstanceIds = [aws_instance.demo.id]` |
| EC2 stop | `cron(0 17 ? * MON-FRI *)` | `arn:aws:scheduler:::aws-sdk:ec2:stopInstances` | `InstanceIds = [aws_instance.demo.id]` |
| RDS stop | `cron(10 17 ? * MON-FRI *)` | `arn:aws:scheduler:::aws-sdk:rds:stopDBInstance` | `DbInstanceIdentifier = aws_db_instance.demo.identifier` |

The target inputs are generated with `jsonencode`. RDS Query/API documentation names the request field `DBInstanceIdentifier`, while EventBridge Scheduler Universal AWS SDK target validation requires the SDK request JSON casing `DbInstanceIdentifier`. Scheduler targets therefore use `DbInstanceIdentifier`; exact request-shape casing and an actual invocation remain mandatory post-apply checks. Lambda is not used.

The dedicated execution role trusts only `scheduler.amazonaws.com`. `aws:SourceAccount` resolves from the current caller identity and `aws:SourceArn` equals the exact schedule group ARN, as required by the Scheduler confused-deputy contract. Its inline policy permits only EC2 Start/Stop on `aws_instance.demo.arn` and RDS Start/Stop on `aws_db_instance.demo.arn`; it has no terminate, delete, Lambda, SSM, S3, Organizations, or wildcard resource permission.

Each target retains an event for at most 900 seconds and makes at most three retries. One standard-resolution alarm watches `AWS/Scheduler` `InvocationDroppedCount` with the `ScheduleGroup` dimension, `Sum >= 1`, and missing data treated as not breaching. This metric represents a final drop after retries are exhausted, so a transient first attempt does not page by itself.

Phase 3B intentionally does not create an SQS DLQ: four simple lifecycle calls have bounded retries, final-drop detection, and a separate cost fallback. This keeps the Demo guardrail small, but it accepts less failure-payload evidence than a DLQ. Add a DLQ only through a later reviewed incident-analysis requirement; it is not technically required for universal targets.

Sources: [Scheduler cron and time zones](https://docs.aws.amazon.com/scheduler/latest/UserGuide/schedule-types.html), [Universal targets and input](https://docs.aws.amazon.com/scheduler/latest/UserGuide/managing-targets-universal.html), [Scheduler confused-deputy prevention](https://docs.aws.amazon.com/scheduler/latest/UserGuide/cross-service-confused-deputy-prevention.html), [Scheduler CloudWatch metrics](https://docs.aws.amazon.com/scheduler/latest/UserGuide/monitoring-cloudwatch.html), [RDS StartDBInstance](https://docs.aws.amazon.com/AmazonRDS/latest/APIReference/API_StartDBInstance.html), [RDS StopDBInstance](https://docs.aws.amazon.com/AmazonRDS/latest/APIReference/API_StopDBInstance.html)

## Alert and cost guardrail contract

`ec-portfolio-demo-alerts` is a Standard SNS topic shared by the Scheduler final-failure alarm and AWS Budget. The email endpoint comes only from required sensitive variable `alert_email`; there is no default or committed example address, and the email is never output. Unlike the write-only database password, the provider must persist subscription metadata, including the endpoint, in Terraform state. State readers can therefore see it.

The subscription remains `PendingConfirmation` until the recipient accepts the SNS confirmation email. No Scheduler or Budget email is considered operational before confirmation. The topic policy grants `sns:Publish` separately to AWS Budgets and CloudWatch, each limited by current `aws:SourceAccount`, the exact topic ARN, and the exact Budget or alarm `aws:SourceArn`. No 12-digit account ID is committed.

Server-side topic encryption is intentionally not enabled. Alerts must never contain a password, token, secret, customer record, or request body; a customer-managed KMS key would add cost and requires extra Budgets/KMS policy that can silently break delivery. Revisit encryption with an explicit payload and key-policy design if alert sensitivity changes.

The monthly account-wide COST Budget is alert-only and has no Budget Action or control role:

- Limit: `30.30 USD` of tax-inclusive cost, equivalent to `30.30 × ¥165/USD = ¥4,999.50` under the stress FX assumption.
- Actual 70% threshold exceeded: `21.21 USD × ¥165/USD = ¥3,499.65`, approximately ¥3,500 Warning.
- Actual 90% threshold exceeded: `27.27 USD × ¥165/USD = ¥4,499.55`, approximately ¥4,500 Critical.
- Forecasted 90% threshold exceeded: predicted tax-inclusive spend above `27.27 USD`, approximately ¥4,500 under stress FX.
- Actual 100% threshold exceeded: tax-inclusive spend above `30.30 USD`, approximately ¥5,000 Strong alert.

The Budget has no project/tag filter, so it watches the whole AWS account and does not miss global, untagged, or not-yet-activated cost-allocation-tag spend. Its `cost_types` selects unblended cost with both `use_blended` and `use_amortized` false, includes tax, recurring/upfront/subscription/support/discount costs, and excludes credits and refunds. AWS provider 6.62 treats the newer `metrics` argument as part of `filter_expression` and conflicts it with `cost_types`, so this account-wide budget uses the supported `cost_types` path. Promotional credits or refunds therefore cannot reduce the monitored spend and hide resource burn. Free Tier or credit is not a condition of the architecture cost model.

Because `include_tax = true`, the cost compared with this Budget is already tax-inclusive. Interpret a Budget threshold as `tax-inclusive USD × FX = invoice-equivalent JPY`; do not multiply by JCT again. This differs from the architecture's infrastructure estimate, which starts with tax-exclusive AWS resource prices and correctly calculates `pre-tax resource estimate + 10% JCT = estimated invoice`.

AWS Budget is not a hard spending cap and does not stop resources. Billing data is updated at least daily, so both cost data and notifications can lag. A forecast also needs about five weeks of usage history and may be absent for a new account. Actual 70/90/100 alerts remain the primary cost signals; the control stack is the EC2/RDS schedule, resource-only `AutoStop` tags, the Scheduler final-failure alarm, and delayed Budget alerts together.

Sources: [AWS Budgets cost types](https://docs.aws.amazon.com/aws-cost-management/latest/APIReference/API_budgets_CostTypes.html), [AWS Budgets best practices and update frequency](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-best-practices.html), [AWS Budgets SNS policy](https://docs.aws.amazon.com/cost-management/latest/userguide/budgets-sns-policy.html), [AWS Budgets pricing](https://aws.amazon.com/aws-cost-management/aws-budgets/pricing/)

### Guardrail cost check

Price check date: 2026-08-31. Four weekday schedules at 22 weekdays produce 88 normal invocations per month. Scheduler lists $1.00 per million invocations above its current monthly allowance; without using that allowance, `88 / 1,000,000 × $1.00 = $0.000088`. Even three retries on every invocation would remain below $0.0004.

The action-free monitoring Budget costs $0.00. One standard-resolution CloudWatch alarm is conservatively $0.10 per alarm-metric-month without using its current allowance. A Standard SNS topic has no fixed monthly fee; even ten 64 KiB API requests and ten email deliveries at $0.50/million requests and $2.00/100,000 email deliveries are about $0.000205 before any allowance.

The added guardrails are therefore approximately $0.101/month without relying on free request/delivery/invocation allowances. The existing architecture already reserves $0.01 for Scheduler, $1.00 for CloudWatch, and a separate $2.00 variable contingency, so this phase does not consume the cost buffer unexpectedly. Prices vary by region and time and must be rechecked before the combined plan/apply.

Sources: [EventBridge Scheduler pricing](https://aws.amazon.com/eventbridge/pricing/), [CloudWatch pricing](https://aws.amazon.com/cloudwatch/pricing/), [SNS pricing](https://aws.amazon.com/sns/pricing/), [AWS Budgets pricing](https://aws.amazon.com/aws-cost-management/aws-budgets/pricing/)

## Phase 3 live verification and code-only gates

Phases 1, 3A/3B, 4A, and 4C-2A are applied, and the approved pre-4C-2B convergence check reported `No changes`. Phase 4A includes the ECR repository, JWT SecureString, and EC2 runtime deployment IAM policy. The four schedules, confirmed SNS subscription, `OK` failure alarm, alarm-to-SNS path, and `30.30 USD` monthly Budget are verified.

The first complete weekday stop/start cycle is verified by read-only status checks:

- 2026-09-01 17:00 JST: EC2 reported `stopped` after its scheduled stop.
- 2026-09-01 17:10 JST: RDS reported `stopped` after its scheduled stop.
- 2026-09-02 09:50 JST: RDS reported `available` after its scheduled start.
- 2026-09-02 10:00 JST: EC2 reported `running` after its scheduled start.

Keep the following contract checks as operational regression guards:

- All four schedules are `ENABLED`, show `Asia/Tokyo`, have flexible windows off, and preview the expected next invocation.
- The execution-role trust has the current account and exact schedule group ARN; its policy has only the exact EC2/RDS resource ARNs and four Start/Stop actions.
- Universal target inputs use `InstanceIds` and `DbInstanceIdentifier` with the actual resource identifiers.
- The SNS email subscription remains `Confirmed` and the alarm-to-SNS path remains functional.
- The group-level CloudWatch alarm remains `OK`, and the Budget remains active with all four SNS notifications connected.
- The verified EC2 17:00 and RDS 17:10 stop invocations continue to reach `stopped` without a final-failure alarm.
- `AWS/Scheduler` `InvocationDroppedCount` remains zero for the runtime schedule group.
- The RDS 09:50 start completes before the EC2 10:00 start, and both resources reach their verified ready states.

The observed resource states provide invocation evidence in addition to the `OK` failure alarm. Retain the stop/start evidence during operational review. If a manual interview/demo start extends beyond the standard window, the same day's stop schedules remain the automatic stop policy; an extension after those times requires an explicit manual stop and cost review.

The applied Phase 4C-2A Route 53 `A` record, origin SecureString, and two EC2 inline IAM policies must remain `no-op` in Phase 5E. Phase 4A, both Phase 4C-2B resources, and every Phase 5A hosting resource must also have zero delta. Any previously applied resource create/change/replacement/destroy is a blocker: stop and report backend/state selection, AWS identity, and live drift concerns instead of applying or editing existing resources.

## Phase 5A Store/Admin static hosting

Phase 5A is applied and converged. The two frontends use separate buckets, OACs, and distributions, with shared static-only cache policies and one route-independent viewer-request function:

```text
Browser -> Store CloudFront -> Store private S3 REST origin
Browser -> Admin CloudFront -> Admin private S3 REST origin
Browser -> existing API CloudFront -> existing HTTPS EC2 origin
```

There is no API origin or API proxy behavior in either frontend distribution. The deployed builds use `https://d1q0vfmnxby7vo.cloudfront.net` as public `VITE_API_BASE_URL`; it contains no token or secret. Terraform does not manage frontend objects. Phase 5E adds only the dedicated artifact-deploy identity and workflow; it does not change frontend source, Route 53, ACM, runtime IAM, API CORS, or either distribution. The Admin static bundle is not confidential or an authorization boundary: API authentication and ADMIN authorization remain mandatory.

### S3 and OAC boundary

- Both buckets use generated globally unique names with `ec-portfolio-demo-store-` / `ec-portfolio-demo-admin-` prefixes. No account ID is hardcoded.
- All four Public Access Block settings are enabled. `BucketOwnerEnforced` disables ACLs; no ACL resource or public policy is created.
- SSE-S3 (`AES256`) avoids a new KMS key or KMS grants. Non-TLS S3 requests are explicitly denied.
- Each bucket policy grants the CloudFront service principal only `s3:GetObject` on that bucket's objects, conditioned on its own exact distribution ARN. OAC always signs with SigV4, using the regional S3 REST endpoint over HTTPS, not S3 website hosting. No cross-frontend OAC read grant is present.
- These policies restrict viewer access through CloudFront; separately privileged account administrators remain an IAM governance boundary. The Phase 5E role can only read and write objects in these two buckets and cannot change bucket or CloudFront configuration.
- `force_destroy = false`; Terraform does not manage `aws_s3_object`, releases, object metadata, versioning, or artifact deletion. The Phase 5E workflow retains content-hashed assets and immutable `_releases/<git-sha>/` snapshots; cleanup requires a separate cost and lifecycle review.

### Delivery, routing, and cache contract

Both distributions use `PriceClass_200`, JP/KR geo allowlists, IPv6, HTTP-to-HTTPS redirect, default CloudFront viewer certificates, GET/HEAD only, and compression with gzip/Brotli cache-key normalization. No aliases, WAF, Origin Shield, Lambda@Edge, log-delivery resources, or paid fixed-cost service is added. Country restrictions reduce exposure but do not replace authentication and cannot prevent VPN/proxy use.

The viewer-request function rewrites extensionless GET/HEAD navigation to `/index.html`, including `/`, `/login`, `/products/4/`, `/orders/3`, and future frontend routes. It never hardcodes application route names. `/api`, `/api/*`, `/assets`, `/assets/*`, and paths containing a dot remain unchanged. Dotted client-side routes are intentionally treated as file-like paths and would need an explicit future routing decision. Other HTTP methods are never rewritten and are not allowed by the static distributions.

The function changes only `request.uri`; query strings, duplicate query values, headers, and cookies remain intact. The browser retains its original route/query string for React. The static cache policies deliberately omit query strings, cookies, and viewer headers from the S3 request/cache key: these requests fetch the same static shell, not query-dependent API content. This has no effect on the existing API's forwarding policy.

| Behavior | CDN min/default/max TTL | Next deployment's object metadata |
|---|---|---|
| Default, HTML, SPA shell, non-hashed root files | `0 / 0 / 60` seconds | HTML: `Cache-Control: no-cache` |
| `/assets/*` content-hashed files | `0 / 86400 / 31536000` seconds | `Cache-Control: public,max-age=31536000,immutable` |

Deployment places only content-hashed artifacts under `/assets/`, uploads both applications' assets before non-hashed files and publishes `index.html` last. It sets content types and cache metadata explicitly. CDN maximum TTL does not cap browser caching, so correct HTML object metadata remains a deployment gate. Real S3 403/404 responses are not mapped to HTML 200. Their configured error TTL is zero, although CloudFront enforces a one-second minimum for S3-origin errors.

### Managed resources and outputs

Phase 5A applied the following 17 resources and subsequently converged with no planned changes:

| Resource address | Instances |
|---|---:|
| `aws_s3_bucket.frontend` | `store`, `admin` (2) |
| `aws_s3_bucket_public_access_block.frontend` | `store`, `admin` (2) |
| `aws_s3_bucket_ownership_controls.frontend` | `store`, `admin` (2) |
| `aws_s3_bucket_server_side_encryption_configuration.frontend` | `store`, `admin` (2) |
| `aws_s3_bucket_policy.frontend` | `store`, `admin` (2) |
| `aws_cloudfront_origin_access_control.frontend` | `store`, `admin` (2) |
| `aws_cloudfront_distribution.frontend` | `store`, `admin` (2) |
| `aws_cloudfront_cache_policy.frontend_shell` | 1 |
| `aws_cloudfront_cache_policy.frontend_assets` | 1 |
| `aws_cloudfront_function.frontend_spa_rewrite` | 1 |

New outputs expose only the Store/Admin bucket names and each distribution's ID/domain. Existing API outputs and all secret contracts remain unchanged. The frontend resources neither consume nor duplicate `cloudfront_origin_verify_token`.

The [Phase 5A cost model](../../../docs/architecture/aws-demo.md#phase-5a-static-hosting-cost-increment) reserves `$0.8155/month` before tax for both frontends together, without free allowances. Keeping the existing `$2` contingency gives a conditional invoice estimate of `¥4,541.89` at ¥160/USD and `¥4,683.83` at ¥165/USD, including JCT. The latter leaves `¥316.17` below ¥5,000. Phase 5E adds no fixed-cost service; retained release storage and deployment requests remain inside the existing frontend allowance but require monitoring.

Sources: [S3 OAC](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html), [CloudFront Functions URI rewrite](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/example_cloudfront_functions_url_rewrite_single_page_apps_section.html), [Cache expiration](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/Expiration.html), [Error caching](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/custom-error-pages-expiration.html)

## Phase 5E GitHub frontend deployment

Phase 5E defines an account-level GitHub OIDC provider and a dedicated `ec-portfolio-demo-github-frontend-deploy` role. The trust policy uses `StringEquals` for both `aud = sts.amazonaws.com` and the verified exact subject `repo:nagi4757/ec-portfolio:environment:demo-frontend`; it contains no repository, branch, or environment wildcard. The role grants only `s3:GetObject` and `s3:PutObject` on the existing Store/Admin object ARNs. It has no delete, list, ACL, bucket-configuration, CloudFront, IAM, SSM, application secret, or Terraform state access. Conditional `PutObject` plus exact manifest keys make bucket listing unnecessary. These three resources are applied and converged; a re-run of the plan reports `No changes`.

The existing CI workflow adds `deploy-frontends` with `needs = [backend, frontend, docker]`. It runs only for a push to `main`, uses the `demo-frontend` GitHub Environment, checks that its queued commit is still `origin/main`, builds Store and Admin with the public API URL `https://d1q0vfmnxby7vo.cloudfront.net`, and obtains a 15-minute AWS session through GitHub OIDC. Long-lived AWS access keys are forbidden. The workflow validates the exact account, role, and bucket inputs before requesting AWS credentials.

`deploy-frontends.sh validate` checks both build directories before the workflow requests AWS credentials. It rejects symlinks, source maps, unexpected nested files, unknown root artifacts, and `/assets/` names without a content hash. `deploy-frontends.sh deploy` repeats that validation, creates an immutable `_releases/<git-sha>/` snapshot and `manifest.sha256` in each bucket, then publishes both applications in this order:

1. Content-hashed `/assets/*` with `public,max-age=31536000,immutable`
2. Non-hashed root files with `no-cache`
3. `index.html` with `no-cache`

Immutable uploads use `If-None-Match: *`. An existing key is accepted only when its content checksum, `Cache-Control`, and `Content-Type` match; otherwise deployment fails without overwriting it. The script never invokes S3 sync/delete or CloudFront. `deploy-frontends.sh rollback` is a script-level primitive only: it downloads and verifies both selected release manifests and snapshots, then republishes them in the same assets-first/HTML-last order using only `GetObject` and `PutObject`. No GitHub Actions entrypoint invokes it yet, because the workflow has no `workflow_dispatch` trigger and the deploy role can be assumed only from the `demo-frontend` environment; a manual rollback entrypoint is deferred to a later phase. Old releases are not deleted automatically.

CloudFront invalidation is intentionally absent. Hashed assets use new names, frontend shell objects use `no-cache`, and the existing default behavior has a zero-second default TTL. If an exceptional invalidation is later required, its exact distribution ARNs and paths need a separate permission and cost gate.

NOTE: `_releases/<git-sha>/` snapshots live in the same bucket as the served site, so the existing default CloudFront behavior serves them at `/_releases/<git-sha>/...`; their file extensions keep them out of the SPA rewrite, and release SHAs are public in this repository. The snapshots hold only the production artifacts that are already served: `deploy-frontends.sh` rejects source maps and hidden files, and a re-check of both build outputs found no `.map` file, no `sourceMappingURL` reference, and no credential or token, only the public API CloudFront URL. Phase 5E therefore leaves every CloudFront behavior and bucket policy unchanged; restricting `/_releases/*` would be a separate distribution change with its own approval.

The `demo-frontend` GitHub Environment is created with a custom deployment branch policy that allows only `main` (one branch, no tags), and these non-secret Environment variables are configured from the approved Terraform outputs and account metadata:

- `AWS_ACCOUNT_ID`
- `AWS_FRONTEND_DEPLOY_ROLE_ARN`
- `STORE_BUCKET_NAME`
- `ADMIN_BUCKET_NAME`

Referencing an unprotected environment is not an acceptable substitute for that gate. The OIDC provider and role are applied and converged, so the deploy job's AWS trust path is already in place. Terraform apply and GitHub Environment configuration are complete; the first frontend object deployment remains a separate explicit approval.

Sources: [GitHub OIDC for AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws), [IAM OIDC providers](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html), [S3 `PutObject`](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html), [CloudFront versioned files](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/Invalidation.html)

## Phase 5F-1 GitHub backend image publication

Phase 5F-1 is the first of three backend continuous-delivery stages. Its scope stops at publishing an immutable API image and recording the deployment state that later stages converge to. **It does not deploy to EC2.** Systems Manager Run Command, the EC2 instance role change that Run Command requires, readiness verification, and rollback all belong to Phase 5F-2, and the boot-time reconciliation unit belongs to Phase 5F-3. Nothing in this stage touches the running Demo API, the RDS schema, CloudFront, CORS, the frontend pipeline, or any existing runtime secret.

The design is desired-state rather than push-to-host. The Demo EC2 instance and RDS are stopped outside a weekday window, so a pipeline that deploys synchronously would fail for every push made while the host is down. Instead the image and the desired state are always recorded, and later stages converge the host to them. Phase 5F-1 delivers the recording half, which is independently useful and carries no host risk.

Phase 5F-1 reuses the account-level GitHub OIDC provider created in Phase 5E and adds a dedicated `ec-portfolio-demo-github-backend-deploy` role. Its trust policy uses `StringEquals` for both `aud = sts.amazonaws.com` and the exact subject `repo:nagi4757/ec-portfolio:environment:demo-backend`; it contains no repository, branch, or environment wildcard, and it is separate from the frontend role. Long-lived AWS access keys remain forbidden.

The role grants only what publication needs:

| Statement | Actions | Resource |
|---|---|---|
| `GetEcrAuthorizationToken` | `ecr:GetAuthorizationToken` | `*`, because the API supports no resource-level restriction |
| `InspectExistingApiImage` | `ecr:DescribeImages` | the Demo API repository ARN |
| `PublishImmutableApiImage` | `ecr:BatchCheckLayerAvailability`, `CompleteLayerUpload`, `InitiateLayerUpload`, `PutImage`, `UploadLayerPart` | the Demo API repository ARN |
| `ReadDeploymentState` | `ssm:GetParameter` | the three deployment-state parameter ARNs |
| `RecordDeploymentState` | `ssm:PutParameter` | the desired and pending parameter ARNs only |

It has no `ecr:*`, `ssm:*`, or `iam:*` wildcard, no image or repository deletion, no lifecycle or tag-mutability change, no SecureString access, and no EC2, Run Command, CloudFront, S3, or Terraform state permission. Write access to `last-known-good-image-sha` is deliberately withheld: that parameter is the reference point for the migration gate, and only a verified Phase 5F-2 deployment may advance it.

### Deployment-state parameters

Three non-secret `String` parameters carry the deployment state. Terraform creates them and seeds them once, then ignores their values, because GitHub Actions owns them at runtime.

| Parameter | Seed | Written by | Purpose |
|---|---|---|---|
| `/ec-portfolio/demo/deploy/desired-image-sha` | `799fddbfa5ed7f663182347f6291163fc4f57983` | GitHub Actions | Image SHA the Demo host should converge to |
| `/ec-portfolio/demo/deploy/last-known-good-image-sha` | `799fddbfa5ed7f663182347f6291163fc4f57983` | Phase 5F-2 only | Last image SHA verified healthy on the host |
| `/ec-portfolio/demo/deploy/pending-migration-image-sha` | `none` | GitHub Actions | Image SHA blocked by the migration gate |

Each parameter also carries an `allowed_pattern`, so Parameter Store itself rejects a malformed value: `^[0-9a-f]{40}$` for the two convergence parameters and `^([0-9a-f]{40}|none)$` for the pending marker. The seed is the image SHA the Demo host is verified to be running today; the tag exists in ECR and the running `ec-portfolio-demo-api` container uses it. Both convergence parameters therefore start consistent with reality, so no later stage can converge the host onto an unverified image. None of these values is a secret, so `String` is correct and no KMS permission is introduced.

### Publication workflow

The existing CI workflow adds `build-and-push-api` with `needs = [backend, docker]`. It runs only for a push to `main`, uses the `demo-backend` GitHub Environment, serialises on its own concurrency group, and obtains a 15-minute AWS session through GitHub OIDC. It checks that its queued commit is still `origin/main`, runs the publication contract test, and validates the exact account and role inputs before requesting AWS credentials. The existing `backend`, `frontend`, `docker`, and `deploy-frontends` jobs are unchanged.

Images are tagged with the full 40-character lowercase Git SHA and nothing else. The repository is `IMMUTABLE`, so `publish-api-image.sh ensure-image` is idempotent by inspection rather than by overwrite:

1. `ecr:DescribeImages` for the exact tag. If the image exists, the build, the ECR login, and the push are all skipped and the existing image is reused.
2. If the repository reports `ImageNotFoundException`, the image is built from `apps/api` and pushed once.
3. If that push is rejected because the immutable tag already exists, the repository is inspected again; the run succeeds only if the tag is genuinely present.
4. Any other inspection or push failure stops the run without starting or retrying a build.

A re-run of the same commit therefore reuses the published image instead of failing. The script never uses `latest`, never deletes or retags an image, and never changes tag mutability.

The `docker` CI job verifies its own local build, not the artifact the registry receives, so `ensure-image` re-asserts the same core contract on the exact tagged image immediately after building it and before any ECR credential is used: the non-root `10001:10001` runtime user, the expected `java -jar /app/app.jar` entrypoint, exactly one exposed `8080/tcp` port, a single `/app/app.jar` entry under `/app`, the root-owned mode `444` RDS CA bundle that contains a certificate and no private key, and no `DB_PASSWORD`, `REDIS_PASSWORD`, or `APP_AUTH_JWT_SECRET` in the image environment or build history. A violation stops the run before the push, so an unverified image can never reach ECR.

### Flyway migration gate

Flyway runs at application start, so a new image applies its migrations to the production database as soon as a container starts, and rolling the image back does not roll the schema back. Automatic delivery is therefore fail-closed for any release that changes migrations.

`publish-api-image.sh migration-guard` compares `apps/api/src/main/resources/db/migration` between `last-known-good-image-sha` and the release commit. The reference point is the image actually running, not the pushed commit's parent, so a migration introduced several commits earlier is still caught. When the comparison is clean the run continues. When it is not:

- the image stays in ECR, so the reviewed artifact is preserved;
- `pending-migration-image-sha` records the blocked SHA;
- `desired-image-sha` is **not** updated, which also blocks the Phase 5F-3 boot-time convergence path, not only this workflow;
- the job fails with the changed migration files and the manual release procedure.

An unreadable, malformed, or unknown `last-known-good-image-sha` also fails closed. A warning that still deploys is explicitly not an acceptable substitute. Only after the gate passes does `record-desired` write `desired-image-sha` and reset `pending-migration-image-sha` to `none`; a passing gate means there is no migration delta against the running image, so clearing the marker is safe.

### Planned resources and gates

The code expectation is **5 add / 0 change / 0 destroy**, subject to the actual approved plan:

| Resource address | Instances |
|---|---:|
| `aws_iam_role.github_backend_deploy` | 1 |
| `aws_iam_role_policy.github_backend_deploy` | 1 |
| `aws_ssm_parameter.deploy_desired_image_sha` | 1 |
| `aws_ssm_parameter.deploy_last_known_good_image_sha` | 1 |
| `aws_ssm_parameter.deploy_pending_migration_image_sha` | 1 |

The GitHub OIDC provider is reused, so it is not an add. Every previously applied resource, including the EC2 instance role, must show zero delta; a `change` on the EC2 role belongs to Phase 5F-2 and is a blocker here. New outputs expose only the backend role ARN and the three parameter names.

Before the deploy job can run, the `demo-backend` GitHub Environment must exist with a custom deployment branch policy that allows only `main` and these non-secret Environment variables:

- `AWS_ACCOUNT_ID`
- `AWS_BACKEND_DEPLOY_ROLE_ARN`

Terraform apply, GitHub Environment creation, the first API image publication, and commit/push each remain a separate explicit approval. As of this document, none of them has been performed.

Sources: [GitHub OIDC for AWS](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws), [ECR image tag mutability](https://docs.aws.amazon.com/AmazonECR/latest/userguide/image-tag-mutability.html), [ECR IAM action reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonelasticcontainerregistry.html), [Parameter Store parameter types](https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-about-examples.html)

## Phase 5F-2a runtime state and release guards

Phase 5F-2 is split so that everything independent of the Demo host lands first. **Phase 5F-2a publishes no deployment and touches no EC2 resource.** It records the non-secret runtime configuration the host will need, raises the rollback retention window, and closes two ways a release could reach the database or lose its rollback path. Systems Manager Run Command, the EC2 instance role change it requires, the deployment wrapper, and the deploy job are all Phase 5F-2b.

### Runtime parameters

Five non-secret `String` parameters carry the runtime configuration that `deploy-api.sh` currently receives from an operator's shell. Terraform owns the values, so they cannot drift from the infrastructure that produces them.

| Parameter | Value source | `allowed_pattern` |
|---|---|---|
| `/ec-portfolio/demo/runtime/db-host` | `aws_db_instance.demo.address` | `^[A-Za-z0-9.-]{1,255}$` |
| `/ec-portfolio/demo/runtime/db-port` | `aws_db_instance.demo.port` | `^[0-9]{1,5}$` |
| `/ec-portfolio/demo/runtime/db-name` | `aws_db_instance.demo.db_name` | `^[A-Za-z0-9_]{1,64}$` |
| `/ec-portfolio/demo/runtime/db-username` | `aws_db_instance.demo.username` | `^[A-Za-z0-9_]{1,64}$` |
| `/ec-portfolio/demo/runtime/cors-allowed-origins` | Phase 5C contract, below | `^https?://[A-Za-z0-9.:-]+(,https?://[A-Za-z0-9.:-]+)*$` |

The CORS allowlist is the Phase 5C contract and has four entries: the Store and Admin Vite dev servers on `http://127.0.0.1:5174` and `http://127.0.0.1:5173`, plus the two deployed frontend origins, which are interpolated from the applied Phase 5A distributions rather than hardcoded. **Reducing this list to the two CloudFront origins would silently break the Phase 5C contract**, so the loopback entries are written out explicitly and the parameter pattern rejects a malformed list.

No new secret is introduced. The database password and the JWT signing secret stay in their existing SecureStrings, and only the EC2 instance role decrypts them.

### Release guards

`publish-api-image.sh migration-guard` previously compared only `apps/api/src/main/resources/db/migration`. A release could therefore reach the database by repointing Flyway rather than by adding a migration file. The guard now blocks, through the same fail-closed path, when any of the following is true between the last known good image and the release commit:

1. Files under the migration directory changed.
2. A line matching `spring.flyway.`, `org.flywaydb`, `flyway-core`, or `flyway-mysql` changed anywhere under `apps/api/src/main/resources` or in `apps/api/build.gradle.kts`.
3. The release commit no longer declares `spring.flyway.enabled=true` or `spring.flyway.locations=classpath:db/migration`.
4. Flyway is configured in any file other than `apps/api/src/main/resources/application.properties`.

Because the guard matches Flyway lines rather than whole files, unrelated property or dependency edits do not block a release. A Flyway version bump does block one, which is intentional: it can change migration behaviour.

`publish-api-image.sh assert-rollback-image` runs between the migration gate and `record-desired`. It reads `last-known-good-image-sha` and confirms with `ecr:DescribeImages` that the image is still published. If the lifecycle policy has expired it, the run fails **before** the desired image SHA advances, so the workflow never leaves the deployment state pointing at a release whose rollback target no longer exists. Placing the check here also blocks the Phase 5F-3 boot-time convergence path, exactly as the migration gate does. The guard needs no new permission: `ecr:DescribeImages` is already in the Phase 5F-1 role.

### Applied resources and gates

The approved plan was expected to be `5 add / 1 change / 0 destroy`. The provider treats the `policy` argument of `aws_ecr_lifecycle_policy` as forcing a new resource, so the applied result was **6 add / 0 change / 1 destroy**:

| Resource address | Action |
|---|---|
| `aws_ssm_parameter.runtime_db_host` / `runtime_db_port` / `runtime_db_name` / `runtime_db_username` / `runtime_cors_allowed_origins` | create |
| `aws_ecr_lifecycle_policy.demo_api` | replacement (destroy + create), retention `10` to `30` |

```text
Apply complete! Resources: 6 added, 0 changed, 1 destroyed.
No changes. Your infrastructure matches the configuration.
```

The single destroy was the lifecycle policy resource itself. `aws_ecr_repository.demo_api` was not changed and keeps `IMMUTABLE` tags, Git SHA tagging, and the ban on `latest`; no container image was deleted, and both the last known good and desired API images remain in the repository. Every other applied resource, including the EC2 instance role, stayed `no-op`; an EC2 role change belongs to Phase 5F-2b and would be a blocker here. Phase 5F-2b work remains a separate explicit approval.

Sources: [ECR lifecycle policy properties](https://docs.aws.amazon.com/AmazonECR/latest/userguide/lifecycle_policy_parameters.html), [Parameter Store parameter types](https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-about-examples.html), [Flyway Spring Boot configuration](https://docs.spring.io/spring-boot/reference/how-to/data-initialization.html)

## Phase 6C-3 ECS EC2 Spot foundation

Applied on 2026-09-28 (24 added) and converged on 2026-09-29: after a refresh-only state normalization, the convergence plan reports `No changes`. The Auto Scaling group stays at desired capacity `0`, so no Spot instance runs and there is no Spot charge. The On-Demand origin host, its Elastic IP association, CloudFront, Route 53, RDS, and the existing schedules are untouched by this phase.

### What exists after apply

`aws_ecs_cluster.demo`, `aws_ecs_capacity_provider.ecs_spot`, `aws_ecs_cluster_capacity_providers.demo`, `aws_launch_template.ecs_spot`, `aws_autoscaling_group.ecs_spot`, `aws_autoscaling_lifecycle_hook.ecs_spot_launching`, the `ec-portfolio-demo-ecs-spot` instance role and profile, and the private runtime artifact bucket holding one bundle object. No task definition and no ECS service: what runs on this capacity is Phase 6C-4.

### Runtime bundle delivery

`bootstrap-spot-host.sh` is larger than the 16 KiB EC2 raw user-data limit on its own, so the bundle cannot be embedded in the launch template. It is published to S3 instead and the launch template carries only a loader.

Thirteen files are packed into one `tar.gz` by `data.archive_file.spot_runtime_bundle`: `bootstrap-spot-host.sh`, the eleven artifacts the bootstrap requires (three of them added in Phase 6C-4a and two in Phase 6C-5c-2, see below), and a `bundle.sha256` manifest generated from `filesha256` over the same reviewed files. The files are listed one by one rather than swept from `infra/runtime/demo/`, which also holds the standalone host's scripts and every test suite.

The archive is written to `.terraform/ec-portfolio/` so building it never dirties the working tree, and uploaded to a stable key with the object **version** carrying the identity:

- bucket: `ec-portfolio-demo-runtime-artifacts-*`, private, versioned, AES256, Block Public Access on all four settings, bucket policy denying insecure transport only
- key: `runtime/spot-runtime.tar.gz`
- the launch template's user_data pins the **exact S3 version ID** and the **archive SHA256**

A key alone is a mutable pointer: replacing the object would silently change what every existing launch template version executes as root. Pinning the version means publishing a new bundle is a reviewed launch template change, and older launch template versions keep running the bundle they were reviewed with.

The expected SHA256 in user_data is `data.archive_file.spot_runtime_bundle.output_sha256`, never a literal. The archive, the uploaded object and the hash the loader demands therefore come from one expression and cannot drift apart. `hashicorp/archive` is pinned to exactly `2.8.1` for the same reason the AMI IDs are pinned: the tar framing that hash covers is provider implementation, not a documented contract, and a minor upgrade that changed it would move the hash with no change to any reviewed file.

### Chain of trust

`bundle.sha256` detects a partial or corrupted delivery. It is not an authenticity check — anyone who can write the bundle can rewrite the manifest to match. The anchor is therefore outside the bundle: the loader verifies the **whole archive**, bootstrap and manifest included, against a SHA256 that comes from Terraform.

```
reviewed repository files
  -> data.archive_file output_sha256   (one Terraform value)
    -> launch template user_data       (pinned bucket + version ID + hash)
      -> archive verified on the host
        -> bundle.sha256 verified by bootstrap-spot-host.sh
          -> the eleven required artifacts
```

### Bundle rollback

Reverting the runtime files restores the previous archive hash, which produces a **new** object version carrying the old content rather than reusing the old version ID. Rollback is forward-only, which is why noncurrent versions must survive.

`aws_s3_bucket_lifecycle_configuration.runtime_artifacts` therefore has **no** `noncurrent_version_expiration`, only a 7-day incomplete-multipart cleanup. Expiring an old bundle would break every launch template version still pointing at it, and the breakage would surface at launch as `AccessDenied` rather than `NoSuchVersion`, because the instance role holds no `s3:ListBucket` and S3 cannot return a 404 to a caller that cannot list. A bundle is about 26 KiB, so retaining the history costs nothing worth trading for that failure mode.

### Launch lifecycle

`bootstrap-spot-host.sh` already keeps a half-built host out of the cluster: it holds the ECS agent back and disables it again on any failure. What it cannot do is make the Auto Scaling group notice, and an EC2 health check will not either — the operating system is healthy on a host whose TLS restore failed.

So the instance is held in `Pending:Wait` by an `autoscaling:EC2_INSTANCE_LAUNCHING` hook while the bootstrap runs, and the outcome is reported with `CompleteLifecycleAction`. Since Phase 6C-4a there is exactly one reporter at a time: the loader reports `ABANDON` if the pre phase fails, and once the pre phase has queued `ec-portfolio-spot-post-bootstrap.service` that unit reports `CONTINUE`, or `ABANDON` on any failure. `default_result` is `ABANDON` because the failure that has to be survived is the one where nothing reports at all — a loader that died before it read its own instance ID, or a host that never ran user data. Those must not reach `InService` by timing out.

`heartbeat_timeout` is 3600 seconds (1800 in Phase 6C-3). It is sized from configured bounds, not measured: about 12 minutes of pre phase at worst (the ten-minute certbot install budget plus the rest), then the post unit's `TimeoutStartSec=1800s` and `TimeoutStopSec=120s`, about 44 minutes in all. `bootstrap-spot-host.test.sh` reads the unit file and this resource and fails if the sum stops fitting.

`health_check_grace_period` is a different clock and is deliberately short by comparison: it starts when an instance reaches `InService`, which for this group is after `CONTINUE`, so by then the host has already restored its TLS state, joined the cluster and passed an HTTPS smoke check. It only has to cover EC2 status checks settling.

**Open item for Phase 6C-4.** Whether ECS places a task on a container instance whose EC2 instance is still in `Pending:Wait` is not stated directly in AWS documentation. The indirect evidence is strong — the ECS agent gates registration on Auto Scaling state only when `ECS_WARM_POOLS_CHECK` is `true` (it defaults to `false` and the bootstrap does not set it), and even then it waits for the IMDS target lifecycle state to be `InService`, which it already is during a launch hook. If the assumption is wrong the result is a bounded failure, not a hang: `wait_for_api_readiness` gives up after 300 seconds, the post-bootstrap abandons, and Auto Scaling rate-limits launches when lifecycle hooks fail consistently. It must still be confirmed against the first real launch.

### Spot instance role

`ec-portfolio-demo-ecs-spot` is separate from `aws_iam_role.ec2` on purpose: extending the On-Demand host's role would let the host currently serving production join the cluster, which it has no reason to do.

The AWS-managed `AmazonEC2ContainerServiceforEC2Role` is not attached. It grants fifteen actions on `*` and cannot be scoped to one cluster. The inline statements cover the same agent contract with the cluster and repository named, and omit four actions the managed policy includes:

| Omitted | Why |
| --- | --- |
| `ecs:CreateCluster` | The cluster is a Terraform resource. |
| `ecs:TagResource` | The agent only calls it when registering with tags, which needs `ECS_CONTAINER_INSTANCE_TAGS` or `ECS_CONTAINER_INSTANCE_PROPAGATE_TAGS_FROM`. The bootstrap sets neither. |
| `ecs:ListTagsForResource` | Used only by the task metadata endpoint's `/taskWithTags` path. |
| `ec2:DescribeTags` | Read by the agent only when tag propagation is on. Capacity provider association is decided by ECS from the `AmazonECSManaged` tag, server side. |
| `logs:*` | No CloudWatch Logs destination exists in this phase. |

`ecs:DiscoverPollEndpoint` is the only ECS action left on `*`; it has no resource type. Runtime bundle access is `s3:GetObjectVersion` on the single object and nothing else — not `s3:GetObject`, because the loader always supplies a version ID and S3 requires the version-scoped action for that request; granting `s3:GetObject` would add the mutable read this design exists to avoid.

The database password and JWT secret parameters are **not** readable by this role. Those belong to the Phase 6C-4 task execution and task roles.

### Capacity provider settings

| Setting | Value | Reason |
| --- | --- | --- |
| `managed_scaling` | `DISABLED` | Desired capacity belongs to the Phase 6C-5 schedule. With managed scaling on, ECS and the scheduler would be two controllers fighting over one value. |
| `managed_termination_protection` | `DISABLED` | Only meaningful for ECS-driven scale-in, which managed scaling would have done. |
| `managed_draining` | `ENABLED` | The AWS default at creation, and what turns a Spot interruption into a graceful drain. It works regardless of termination protection. ECS attaches its own `EC2_INSTANCE_TERMINATING` hook to implement it — a different transition from the launch hook, so the two do not interact. |

No `default_capacity_provider_strategy` on the cluster: a default would send any `RunTask` that omitted a strategy to the Spot group. The Phase 6C-4 service does not use a strategy either: it is a `DAEMON` on the `EC2` launch type (AWS accepts a launch type or a capacity provider strategy, not both), and its tasks land only on Spot hosts because this capacity provider's group is the cluster's only source of container instances.

### Two settings that are load-bearing and easy to lose

`AmazonECSManaged` is declared as an Auto Scaling group `tag` with `propagate_at_launch = true`. ECS adds this tag itself when a capacity provider is associated, so omitting it from Terraform means every subsequent plan tries to remove it, and instances launched without it are not matched to the capacity provider.

The Auto Scaling group pins a **numeric** launch template version through `aws_launch_template.ecs_spot.latest_version`, never `$Latest`. `$Latest` is resolved by AWS at launch time, which would let a template edit change what the group launches without any plan showing it.

### Local validation without AWS credentials

`terraform plan` needs the protected runtime inputs described under [Local validation](#local-validation) and must be run by the operator. Everything below runs without them:

```
terraform fmt -check -recursive
terraform validate
terraform graph              # builds the dependency graph; fails on a cycle
infra/runtime/demo/bootstrap-spot-host.test.sh
```

The bundle contract can also be exercised end to end without AWS: build the archive, extract it, apply the loader's `chmod`, then source the extracted `bootstrap-spot-host.sh` and call `resolve_bundle` and `verify_bundle_checksums`. Those are the host's own verification functions, so a pass means the Terraform-generated manifest satisfies the Phase 6C-2 contract rather than merely resembling it.

## Phase 6C-4a Spot host bootstrap hardening

Code only; not applied. Two problems are fixed before any Spot host is launched.

**The bootstrap no longer waits for the ECS agent from inside user data.** The Amazon Linux ECS AMI packaging of `ecs.service` (`amazon-linux-ami-integrated`) carries `After=cloud-final.service`. On such an AMI an agent started from user data cannot come up until user data has finished, so the Phase 6C-3 bootstrap — which started the agent and then waited for registration and API readiness inside user data — would time out on every launch and abandon the host. Whether the pinned AMI carries that ordering was not verified against a live instance; the structure below is correct either way.

| Phase | Runs in | Does | Reports |
| --- | --- | --- | --- |
| pre | user data, started by the loader | bundle check, TLS restore, certbot, IMDS guard (installed and proven), `ecs.config`, `systemctl enable ecs`, `systemctl start --no-block ec-portfolio-spot-post-bootstrap.service` | nothing; the loader reports `ABANDON` if pre fails |
| post | `ec-portfolio-spot-post-bootstrap.service`, `After=cloud-final.service ecs.service`, `Wants=ecs.service` | cluster registration, API readiness, HTTPS origin and smoke, renewal timer | `CONTINUE`, or `ABANDON` on any failure or on its start timeout (SIGTERM is trapped) |

```
cloud-final.service ── loader ── pre phase ──(start --no-block)──┐
                                                                 ▼
ec-portfolio-imds-guard.service ──Before= / RequiredBy=──▶ ecs.service
                                                                 │
                                   After=cloud-final.service ecs.service
                                                                 ▼
                               ec-portfolio-spot-post-bootstrap.service ──▶ CONTINUE | ABANDON
```

The post unit has no `[Install]` section: the launch lifecycle action exists only on the first boot, so a reboot does not run it again.

**Host-network containers cannot reach IMDS.** The launch template's hop limit of 1 does not apply to host network mode. `imds-guard.sh` puts one jump at the top of the filter `OUTPUT` chain for `169.254.169.254/32` into `EC_PORTFOLIO_IMDS`, which returns for UID 0 and rejects every other UID. `ec-portfolio-imds-guard.service` re-applies it at every boot, `Before=ecs.service` and `RequiredBy=ecs.service`, so the agent does not start without it. On first boot the pre phase also proves the effect: root obtains an IMDSv2 token, UIDs 10001 (API) and 999 (Valkey) get a refused connection. A host-network container running as UID 0 is not covered; the Phase 6C-4 task definition must not run any container as root. The runtime README has the full model.

No security group, IAM policy, instance role or chain policy changes.

### Expected plan delta when this is applied

| Resource | Action | Why |
| --- | --- | --- |
| `aws_s3_object.spot_runtime_bundle` | update in-place | new `source_hash` (bootstrap, three new artifacts, manifest); a new object version |
| `aws_launch_template.ecs_spot` | update in-place | `user_data` pins the new version ID and SHA256 and carries the new loader; this creates a **new launch template version**, not a replacement |
| `aws_autoscaling_group.ecs_spot` | update in-place | `launch_template.version` follows `latest_version` |
| `aws_autoscaling_lifecycle_hook.ecs_spot_launching` | update in-place | `heartbeat_timeout` 1800 → 3600 |

Expected `0 to add, 4 to change, 0 to destroy`, with output changes to `spot_runtime_bundle_sha256`, `spot_runtime_bundle_version_id` and `ecs_spot_launch_template_version`. Anything else — in particular any change to the On-Demand host, RDS, CloudFront, Route 53 or SSM — is a blocker.

The apply launches no instance: `desired_capacity = 0` is unchanged and still managed by Terraform, managed scaling is `DISABLED`, and the group has no `instance_refresh` block, so a new launch template version only affects instances launched later. The permissions for these four update calls (`s3:PutObject` on the bundle key, `ec2:CreateLaunchTemplateVersion`, `autoscaling:UpdateAutoScalingGroup`, `autoscaling:PutLifecycleHook`) are already in `ECPortfolioTerraformApplySpotFoundation`.

### Local validation without AWS credentials

```
terraform fmt -check -recursive
terraform validate
infra/runtime/demo/bootstrap-spot-host.test.sh
infra/runtime/demo/imds-guard.test.sh
infra/runtime/demo/spot-user-data-loader.test.sh
infra/runtime/demo/spot-runtime-bundle.test.sh
```

`spot-runtime-bundle.test.sh` checks that `spot_bundle_manifest_artifacts`, the loader's mode lists and `REQUIRED_BUNDLE_ARTIFACTS` name the same files, then builds a bundle from the repository and runs the bootstrap's own `resolve_bundle` and `verify_bundle_checksums` on it. `spot-user-data-loader.test.sh` renders the template, runs it against recording fakes, and checks the rendered upper bound against the 16 KiB user-data limit.

## Phase 6C-4 ECS application layer

Code only; not applied. `ecs_application.tf` defines what runs on the Spot capacity: one task per container instance, API and Valkey side by side on the host network.

| Resource | Name | Notes |
| --- | --- | --- |
| `aws_cloudwatch_log_group.ecs_api` | `/ec-portfolio/demo/ecs/api` | 7-day retention, no KMS key |
| `aws_iam_role.ecs_task_execution` | `ec-portfolio-demo-ecs-task-execution` | trust `ecs-tasks.amazonaws.com` only; no managed policy |
| `aws_iam_role_policy.ecs_task_execution_ecr_pull` | `ecr-image-pull` | `ecr:GetAuthorizationToken` on `*`; the three pull actions on `ec-portfolio-demo-api` only |
| `aws_iam_role_policy.ecs_task_execution_runtime_secrets` | `runtime-secrets-read` | `ssm:GetParameters` on the DB password and the JWT secret only; no `kms:Decrypt` (`alias/aws/ssm`) |
| `aws_iam_role_policy.ecs_task_execution_logs` | `api-task-logs-write` | `logs:CreateLogStream`, `logs:PutLogEvents` on the log group's streams only |
| `aws_ecs_task_definition.api` | family `ec-portfolio-demo-api` | `host` network, `EC2`, execution role only (no task role) |
| `aws_ecs_service.api` | `ec-portfolio-demo-api` in `ec-portfolio-demo` | `DAEMON`, launch type `EC2`, no desired count, no capacity provider strategy, no load balancer, no service connect, execute command off, AZ rebalancing off, no wait for steady state |

The names are the ones the Access IaC grants on (Phase 6C-4 ECS application permissions in `infra/terraform/access/README.md`); a different name fails with an AccessDenied. The three inline policies are the reviewed task execution role document (canonical `77dcb0cccd66dd1b32d4c59bd4a8ebbc1752c957f7b7f90c758aa2bcb9da3374`).

The DAEMON service is what the bootstrap's post phase relies on: every host that registers gets exactly one task, and the post phase waits for registration, then API readiness on `127.0.0.1:8080`, then configures the origin and reports `CONTINUE`.

| Container | Image | User | Listens on | Notes |
| --- | --- | --- | --- | --- |
| `valkey` | `valkey/valkey@sha256:16625369f78a3844287f298799bebb7f4e59d0f7f40e789779d60e890f3d4399` (the `8.1.9-alpine` linux/amd64 manifest) | `999:1000` | `127.0.0.1:6379` only | `--bind 127.0.0.1 --protected-mode yes --save '' --appendonly no`; health check `valkey-cli -h 127.0.0.1 -p 6379 ping` |
| `api` | `<ecr repository>:868efcc04316de89e73174c48d42619cd4466a14` | `10001:10001` | `127.0.0.1:8080` only | starts after `valkey` is `HEALTHY`; `SERVER_ADDRESS=127.0.0.1`, `JAVA_TOOL_OPTIONS=-Djava.net.preferIPv4Stack=true`, `REDIS_HOST=127.0.0.1` |

- Both containers are essential, unprivileged, run with `no-new-privileges`, and log to the log group with the `awslogs` driver through the execution role (`ECS_ENABLE_AWSLOGS_EXECUTIONROLE_OVERRIDE=true`, Phase 6C-4b).
- The Valkey user comes from the image itself: its `/etc/passwd` reads `valkey:x:999:1000` (linux/amd64 manifest `sha256:16625369f78a3844287f298799bebb7f4e59d0f7f40e789779d60e890f3d4399`). The task definition pins that digest rather than the tag, because a tag is only resolved when the first task starts, which with the group at desired 0 is long after the apply. Neither user is 0, so the IMDS guard rejects both.
- The API's non-secret environment is the standalone host's, derived from the same resources `runtime_parameters.tf` uses. `DB_PASSWORD` and `APP_AUTH_JWT_SECRET` are ECS `secrets` that name the parameter ARNs; no secret value is in the task definition or the state.
- The API image is the On-Demand host's last-known-good release, pinned as a constant (a full Git SHA in the `IMMUTABLE` repository): Flyway migrates the shared RDS at startup, so a Spot task must run the same release.

### Expected plan delta when this is applied

`7 to add, 0 to change, 0 to destroy`: the seven resources above. With the Auto Scaling group at desired 0 the service places no task and no instance starts. Anything else is a blocker.

## Phase 6C-5b-1 EIP association ownership

Applied on 2026-10-01: the apply removed only the state entry (`0 added, 0 changed, 0 destroyed`). The live association, the EIP, Route 53 and CloudFront were unchanged, and the convergence plan reports `No changes`. Terraform stops owning the EIP association. The address itself and the DNS record that points at it stay managed.

| Address | After this change |
| --- | --- |
| `aws_eip.ec2_origin` | still managed: the allocation, its tags and its public IP |
| `aws_route53_record.origin_demo` | still managed: the `A` record to `aws_eip.ec2_origin.public_ip` |
| `aws_instance.demo` | still managed, unchanged |
| `aws_eip_association.ec2_origin` | `removed` with `destroy = false`: dropped from state only |

Phase 6C-5b moves the EIP between the On-Demand host and a validated Spot host as a reviewed operator step. While the association was in state, the first plan after such a move would propose re-attaching the EIP to the On-Demand host. `ignore_changes` cannot prevent that: the association ID changes, the read returns not found, and the resource is created again. `terraform state rm` would do the same as the `removed` block, but as an unreviewed manual step.

The apply makes no association call: no `DisassociateAddress` and no `AssociateAddress`. The live association (EIP to the On-Demand host) stays as it is until the separately approved cutover. From then on Terraform does not restore the association if it goes missing; putting the EIP back is part of the cutover runbook, not of a plan.

### Expected plan delta when this is applied

```
  # aws_eip_association.ec2_origin will no longer be managed by Terraform, but will not be destroyed
  # (destroy = false is set in the configuration)

Plan: 0 to add, 0 to change, 0 to destroy.
```

- In `terraform show -json` of the saved plan, `resource_changes` has exactly one entry that is not `no-op`: `aws_eip_association.ec2_origin` with `actions = ["forget"]`. Every other resource, in particular `aws_eip.ec2_origin`, `aws_instance.demo`, `aws_route53_record.origin_demo` and the CloudFront distributions, is `no-op`, and there is no output change.
- There is exactly one warning, with exactly this address:

  ```
  Warning: Some objects will no longer be managed by Terraform

  If you apply this plan, Terraform will discard its tracking information for the following objects, but it will not delete them:
   - aws_eip_association.ec2_origin
  ```

  Any other warning, or any other address in that list, is a blocker.
- In the `-json` UI stream of Terraform 1.16 the forget appears as a `planned_change` with `action` `remove` ("Plan to remove"). It is not counted in `change_summary`, whose `remove` counts destroys and must be `0`. A real destroy appears as `delete` and `1 to destroy`. Gate on the saved plan's `resource_changes` actions, not on the word "remove".
- A `delete` for the association means the `removed` block lost `destroy = false`. Stop.

After the apply the convergence plan reports `No changes` again. The `removed` block stays in the configuration and is a no-op from then on, with no warning.

### Drift after a cutover

Once the EIP is associated with a Spot host, a refresh shows the association-derived attributes of `aws_eip.ec2_origin` changing (`instance`, `association_id`, `network_interface`, `private_ip`, `private_dns`). The configuration sets none of them, so they are drift only, never a planned change. The convergence drift rule allows exactly these attributes for this one address; the exact list is confirmed at the first cutover. Any other change to `aws_eip.ec2_origin` (`domain`, `tags`, replacement, destroy) or any change to the Route 53 record is a blocker.

### Local validation without AWS credentials

```
terraform init -backend=false -input=false -lockfile=readonly
terraform fmt -check -recursive
terraform validate
```

## Phase 6C-5c-2 Spot origin EIP promotion

A Spot host launched from the new launch template version moves the origin Elastic IP to itself, once, after Auto Scaling has accepted its `CONTINUE`. Until now that move was an operator step (Phase 6C-5b). The bootstrap still never associates the address: the post phase only leaves a `continue-accepted` marker and queues `ec-portfolio-spot-eip-promotion.service`, which runs `promote-origin-eip.sh` from the same runtime bundle (see the runtime README).

| Address | Change |
| --- | --- |
| `aws_iam_role_policy.ecs_spot_origin_eip_promotion` | new inline policy `origin-eip-promotion` on the Spot host role |
| `aws_s3_object.spot_runtime_bundle` | new object version: the bundle carries `promote-origin-eip.sh` and its unit (13 files) |
| `aws_launch_template.ecs_spot` | new version: the loader passes `EIP_ALLOCATION_ID` (`aws_eip.ec2_origin.allocation_id`) and pins the new bundle |
| `aws_autoscaling_group.ecs_spot` | `launch_template.version` moves to the new version; capacity is unchanged |

`origin-eip-promotion`:

| Sid | Action | Resource / condition |
| --- | --- | --- |
| `AssociateExactOriginEip` | `ec2:AssociateAddress` | `elastic-ip/<allocation of aws_eip.ec2_origin>` |
| `AssociateOriginEipToSpotHost` | `ec2:AssociateAddress` | `instance/*` with `ec2:InstanceMarketType = spot` and `ec2:InstanceProfile = ` the Spot host profile |
| `ReadOriginEipHolder` | `ec2:DescribeAddresses` | `*` (no resource-level permissions) |
| `ReadSpotGroupCapacity` | `autoscaling:DescribeAutoScalingGroups` | `*` (no resource-level permissions) |

- The same shape as the Apply permission set's `ECPortfolioOriginEipAssociation` for its Spot statement. The On-Demand host is `on-demand` and carries `ec-portfolio-demo-ec2`, so it is never a target; returning the address to it is the day-close's and the operator's job, not this role's.
- The current holder is not named. Reassociation needs no `ec2:DisassociateAddress`. Whether EC2 also authorizes the current holder on that path is not documented, so the promotion asks first with `associate-address --dry-run` and makes the real call only on `DryRunOperation`. An `UnauthorizedOperation` there ends the promotion with no association made, and the permission model is reviewed again; nothing is widened by reflex.
- Not granted: `ec2:DisassociateAddress`, a `network-interface` resource, any other address, any tag, profile or instance launch permission that would let a host widen the conditions.
- The promotion moves the address only while the group's desired capacity is at least 1 and this instance is `InService`, so a host that finishes after the night's scale-down does not take the address back. It never completes a lifecycle action, terminates or stops anything, or takes the ECS agent down: a failed promotion leaves a healthy host `InService` and the address with its current holder.

### Expected plan delta when this is applied

```
Plan: 1 to add, 3 to change, 0 to destroy.
```

- add: `aws_iam_role_policy.ecs_spot_origin_eip_promotion`.
- update in place: `aws_s3_object.spot_runtime_bundle` (`source_hash`, `version_id`), `aws_launch_template.ecs_spot` (`user_data`, `latest_version`), `aws_autoscaling_group.ecs_spot` (`launch_template[0].version` only).
- No change to `aws_eip.ec2_origin`, `aws_instance.demo`, `aws_route53_record.origin_demo`, the CloudFront distributions, the lifecycle hook or the group's `min_size`, `max_size` and `desired_capacity`. Any replace or destroy is a blocker.
- The Apply permission set already covers every call: `iam:PutRolePolicy` and `iam:GetRolePolicy` on the Spot role, the launch template version, the group update and the bundle object come from `ECPortfolioTerraformApplySpotFoundation`. The Plan permission set already reads the role's inline policies. No access root change is needed.

Apply only while the group is at desired 0 and no cutover is running. From then on every Spot launch promotes itself after `CONTINUE`; the operator-only mode of Phase 6C-5a and 6C-5b is gone for new launches. Returning to it is a revert of this change and an apply, which publishes a launch template version without `EIP_ALLOCATION_ID`; a host built from it installs no promotion unit.

### Verification at the first launch

The promotion's own dry run is the live verification of the Spot path of the role ("Spot path pending live verification" in the access README): the address moving to the new host after `InService` means EC2 answered `DryRunOperation` and the association was verified. On the host the outcome is in `/run/ec-portfolio-demo/`: `spot-eip-promoted`, or `spot-eip-promotion-failed` holding one reason word (for example `dry-run-unauthorized`). If the address does not move, the operator associates it as in Phase 6C-5b and the cause is investigated before the next launch.

## Local validation

Run static checks in the isolated code worktree without AWS credentials or runtime input files:

```shell
node --test functions/frontend-spa-rewrite.test.mjs
../../runtime/demo/deploy-frontends.test.sh
../../runtime/demo/publish-api-image.test.sh
terraform init -backend=false -input=false -lockfile=readonly
terraform fmt -check -recursive
terraform validate
```

Static validation does not require real DB, JWT, or either origin verification input. `db_master_password`, `auth_jwt_secret`, and `origin_verify_token` remain ephemeral and must use a protected non-logging input channel during a future approved operation. `cloudfront_origin_verify_token` uses the same existing token but is non-ephemeral: its retention in a saved plan and encrypted remote state is the accepted Phase 4C-2B boundary above. Never supply any of these values through committed tfvars, shell history, or logs; do not load Keychain secrets for static validation.

Static validation also does not require `alert_email`. A future approved plan/apply must supply it through an ignored runtime variable source or protected environment variable. Do not add a personal address to `terraform.tfvars.example` or commit it in any `.tfvars` file.

The existing public hosted zone ID must likewise be supplied only at runtime as `route53_public_hosted_zone_id`. Do not add the real ID to `terraform.tfvars.example`, documentation, outputs, logs, or the PR description.

`terraform plan` needs AWS credentials because it resolves AWS-managed data and the remote state. Phase 5E and Phase 5F-1 both use `ec-portfolio-plan`, the existing `demo/terraform.tfstate` backend/workspace, and the same protected runtime inputs. Both origin token variables must use the identical existing Keychain token. Do not rotate inputs, print secrets, create a saved plan, use `-target`/`-refresh=false`, change permissions, switch to the apply profile, or mutate state. Run `terraform plan -input=false -detailed-exitcode`. With Phase 5E applied and Phase 5F-1 still code only, the expected result is exit code `2` listing exactly the five Phase 5F-1 creates with zero delta on every existing resource; exit code `0` would mean the Phase 5F-1 configuration is missing. Once Phase 5F-1 is applied and converged, exit code `0` (`No changes`) becomes the expected result again. AccessDenied, any existing resource delta, replacement, destroy, or unexpected address requires immediate stop and a report. Static validation alone cannot prove a zero-drift plan.

## State and deployment gates

The main worktree's Demo partial S3 backend is initialized and remote state exists. Phase 1 network, Phase 3 runtime/guardrail resources, Phase 4A deployment-foundation resources, Phase 4C origin/API resources, Phase 5A frontend hosting resources, and the Phase 5E GitHub deployment identity are applied and converged. Phase 5B artifacts and Phase 5C runtime CORS are deployed. Main's ignored backend configuration, runtime metadata, recovery artifacts, and untracked `AGENTS.md` must not be modified. An approved isolated plan may read the existing backend configuration while initializing only its own worktree metadata; it must not create/select a different workspace or migrate state.

Before any future state-changing AWS operation, separately verify:

- Remote state location and bootstrap ownership
- Encryption at rest and in transit
- State locking and recovery procedure
- Least-privilege state access and auditability
- State backup, retention, and break-glass access

The independent [bootstrap root](../bootstrap/README.md) owns the S3 bucket and native lockfile strategy. `backend.hcl.example` documents the `demo/terraform.tfstate` runtime configuration without committing account-specific values.

Phase 5E's apply is complete and converged; its plan, exact OIDC trust, and object-only permissions were reviewed before it ran. In any later Terraform operation, all existing resources, especially the API and frontend CloudFront distributions, S3 bucket configuration, DNS/SSM/runtime IAM, EC2/EIP/network/SG, RDS, Scheduler/SNS/Alarm/Budget, Phase 4, and the Phase 5E identity resources, must remain `no-op`. Any change/replacement/destroy, unexpected address, or secret rotation requires stopping for Architecture review; never hide drift with a targeted or refresh-disabled plan.

Terraform apply, GitHub Environment configuration, and the first automated frontend deployment are complete for Phase 5E. Phase 5F-1 is code only: its Terraform apply, the `demo-backend` GitHub Environment, the first API image publication, and commit/push each still need explicit approval.
