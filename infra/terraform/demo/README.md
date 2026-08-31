# Demo Terraform Network and Runtime

<!-- markdownlint-disable MD013 MD060 -->

This root module defines the Tokyo network foundation and the Phase 3A Demo runtime resources. The remote backend and Phase 1 network are already applied to AWS; the EC2, Elastic IP, IAM runtime identity, RDS, DB subnet group, and DB password parameter added in Phase 3A are code definitions only and have not been planned against or applied to AWS.

Do not apply the runtime resources when this change is merged. EventBridge Scheduler and AWS Budget guardrails must be merged first, followed by a combined cost/security plan review and explicit PO approval. This prevents an unscheduled EC2 or RDS from running continuously.

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

Automatic public IPv4 assignment is disabled. A future EC2 phase must explicitly attach the architecture-approved Elastic IP. The private DB route table has no Internet Gateway, NAT Gateway, or VPC endpoint route.

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

Each resource also receives an `ec-portfolio-demo-*` `Name` tag. `AutoStop = true` is set directly on the scheduled EC2 and RDS resources only. It is omitted from the VPC, subnets, Internet Gateway, route tables, routes, security groups, Elastic IP, DB subnet group, IAM resources, and SSM parameter because those resources cannot be safely stopped by the runtime schedule.

Removing `AutoStop` from provider default tags is expected to remove that tag from the existing foundation resources in place. Any future plan that proposes replacing the VPC, subnet, Internet Gateway, route, route table, or security group is a blocker and must not be applied. Never place credentials, secrets, personal data, or origin verification values in tags or variable files.

## EC2 runtime contract

- The host is x86_64 `t3a.medium` with Standard CPU credits. Do not reduce it to 2 GiB or switch to ARM64 before the architecture's memory/load and multi-platform image gates pass.
- The AMI is discovered from AWS's public SSM parameter `/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64`. It resolves to the current AWS-maintained Amazon Linux 2023 x86_64 AMI in Tokyo. A newer parameter value can cause a future replacement plan; review that replacement instead of hiding it with `ignore_changes`.
- The instance uses the existing public app subnet with automatic public IP assignment disabled and only the existing EC2 origin security group. A separately associated Elastic IP provides the stable future CloudFront origin address and continues to incur public IPv4 cost while EC2 is stopped.
- The encrypted root volume is 20 GiB gp3 with default IOPS/throughput and is deleted on instance termination. No additional data volume is defined.
- IMDSv2 tokens are required, the metadata endpoint is enabled, metadata tags are disabled, and the hop limit is `1`. Phase 3A containers do not need instance metadata. A future container AWS SDK requirement must justify a separately reviewed hop-limit change to `2`.
- No EC2 key pair, SSH ingress, runtime software, Docker, Nginx, Valkey, application container, origin TLS, origin secret, or ECR pull bootstrap is defined.

AWS-provided AL2023 AMIs normally include SSM Agent, so Phase 3A does not add network-fetched installation user data. Verify the agent is installed and running during the future launch gate. The dedicated instance role trusts only `ec2.amazonaws.com`. Its custom inline policy permits managed-node registration and Session Manager message channels only.

`AmazonSSMManagedInstanceCore` was reviewed but not attached: its current AWS-managed policy includes wildcard `ssm:GetParameter` and `ssm:GetParameters`, which would violate the explicit rule that this role cannot read the DB SecureString yet. The custom policy intentionally excludes Parameter Store, KMS, Run Command, ECR, SQS, SES, application CloudWatch publishing, and S3 permissions. Each capability must be added later with its own resource-scoped review.

Sources: [AWS public AMI parameters](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/finding-an-ami-parameter-store.html), [AL2023 SSM Agent installation](https://docs.aws.amazon.com/systems-manager/latest/userguide/agent-install-al2.html), [Systems Manager instance permissions](https://docs.aws.amazon.com/systems-manager/latest/userguide/setup-instance-permissions.html), [AmazonSSMManagedInstanceCore policy JSON](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonSSMManagedInstanceCore.html), [Systems Manager security best practices](https://docs.aws.amazon.com/systems-manager/latest/userguide/security-best-practices.html)

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

The SecureString uses the AWS-managed `alias/aws/ssm` key. No secret value is accepted through a committed tfvars file, backend configuration, resource tag, output, or ordinary `password`/`value` argument. Supply it only through an approved ephemeral execution channel that does not log the value. Rotation requires a new secret and an incremented version in the same reviewed operation. If either RDS or SSM update fails, retain the same secret/version securely and retry to convergence rather than incrementing again.

The EC2 role cannot read this parameter yet. A future deployment design may add `ssm:GetParameter` and required decrypt access scoped to this single parameter/key; wildcard Parameter Store or KMS decrypt permissions are prohibited.

Sources: [Terraform ephemeral variables](https://developer.hashicorp.com/terraform/language/block/variable#ephemeral), [Terraform write-only arguments](https://developer.hashicorp.com/terraform/language/manage-sensitive-data/write-only), [Terraform `aws_ssm_parameter`](https://registry.terraform.io/providers/hashicorp/aws/6.62.0/docs/resources/ssm_parameter)

## Local validation

Copy the example only when preparing a reviewed environment:

```shell
cp terraform.tfvars.example terraform.tfvars
terraform init -backend=false
terraform fmt -check
terraform validate
```

Static validation does not require a real DB password value. A future approved plan/apply must inject `db_master_password` through a non-logging ephemeral channel and must not write it to `terraform.tfvars`, a saved plan, shell history, or logs.

`terraform plan` needs AWS credentials because it resolves AWS-managed data and the remote state. Do not force a credentialed plan as part of Phase 3A static validation, and do not run `terraform apply` in this phase.

## State and deployment gates

The Demo partial S3 backend is initialized and remote state exists. The Phase 1 VPC, public app subnet, two private DB subnets, Internet Gateway, routing, and EC2/RDS security groups are already applied; the last approved live plan reported no changes before Phase 3A code was added.

Before any Runtime AWS apply, separately verify:

- Remote state location and bootstrap ownership
- Encryption at rest and in transit
- State locking and recovery procedure
- Least-privilege state access and auditability
- State backup, retention, and break-glass access

The independent [bootstrap root](../bootstrap/README.md) owns the S3 bucket and native lockfile strategy. `backend.hcl.example` documents the `demo/terraform.tfstate` runtime configuration without committing account-specific values.

Before the future combined Runtime/Scheduler/Budget plan or apply, verify the target-account AZ availability, CloudFront managed prefix-list ID and quota weight, AWS identity/region, cost estimate, write-only credential path, and absence of unexpected paid resources or foundation replacements. Runtime apply remains prohibited until Scheduler/Budget code is merged and Architecture/PO approves that exact combined plan.
