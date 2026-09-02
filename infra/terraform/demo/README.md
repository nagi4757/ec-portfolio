# Demo Terraform Network and Runtime

<!-- markdownlint-disable MD013 MD060 -->

This root module defines the Tokyo network foundation, Phase 3A Demo runtime, Phase 3B Scheduler/cost/failure guardrails, the Phase 4A deployment foundation, and the Phase 4C-2A origin foundation. Phases 1, 3A/3B, and 4A are applied to AWS, and the latest credentialed Terraform convergence check reported `No changes`. Phase 4A's ECR repository, JWT SecureString, and EC2 runtime deployment IAM policy are applied. All four schedules exist, the SNS subscription is confirmed, the Scheduler failure alarm is `OK`, alarm-to-SNS delivery is verified, and the tax-inclusive monthly Budget limit is `30.30 USD`.

The Scheduler stop path was verified on 2026-09-01: EC2 was `stopped` after its 17:00 JST invocation and RDS was `stopped` after 17:10. The start path was verified on 2026-09-02: RDS was `available` after 09:50 and EC2 was `running` after 10:00.

Phase 4C-2A is code only and is not applied. Its DNS/SSM/IAM resources require a separate credentialed plan, security/cost review, and explicit PO approval. Do not run that plan or apply as part of this change. Phase 4C-2A does not create CloudFront, issue a certificate, or configure Nginx.

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

Automatic public IPv4 assignment is disabled by `aws_subnet.public_app.map_public_ip_on_launch = false`, which is the source of truth. EC2 follows that subnet policy, while the explicit `aws_eip.ec2_origin` and `aws_eip_association.ec2_origin` resources provide the stable public origin address. The private DB route table has no Internet Gateway, NAT Gateway, or VPC endpoint route.

## Security-group contract

The EC2 origin security group allows only:

- Ingress TCP 443 from the AWS-managed `com.amazonaws.global.cloudfront.origin-facing` prefix list.
- Egress TCP 443 to IPv4 destinations for ECR, SSM, CloudWatch, AWS APIs, and approved HTTPS package repositories.
- Egress TCP 3306 to the RDS security group.

There is no SSH ingress and no public CIDR ingress to TCP 443. The CloudFront origin secret remains a later CloudFront/Nginx concern and is not represented by a security-group rule.

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
- The AMI is discovered from AWS's public SSM parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`. It resolves to the current AWS-maintained Amazon Linux 2023 x86_64 AMI in Tokyo. A newer parameter value can cause a future replacement plan; review that replacement instead of hiding it with `ignore_changes`.
- The instance follows the existing public app subnet's no-auto-public-IP policy and uses only the existing EC2 origin security group. A separately associated Elastic IP provides the stable future CloudFront origin address and continues to incur public IPv4 cost while EC2 is stopped. Do not duplicate the subnet policy with instance-level `associate_public_ip_address = false`: during partial-apply recovery, provider refresh after the explicit EIP association conflicted with the duplicate setting and proposed perpetual instance replacement.
- The encrypted root volume is 20 GiB gp3 with default IOPS/throughput and is deleted on instance termination. No additional data volume is defined.
- IMDSv2 tokens are required, the metadata endpoint is enabled, metadata tags are disabled, and the hop limit is `1`. Phase 3A containers do not need instance metadata. A future container AWS SDK requirement must justify a separately reviewed hop-limit change to `2`.
- No EC2 key pair, SSH ingress, runtime software, Docker, Nginx, Valkey, application container, origin TLS, origin-header enforcement, or ECR pull bootstrap is defined. Phase 4C-2A reserves the origin token in SSM and its exact read permission only; it does not consume the token on the host.

AWS-provided AL2023 AMIs normally include SSM Agent, so Phase 3A does not add network-fetched installation user data. Verify the agent is installed and running during the future launch gate. The dedicated instance role trusts only `ec2.amazonaws.com`. Its custom inline policy permits managed-node registration and Session Manager message channels only.

`AmazonSSMManagedInstanceCore` remains intentionally unattached because its wildcard Parameter Store reads are broader than this deployment contract. The existing custom Session Manager policy is unchanged. Phase 4A adds a separate inline runtime policy: only `ecr:GetAuthorizationToken` uses the API-required `Resource = "*"`; the three image-pull actions use the exact Demo API repository ARN, and `ssm:GetParameter` uses only the DB and JWT SecureString ARNs. It grants no ECR push, Parameter Store path/list, Run Command, KMS, S3, Secrets Manager, SQS, SES, or application CloudWatch permissions.

Both SecureStrings use the default AWS-managed `alias/aws/ssm` key. AWS documents that this key's `Decrypt` permission is available to all IAM principals in the account, so adding another broad `kms:Decrypt` statement would not narrow access and is omitted. Exact `ssm:GetParameter` resource permissions are the retrieval boundary for this role. A future customer-managed key would require a separately reviewed key policy and encryption-context-scoped decrypt permission.

