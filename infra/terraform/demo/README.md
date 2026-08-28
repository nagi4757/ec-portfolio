# Demo Terraform Network Foundation

<!-- markdownlint-disable MD013 MD060 -->

This root module implements Phase 1 of the approved Demo AWS architecture. It defines only the Tokyo network, routing, and security-group foundation. It does not create EC2, EBS, Elastic IP, RDS, CloudFront, NAT Gateway, VPC endpoints, or any application service.

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
- `AutoStop = true`

Each resource also receives an `ec-portfolio-demo-*` `Name` tag. Never place credentials, secrets, personal data, or origin verification values in tags or variable files.

## Local validation

Copy the example only when preparing a reviewed environment:

```shell
cp terraform.tfvars.example terraform.tfvars
terraform init -backend=false
terraform fmt -check
terraform validate
```

`terraform plan` needs AWS credentials because it resolves the AWS-managed CloudFront prefix list. Do not force a credentialed plan as part of static validation, and do not run `terraform apply` in this phase.

## State and deployment gates

The current implicit local backend is validation-only. Before any AWS apply, separately approve and implement:

- Remote state location and bootstrap ownership
- Encryption at rest and in transit
- State locking and recovery procedure
- Least-privilege state access and auditability
- State backup, retention, and break-glass access

An S3 backend is a likely option, but this phase does not choose or create a bucket, lock mechanism, or bootstrap workflow. Remote State Bootstrap is a separate Infra task.

Before plan/apply, also verify the target-account AZ availability, CloudFront managed prefix-list ID and quota weight, AWS identity/region, cost estimate, and the absence of unexpected paid resources.
