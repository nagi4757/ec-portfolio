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

Phase 2B requires a new approval. Its gate order is fixed:

1. **Temporary AWS authentication:** Use an approved local AWS SSO/IAM Identity Center session. Confirm identity, account and `ap-northeast-1`; do not place credentials in HCL or `backend.hcl`.
2. **Bootstrap plan:** Copy `terraform.tfvars.example`, run the credentialed Bootstrap plan and keep only an approved human-readable review artifact outside Git.
3. **PO approval:** Obtain explicit approval for the exact plan and initial local-state exception.
4. **Bootstrap apply:** Apply the Bootstrap root once, creating only the reviewed state bucket controls.
5. **S3 protection verification:** Verify every bucket protection below. A failed check blocks migration.
6. **Protected local-state backup:** Confirm the local state is readable, then create and record the recovery backup described below before changing the backend.
7. **Remote backend migration:** Add the reviewed partial `backend "s3"` declaration, render `backend.hcl` from the example and run `terraform init -migrate-state -backend-config=backend.hcl`. Do not use `terraform state push` as the normal migration mechanism.
8. **Remote state and lock verification:** Verify the S3 object/version, remote read, lineage, serial, resource identity and native lock acquire/release gates below. Do not delete any local artifact yet.
9. **Architecture/PO confirmation:** Present metadata-only verification results and obtain confirmation that S3 is the authoritative recovery source.
10. **Local working-state cleanup:** Only after confirmation, remove residual local working state according to the approved secure cleanup procedure.
11. **Temporary backup cleanup:** Securely delete the protected migration backup after the remote versioned state is accepted. Permanent duplicate local retention is not the default.

The Demo root follows the same backup, migration and verification gates later with its distinct `demo/terraform.tfstate` key. None of these migration or mutation steps are authorized in Phase 2A.

### S3 protection verification gate

Immediately after the approved Bootstrap apply and before local-state backup or migration, confirm through approved read-only inspection that:

- The expected bucket exists in the approved account and Tokyo region.
- Versioning reports `Enabled`.
- Default encryption reports SSE-S3 `AES256`.
- `block_public_acls`, `ignore_public_acls`, `block_public_policy` and `restrict_public_buckets` are all enabled.
- Object ownership is `BucketOwnerEnforced`.
- The bucket policy contains the `aws:SecureTransport = false` Deny and no public Allow.
- The applied bucket definition retains `force_destroy = false` and `prevent_destroy = true`; no unsafe destroy override is present.
- S3 public-access inspection reports that the bucket is not public.

If any protection is absent or cannot be verified, stop before migration and report it. Do not weaken a protection to make migration proceed.

### Protected pre-migration backup

Before `terraform init -migrate-state`:

1. Confirm the Bootstrap local state can be read with a read-only Terraform state command.
2. Set an owner-only `umask` and create a temporary directory outside the repository on an encrypted, access-controlled local volume.
3. Use `terraform state pull` to write an explicit pre-migration state backup into that directory. Redirect it directly to the protected file; never print or pipe the state through CI, terminal capture, chat, Slack or PR tooling.
4. Set the state backup and its metadata file to owner read/write only (`0600`) and the directory to owner access only (`0700`).
5. Record the backup SHA-256 checksum, lineage, serial, resource count and expected major resource addresses in the protected metadata file. Metadata review must not print attribute values or the full state.
6. Confirm the backup and metadata paths are outside Git and are not PR attachments, CI artifacts or uploads to unapproved general cloud storage.

This backup is a temporary break-glass artifact, not a Git artifact or ordinary team-share file. Its content must never appear in documentation, logs or example files.

### Remote state verification gate

After migration, preserve both the original local working state and protected backup until every check succeeds:

