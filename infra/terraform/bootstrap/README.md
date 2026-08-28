# Terraform Remote State Bootstrap

<!-- markdownlint-disable MD013 MD060 -->

This independent root module defines the dedicated S3 bucket that will store EC Portfolio Terraform state. Phase 2A is definition and static validation only: it does not connect credentials, query an AWS account, run a plan, create the bucket, or migrate state.

## Bootstrap exception

The state bucket cannot use itself as a backend before it exists. The bootstrap root therefore uses local state only for the first approved creation. This is a narrow exception, not the steady-state design. Local bootstrap state must be treated as sensitive, kept out of Git and logs, and migrated immediately after the bucket is created in Phase 2B.

The bootstrap root does not declare an active `backend "s3"` block yet. Adding that partial backend declaration and performing `terraform init -migrate-state` are explicit Phase 2B changes after the bucket exists.

## Bucket contract

The deterministic bucket name is:

```text
ec-portfolio-terraform-state-<account-id>-ap-northeast-1
```

`aws_caller_identity` supplies the account ID only during a future credentialed plan/apply. No account ID, personal identifier, random provider, or credential is committed.

The bucket is separate from every application or media bucket and has these controls:

- S3 versioning enabled for state recovery
- Default SSE-S3 encryption with `AES256`
- `BucketOwnerEnforced` ownership; ACL-based operation is disabled
- All four S3 Public Access Block settings enabled
- Bucket policy denies all S3 actions when `aws:SecureTransport` is `false`
- No public Allow statement and no speculative future role ARN
- `force_destroy = false`
- `lifecycle.prevent_destroy = true`, intentionally limited to this critical state bucket
- No automatic current or noncurrent-version expiration

The `s3:*` action in the bucket policy is a Deny-only transport guard covering every possible insecure S3 operation. It is not an Allow permission or an access-control recommendation.

SSE-S3 avoids a customer-managed KMS key and its policy/cost surface for this Demo. A production environment can evaluate SSE-KMS when key separation, audit, or compliance requirements justify it.

S3 storage, requests, and retained object versions can incur small charges. The state bucket is expected to have low usage but is not assumed to be free. Version retention will be reviewed from measured growth rather than shortened preemptively.

## Native S3 locking

Terraform 1.16 S3 native locking is the target:

```hcl
use_lockfile = true
```

For a key such as `demo/terraform.tfstate`, Terraform uses both:

- `demo/terraform.tfstate`
- `demo/terraform.tfstate.tflock`

DynamoDB-based locking is deprecated and is not configured or provisioned. `terraform force-unlock` must not be used to bypass a healthy lock. It is break-glass recovery only after confirming that no active Terraform process owns the lock and recording operator approval.

Source: [Terraform S3 backend and native locking](https://developer.hashicorp.com/terraform/language/backend/s3)

## Future backend keys

After Phase 2B migration, the planned layout is:

| Root | State key | Lock object |
|---|---|---|
| Bootstrap | `bootstrap/terraform.tfstate` | `bootstrap/terraform.tfstate.tflock` |
| Demo | `demo/terraform.tfstate` | `demo/terraform.tfstate.tflock` |

Both use region `ap-northeast-1`, `use_lockfile = true`, and backend encryption. The committed `backend.hcl.example` files contain placeholders only and no credentials.

## Phase 2B migration draft

Phase 2B requires a new approval and follows this order:

1. Authenticate locally with approved temporary AWS SSO/IAM Identity Center credentials.
2. Copy `terraform.tfvars.example` and confirm identity, account, region, bucket name, and cost.
3. Run a credentialed bootstrap plan and retain only an approved human-readable review artifact outside Git.
4. Obtain PO approval for the exact plan.
5. Apply the bootstrap root once, creating only the reviewed state bucket controls.
6. Verify versioning, encryption, ownership, Public Access Block, HTTPS-only policy, and deletion protection.
7. Add the partial S3 backend declaration, render `backend.hcl` from the example, and migrate bootstrap local state with `terraform init -migrate-state -backend-config=backend.hcl`.
8. Verify the remote bootstrap state and `.tflock` behavior before securely removing the local state copy according to an approved recovery procedure.
9. Add the partial S3 backend declaration to the Demo root and initialize it with its distinct `demo/terraform.tfstate` key.
10. Design Local Infrastructure Admin and GitHub OIDC deploy roles separately; do not reuse long-lived credentials.

None of these migration or mutation steps are authorized in Phase 2A.

## Future least-privilege access

IAM resources are outside this phase. Future identity policies must be scoped to this exact bucket and the required key, not `s3:*`:

- Bucket: `s3:ListBucket`, restricted to the relevant `bootstrap/` or `demo/` prefix
- State object: `s3:GetObject` and `s3:PutObject` on the exact `*.tfstate` key
- Lock object: `s3:GetObject`, `s3:PutObject`, and `s3:DeleteObject` on the exact `*.tfstate.tflock` key
- No `s3:DeleteObject` permission on the state object

Local Infrastructure Admin and GitHub deploy roles will be designed separately. Local operators use approved temporary SSO credentials; GitHub Actions uses OIDC. Backend credentials must not be written in Terraform HCL, `backend.hcl`, variable files, plans, state, logs, or Git.

## Local static validation

Use Terraform 1.16 without AWS credentials:

```shell
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
```

`aws_caller_identity` requires credentials only for a plan or apply. Do not run a bootstrap plan merely to satisfy static validation, and do not run `terraform apply`, `terraform import`, `terraform state push`, or `terraform force-unlock` in Phase 2A.