Sources: [AWS public AMI parameters](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/finding-an-ami-parameter-store.html), [AL2023 SSM Agent installation](https://docs.aws.amazon.com/systems-manager/latest/userguide/agent-install-al2.html), [Systems Manager instance permissions](https://docs.aws.amazon.com/systems-manager/latest/userguide/setup-instance-permissions.html), [AmazonSSMManagedInstanceCore policy JSON](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonSSMManagedInstanceCore.html), [Parameter Store IAM and default-key permissions](https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-setting-up.html), [ECR IAM action/resource reference](https://docs.aws.amazon.com/service-authorization/latest/reference/list_ecr.html)

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

The lifecycle policy retains the ten newest tagged images for rollback and only the newest untagged image. Image expiration is asynchronous and count-based: it limits repository growth but does not guarantee a byte-size ceiling. The existing cost model reserves 1 GB, or `$0.10/month` before tax, for ECR. At the stress assumptions, each additional GB is approximately `$0.10 × ¥165/USD × 1.10 = ¥18.15` invoice-equivalent. Same-Region transfer from ECR to EC2 is currently `$0.00/GB`; storage beyond 1 GB consumes the existing variable contingency and must be reviewed before it threatens the ¥5,000 hard ceiling. Free Tier and credits are not assumed.

The Standard SecureString `/ec-portfolio/demo/app/auth-jwt-secret` follows the DB secret's write-only pattern: `auth_jwt_secret` is sensitive and ephemeral, `value_wo` prevents plaintext state storage, and `auth_jwt_secret_version` is the only persisted rotation input. A supplied secret must be at least 32 high-entropy characters. No secret value is committed, tagged, logged, or output; only the parameter name and ARN are non-secret outputs.

The runtime policy is for host-side deployment only. The EC2 host may authenticate to ECR, pull from the exact repository, and fetch the exact DB/JWT parameters with decryption. It must write runtime material to a root-controlled ephemeral location, pass only application values to the container, and remove temporary files after use. The Spring container must not receive AWS credentials or access Instance Metadata/AWS SDK; the IMDS hop limit remains `1`. Phase 4A adds no `user_data`, Docker, Nginx, application install, image push, image pull, or service restart behavior.

Sources: [ECR repository settings](https://registry.terraform.io/providers/hashicorp/aws/6.62.0/docs/resources/ecr_repository), [ECR lifecycle policy properties](https://docs.aws.amazon.com/AmazonECR/latest/userguide/lifecycle_policy_parameters.html), [ECR pricing](https://aws.amazon.com/ecr/pricing/), [Parameter Store SecureString encryption](https://docs.aws.amazon.com/systems-manager/latest/userguide/secure-string-parameter-kms-encryption.html)

## Phase 4C-2A origin foundation

The approved origin hostname is `origin-demo.yoonec.dev` in the existing public Route 53 zone for `yoonec.dev`. Terraform discovers that zone by exact DNS name with `private_zone = false`; a data-source postcondition then requires its ID to equal the runtime-only `route53_public_hosted_zone_id`. A missing zone, duplicate matching public zone, private-only zone, or wrong supplied ID fails the plan rather than selecting a different zone. The hosted zone ID is not hardcoded or output.

One TTL-60 `A` record maps the origin hostname to the existing `aws_eip.ec2_origin.public_ip`. No `AAAA` record, additional EIP, EC2 replacement, subnet change, or security-group change is defined. This prepares public DNS for the existing CloudFront-prefix-list-restricted origin; it does not make the EIP directly reachable from arbitrary Internet sources.

The Standard SecureString `/ec-portfolio/demo/origin/verify-token` reserves the future `X-Origin-Verify` defense-in-depth token. `origin_verify_token` is sensitive and ephemeral, accepts exactly 32-128 URL-safe `[A-Za-z0-9_-]` characters, and has no default. Together with the SSM resource's `value_wo`, this prevents the Phase 4C-2A root input and parameter plaintext from being persisted in saved plan or state artifacts; only `origin_verify_token_version` is persisted for rotation. No output exposes the value. Treat it as a defense-in-depth origin token layered on the managed prefix-list security-group restriction, not as a DB/JWT-equivalent credential or an authentication boundary. A future Phase 4C-2B CloudFront header binding and any resulting state exposure require a separate Architecture gate.

Two separate EC2 inline policies preserve reviewable least-privilege boundaries:

- `origin-verification-read` grants only `ssm:GetParameter` on the exact origin-token parameter ARN. It grants no Parameter Store path/list access and no explicit KMS permission.
- `acme-dns-route53` grants `route53:ChangeResourceRecordSets` only on the discovered public zone and only for `TXT`, normalized name `_acme-challenge.origin-demo.yoonec.dev`, and `UPSERT`/`DELETE`. Certbot's Route53 plugin uses `ListHostedZones` to discover the parent zone and `GetChange` to poll propagation; only `ListHostedZones` requires `Resource = "*"`, while `GetChange` is limited to the Route 53 change ARN pattern. The EC2 instance profile supplies short-lived role credentials; no access key or credential file is created.

The current AL2023.12 package catalog lists `certbot` and `python3-certbot-dns-route53` in the `2.6.0-4.amzn2023.0.1` package group with Full Support. Certbot upstream documents the three Route 53 API permissions, and its implementation uses `UPSERT` for challenge creation/update, `DELETE` for cleanup, `ListHostedZones` for discovery, and `GetChange` for polling. Before the later certificate operation, verify the package version actually resolved by the running AL2023 repository, install through a separately approved runtime procedure, and run a renewal dry-run. Package installation, Let's Encrypt account registration, certificate/private-key creation, renewal scheduling, Nginx TLS configuration, and CloudFront remain outside this phase.

The existing `yoonec.dev` Route 53 registrar charge is `$17/year`; it is an annual domain cost and is tracked separately from the steady monthly Demo resource subtotal. The existing hosted zone remains `$0.50/month` plus DNS query charges and is already represented by the `$0.54` monthly Route 53 allowance in the architecture cost table. This phase creates neither another hosted zone nor another fixed monthly service. Because the Budget is account-wide, the domain registration or renewal charge can trigger monthly thresholds in its billing month. That expected one-time/annual signal does not change the `30.30 USD` Budget contract.

Sources: [AL2023.12 package list](https://docs.aws.amazon.com/linux/al2023/release-notes/all-packages-AL2023.12.html), [Certbot Route53 plugin](https://certbot-dns-route53.readthedocs.io/en/stable/), [Certbot 2.6.0 Route53 implementation](https://github.com/certbot/certbot/blob/v2.6.0/certbot-dns-route53/certbot_dns_route53/_internal/dns_route53.py), [Route 53 record-level IAM conditions](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/specifying-conditions-route53.html), [Route 53 IAM actions and resources](https://docs.aws.amazon.com/service-authorization/latest/reference/list_route53.html), [Route 53 pricing](https://aws.amazon.com/route53/pricing/)

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

Phases 1, 3A/3B, and 4A are applied and Terraform has converged with `No changes`. Phase 4A includes the ECR repository, JWT SecureString, and EC2 runtime deployment IAM policy. The four schedules, confirmed SNS subscription, `OK` failure alarm, alarm-to-SNS path, and `30.30 USD` monthly Budget are verified.

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

The future Phase 4C-2A credentialed plan must report exactly `4 add / 0 change / 0 destroy` for this phase: one Route 53 `A` record, one SSM SecureString, and two EC2 inline IAM policies. Phase 4A must have zero create/change/replacement delta. Any Phase 4A delta, existing-resource change, replacement, or destroy is a blocker: stop and investigate backend/state selection, AWS identity, and live drift instead of applying.

## Local validation

Copy the example only when preparing a reviewed environment:

```shell
cp terraform.tfvars.example terraform.tfvars
terraform init -backend=false
terraform fmt -check
terraform validate
```

Static validation does not require real DB, JWT, or origin verification values. A future approved plan/apply must inject `db_master_password`, `auth_jwt_secret`, and `origin_verify_token` through a non-logging ephemeral channel and must not write them to `terraform.tfvars`, a saved plan, shell history, or logs. All three inputs are ephemeral in Phase 4C-2A. Any future CloudFront header binding requires a separate Architecture decision before changing that contract.

Static validation also does not require `alert_email`. A future approved plan/apply must supply it through an ignored runtime variable source or protected environment variable. Do not add a personal address to `terraform.tfvars.example` or commit it in any `.tfvars` file.

The existing public hosted zone ID must likewise be supplied only at runtime as `route53_public_hosted_zone_id`. Do not add the real ID to `terraform.tfvars.example`, documentation, outputs, logs, or the PR description.

`terraform plan` needs AWS credentials because it resolves AWS-managed data and the remote state. Do not run a credentialed plan or `terraform apply` as part of Phase 4C-2A code validation.

## State and deployment gates

The Demo partial S3 backend is initialized and remote state exists. Phase 1 network, Phase 3 runtime/guardrail resources, and Phase 4A deployment-foundation resources are applied; the latest approved credentialed convergence check reported `No changes`. Phase 4C-2A resources are not applied.

Before any future state-changing AWS operation, separately verify:

- Remote state location and bootstrap ownership
- Encryption at rest and in transit
- State locking and recovery procedure
- Least-privilege state access and auditability
- State backup, retention, and break-glass access

The independent [bootstrap root](../bootstrap/README.md) owns the S3 bucket and native lockfile strategy. `backend.hcl.example` documents the `demo/terraform.tfstate` runtime configuration without committing account-specific values.

Before a future Phase 4C-2A plan or apply, verify the exact public `yoonec.dev` hosted zone identity, the single `A` record to the existing EIP, absence of `AAAA`, ephemeral/write-only origin-token path, exact SSM/Route 53 IAM scopes, and no CloudFront, certificate, Nginx, compute, network, security, database, schedule, alert, or Budget change. The expected delta is exactly `4 add / 0 change / 0 destroy`. Phase 4A resources must have zero delta; otherwise stop and investigate backend/state selection, AWS identity, and drift. Apply remains prohibited until this code is merged and Architecture/PO approves that exact plan.