- Confirm `bootstrap/terraform.tfstate` exists, has a non-null S3 version ID and has a non-zero plausible object size. For Demo migration, perform the same checks on `demo/terraform.tfstate`.
- Confirm the bucket still reports versioning `Enabled`; the migrated state object must be a versioned object.
- Read the state through HTTPS and the approved IAM identity. Do not make the object public or download it through an unauthenticated URL.
- From a new Terraform process or clean working directory, initialize the reviewed backend configuration and successfully run `terraform state pull` plus `terraform state list` or an equivalent read-only state operation.
- Store the post-migration pull only in the same protected temporary directory, with owner-only permissions. Never print the full state.
- Compare metadata from the pre-migration backup and remote pull: lineage must be identical, serial must not unexpectedly decrease, resource count must match, and the expected major resource addresses/identities must be present. A pure backend migration must not create a new lineage.
- Compare checksums as an additional integrity signal. If serialization or expected metadata causes a checksum difference, do not treat that alone as proof of corruption; reconcile lineage, serial, resource identity and the exact reviewed migration behavior before approval.

An unexpected lineage, lower or unexplained serial, missing resource, zero-byte object or failed remote read blocks cleanup and all subsequent applies.

### Native lock verification gate

With `use_lockfile = true`, perform an approved non-applying Terraform operation that acquires a lock, such as a read-only plan. Verify that Terraform can create the corresponding `<state-key>.tflock`, that the operation completes normally and that the lock object is released afterward with no stale `.tflock` remaining.

In a controlled verification environment, a concurrent second operation may additionally confirm that lock contention blocks it. Do not use `terraform force-unlock` or manually delete the lock file as part of normal validation. Force-unlock is allowed only for a confirmed stale lock after proving no active owner remains and obtaining break-glass Architecture/PO approval.

### Failure and recovery stop condition

If any protection, migration, remote-read, lineage, serial, resource-identity or lock check fails:

- Stop without further apply, `terraform state push`, force-unlock or manual lock deletion.
- Preserve the original local state and protected backup; do not clean either artifact.
- Inspect S3 object versions and compare protected lineage/serial/resource metadata without logging state contents.
- Determine the cause and propose a recovery action.
- Perform recovery only after separate Architecture/PO approval.

An arbitrary `terraform state push` is not a standard repair. It requires a separately reviewed break-glass recovery plan because it can overwrite newer authoritative state.

## Future least-privilege access

IAM resources are outside this phase. Future identity policies must be scoped to this exact bucket and the required key, not `s3:*`:

- Bucket: `s3:ListBucket`, restricted to the relevant `bootstrap/` or `demo/` prefix
- State object: `s3:GetObject` and `s3:PutObject` on the exact `*.tfstate` key
- Lock object: `s3:GetObject`, `s3:PutObject`, and `s3:DeleteObject` on the exact `*.tfstate.tflock` key
- No `s3:DeleteObject` permission on the state object

Local Infrastructure Admin and GitHub deploy roles will be designed separately. Local operators use approved temporary SSO credentials; GitHub Actions uses OIDC. Backend credentials must not be written in Terraform HCL, `backend.hcl`, variable files, plans, state, logs, or Git.

## Sensitive values and state

Terraform `sensitive = true` and provider attributes marked sensitive reduce accidental disclosure by redacting values in normal CLI/UI output. They do **not** mean that the values are omitted from Terraform state or plan files. Anyone who can read those artifacts may be able to read the underlying values, and some explicit output modes can reveal sensitive outputs.

Future secret-related resources can therefore place database metadata, tokens or other sensitive attributes in state even when their display is masked. State confidentiality depends on the private dedicated bucket, encryption at rest and in transit, least-privilege IAM, Git/artifact exclusion and log exclusion. Where supported and architecturally appropriate, ephemeral values or provider write-only arguments can be evaluated separately to omit particular values, but `sensitive` alone is not a storage control.

Source: [Terraform sensitive data and state](https://developer.hashicorp.com/terraform/language/manage-sensitive-data)

## Local static validation

Use Terraform 1.16 without AWS credentials:

```shell
terraform fmt -check -recursive
terraform init -backend=false
terraform validate
```

`aws_caller_identity` requires credentials only for a plan or apply. Do not run a bootstrap plan merely to satisfy static validation, and do not run `terraform apply`, `terraform import`, `terraform state push`, or `terraform force-unlock` in Phase 2A.
