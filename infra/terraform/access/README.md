# Access Terraform root

This root owns the **inline policies** of the two IAM Identity Center permission
sets that run the Demo root: `ECPortfolioTerraformPlan` and
`ECPortfolioTerraformApply`. Its purpose is that those policies are changed
through reviewed code, never by hand in the console.

```
ECPortfolioAccessAdmin            manual, one-time console bootstrap
        |  runs
        v
infra/terraform/access            owns two inline policies, nothing else
        |  grants
        v
ECPortfolioTerraformPlan / ECPortfolioTerraformApply
        |  run
        v
infra/terraform/demo
```

Two rules keep the boundary: the Demo root never manages the permissions it runs
with, and this root never manages the permission set it runs as.

## Scope

| Managed here | Not managed here (stays in the Identity Center console) |
| --- | --- |
| `aws_ssoadmin_permission_set_inline_policy.plan` | The permission sets themselves: name, session duration, relay state, description, tags |
| `aws_ssoadmin_permission_set_inline_policy.apply` | AWS managed and customer managed policy attachments, permissions boundary |
| | Account assignments |
| | `ECPortfolioAccessAdmin` and every other permission set |

The permission sets are read with `data "aws_ssoadmin_permission_set"` by name.
A renamed or replaced permission set stops the plan instead of receiving a
policy meant for another one.

The inline policy resource owns the whole document. Whatever this root renders
replaces the live policy on apply, which is why adoption is gated on the
rendered document being semantically identical to the exported one.

## Who runs it

Only the `ECPortfolioAccessAdmin` permission set, through a local profile named
`ec-portfolio-access-admin`. `identity.tf` checks the caller before any Identity
Center read, so running this root as Plan, Apply or Bootstrap fails immediately.

Plan and Apply are never granted Identity Center, identity store or
Organizations actions; `policy_guardrails.tf` reports any such grant.

## Backend

The existing state bucket, with its own key and namespace:

| Setting | Value | Why |
| --- | --- | --- |
| `key` | `access/terraform.tfstate` | Separate from `demo/` and `bootstrap/` |
| `workspace_key_prefix` | `access/env:` | The S3 backend lists `<workspace_key_prefix>/` on every run. Keeping that prefix under `access/` lets the access-admin `s3:ListBucket` grant stay inside the access namespace |
| `use_lockfile` | `true` | Lock object `access/terraform.tfstate.tflock` |

Only the default workspace is used. Any other workspace would live under
`access/env:/`, where the access-admin has no object permission.

```sh
sed "s/ACCOUNT_ID/<account id>/" backend.hcl.example > backend.hcl   # backend.hcl is ignored by Git
```

## One-time manual bootstrap

Done once by an Identity Center administrator in the console. After it, Plan and
Apply policy changes need no console work.

1. **Collect values.**
   - IAM Identity Center > Settings: the instance ID (`ssoins-...`).
   - Organizations: whether this account is the management account. It is,
     which is why the policy carries `ManagementAccountInlinePolicyProvisioning`
     (see the note under the policy).
   - Permission sets: the IDs (`ps-...`) of `ECPortfolioTerraformPlan` and
     `ECPortfolioTerraformApply`.
   - IAM > Roles, search `AWSReservedSSO_ECPortfolioTerraform`: the Plan and
     Apply role names, needed by the discovery, and their ARNs (path included),
     needed by the policy.
   - The state bucket: `ec-portfolio-terraform-state-<account id>-ap-northeast-1`.
2. **Create the permission set.** Create permission set > Custom permission set.
   Inline policy: the document below with the seven placeholders replaced. No AWS
   managed policy, no customer managed policy, no permissions boundary. Name
   `ECPortfolioAccessAdmin`, session duration 1 hour, no relay state.
3. **Assign it.** AWS accounts > the Demo account > Assign users or groups: your
   own user only, permission set `ECPortfolioAccessAdmin`. Wait for provisioning
   to succeed.
4. **Add the local profile** (outside the repository):
   ```ini
   [profile ec-portfolio-access-admin]
   sso_session = ec-portfolio
   sso_account_id = <account id>
   sso_role_name = ECPortfolioAccessAdmin
   region = ap-northeast-1
   ```
5. **Verify (read-only).**
   ```sh
   aws sts get-caller-identity --profile ec-portfolio-access-admin            # AWSReservedSSO_ECPortfolioAccessAdmin_*
   aws sso-admin list-instances --profile ec-portfolio-access-admin           # succeeds
   aws s3api list-objects-v2 --bucket <state bucket> --prefix 'access/env:/' --max-keys 1 \
     --profile ec-portfolio-access-admin                                      # succeeds (empty)
   aws s3api list-objects-v2 --bucket <state bucket> --prefix 'demo/' --max-keys 1 \
     --profile ec-portfolio-access-admin                                      # must be AccessDenied
   ```
6. **Declare the freeze.** From the first discovery until the import has
   converged, nobody edits the Plan or Apply inline policy in the console.

### `ECPortfolioAccessAdmin` inline policy

Maintained by hand; this root does not manage it. Change it only by repeating
step 2.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SsoInstanceDiscovery",
      "Effect": "Allow",
      "Action": "sso:ListInstances",
      "Resource": "*"
    },
    {
      "Sid": "SsoPermissionSetLookup",
      "Effect": "Allow",
      "Action": ["sso:ListPermissionSets", "sso:DescribePermissionSet"],
      "Resource": [
        "arn:aws:sso:::instance/<INSTANCE_ID>",
        "arn:aws:sso:::permissionSet/<INSTANCE_ID>/*"
      ]
    },
    {
      "Sid": "SsoProvisioningStatusRead",
      "Effect": "Allow",
      "Action": [
        "sso:DescribePermissionSetProvisioningStatus",
        "sso:ListPermissionSetsProvisionedToAccount"
      ],
      "Resource": [
        "arn:aws:sso:::instance/<INSTANCE_ID>",
        "arn:aws:sso:::account/<ACCOUNT_ID>"
      ]
    },
    {
      "Sid": "SsoTargetPermissionSetRead",
      "Effect": "Allow",
      "Action": [
        "sso:GetInlinePolicyForPermissionSet",
        "sso:ListManagedPoliciesInPermissionSet",
        "sso:ListCustomerManagedPolicyReferencesInPermissionSet",
        "sso:GetPermissionsBoundaryForPermissionSet",
        "sso:ListTagsForResource",
        "sso:ListAccountsForProvisionedPermissionSet",
        "sso:ListAccountAssignments"
      ],
      "Resource": [
        "arn:aws:sso:::instance/<INSTANCE_ID>",
        "arn:aws:sso:::permissionSet/<INSTANCE_ID>/<PLAN_PS_ID>",
        "arn:aws:sso:::permissionSet/<INSTANCE_ID>/<APPLY_PS_ID>",
        "arn:aws:sso:::account/<ACCOUNT_ID>"
      ]
    },
    {
      "Sid": "SsoTargetInlinePolicyWrite",
      "Effect": "Allow",
      "Action": [
        "sso:PutInlinePolicyToPermissionSet",
        "sso:ProvisionPermissionSet"
      ],
      "Resource": [
        "arn:aws:sso:::instance/<INSTANCE_ID>",
        "arn:aws:sso:::permissionSet/<INSTANCE_ID>/<PLAN_PS_ID>",
        "arn:aws:sso:::permissionSet/<INSTANCE_ID>/<APPLY_PS_ID>",
        "arn:aws:sso:::account/<ACCOUNT_ID>"
      ]
    },
    {
      "Sid": "ProvisionedRoleDriftRead",
      "Effect": "Allow",
      "Action": [
        "iam:GetRole",
        "iam:ListRolePolicies",
        "iam:GetRolePolicy",
        "iam:ListAttachedRolePolicies"
      ],
      "Resource": [
        "arn:aws:iam::<ACCOUNT_ID>:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_ECPortfolioTerraformPlan_*",
        "arn:aws:iam::<ACCOUNT_ID>:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_ECPortfolioTerraformApply_*"
      ]
    },
    {
      "Sid": "ManagementAccountInlinePolicyProvisioning",
      "Effect": "Allow",
      "Action": "iam:PutRolePolicy",
      "Resource": [
        "<PLAN_RESERVED_ROLE_ARN>",
        "<APPLY_RESERVED_ROLE_ARN>"
      ]
    },
    {
      "Sid": "CustomerManagedPolicyRead",
      "Effect": "Allow",
      "Action": [
        "iam:GetPolicy",
        "iam:GetPolicyVersion",
        "iam:ListPolicyVersions"
      ],
      "Resource": [
        "arn:aws:iam::<ACCOUNT_ID>:policy/ECPortfolioTerraformPlanFrontendRead",
        "arn:aws:iam::<ACCOUNT_ID>:policy/ECPortfolioTerraformPlanGithubIamRead",
        "arn:aws:iam::<ACCOUNT_ID>:policy/ECPortfolioTerraformPlanPhase5F1Read",
        "arn:aws:iam::<ACCOUNT_ID>:policy/ECPortfolioTerraformPlanPhase5F2aRead",
        "arn:aws:iam::<ACCOUNT_ID>:policy/ECPortfolioTerraformPlanRuntimeInputRead",
        "arn:aws:iam::<ACCOUNT_ID>:policy/ECPortfolioDbPortForwarding",
        "arn:aws:iam::<ACCOUNT_ID>:policy/ECPortfolioEc2SessionAccess",
        "arn:aws:iam::<ACCOUNT_ID>:policy/ECPortfolioPhase5BFrontendDeploy",
        "arn:aws:iam::<ACCOUNT_ID>:policy/ECPortfolioPhase5CRuntimeDeploy",
        "arn:aws:iam::<ACCOUNT_ID>:policy/ECPortfolioPhase5EFrontendCICDApply",
        "arn:aws:iam::<ACCOUNT_ID>:policy/ECPortfolioPreMigrationSnapshot",
        "arn:aws:iam::<ACCOUNT_ID>:policy/ECPortfolioTerraformApplyEcrRead",
        "arn:aws:iam::<ACCOUNT_ID>:policy/ECPortfolioTerraformApplyOriginTls",
        "arn:aws:iam::<ACCOUNT_ID>:policy/ECPortfolioTerraformApplyPhase5F1",
        "arn:aws:iam::<ACCOUNT_ID>:policy/ECPortfolioTerraformApplyPhase5F2a"
      ]
    },
    {
      "Sid": "PreMigrationSnapshotPolicyVersionWrite",
      "Effect": "Allow",
      "Action": "iam:CreatePolicyVersion",
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:policy/ECPortfolioPreMigrationSnapshot"
    },
    {
      "Sid": "AccessStateBucketList",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::<STATE_BUCKET>",
      "Condition": {
        "StringEquals": {
          "s3:prefix": [
            "access/env:/",
            "access/terraform.tfstate",
            "access/terraform.tfstate.tflock"
          ]
        }
      }
    },
    {
      "Sid": "AccessStateObjects",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": "arn:aws:s3:::<STATE_BUCKET>/access/terraform.tfstate"
    },
    {
      "Sid": "AccessStateLock",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::<STATE_BUCKET>/access/terraform.tfstate.tflock"
    }
  ]
}
```

Deliberately absent: `sso:CreatePermissionSet`, `sso:DeletePermissionSet`,
`sso:UpdatePermissionSet`, `sso:TagResource`, `sso:UntagResource`,
`sso:DeleteInlinePolicyFromPermissionSet`, account assignment and policy
attachment actions, every `sso-directory`, `identitystore` and `organizations`
action, IAM role lifecycle actions (`iam:CreateRole`, `iam:DeleteRole`,
`iam:UpdateRole`, `iam:DeleteRolePolicy`, `iam:AttachRolePolicy`,
`iam:DetachRolePolicy`, trust policy and permissions boundary changes), IAM
policy mutation other than `PreMigrationSnapshotPolicyVersionWrite`
(`iam:CreatePolicy`, `iam:CreatePolicyVersion` on any other policy,
`iam:SetDefaultPolicyVersion`, `iam:DeletePolicyVersion`, `iam:DeletePolicy`,
`iam:TagPolicy`, `iam:UntagPolicy`), and any access to workload resources or to
the Demo state.

`CustomerManagedPolicyRead`: the Plan and Apply permission sets also carry
customer managed policies (5 and 10). They are read-only here so that their
content can be baselined and reviewed; the list is exactly the policies the two
permission sets reference, as the discovery records them. A new reference means
a new ARN in this statement, never a wildcard.

`PreMigrationSnapshotPolicyVersionWrite`: rotating the Demo DB master password
needs `rds:ModifyDBInstance` on the Demo RDS instance, and the Apply permission
set has no such permission. The DB phase of the secret rotation (Phase B)
stopped on that AccessDenied after the SSM parameter had already been updated,
and this change is how it is recovered. The Apply inline policy has no room
left and all ten of its customer managed policy slots are taken, so the
permission is added as a new version of `ECPortfolioPreMigrationSnapshot`.
That is the only Apply customer managed policy that grants RDS actions, and it
is already scoped to the exact Demo DB instance ARN. The new version adds
exactly one statement and leaves the existing ones unchanged:

```json
{
  "Sid": "ModifyExactDemoDbInstance",
  "Effect": "Allow",
  "Action": "rds:ModifyDBInstance",
  "Resource": "arn:aws:rds:ap-northeast-1:<ACCOUNT_ID>:db:ec-portfolio-demo-mariadb"
}
```

- AccessAdmin creates that version with
  `iam:CreatePolicyVersion --set-as-default`, on this one policy ARN only.
- `iam:CreatePolicyVersion` alone can create a version and make it the default,
  so `iam:SetDefaultPolicyVersion` is not granted.
- The policy has one version, so the quota of five is not in reach and
  `iam:DeletePolicyVersion` is not granted either.
- A rollback is a roll-forward: a new version carrying the previous document,
  created with `--set-as-default`. Pointing the default back at an existing
  version would need `iam:SetDefaultPolicyVersion`, which stays out until a
  change actually requires it.
- AccessAdmin can already rewrite the Apply inline policy, so this adds no new
  way to raise Apply's permissions. It is still limited to one ARN.

This statement cannot be verified read-only. The first `CreatePolicyVersion`
is its verification, followed by `iam:GetPolicy`, `iam:GetPolicyVersion` and
`iam:ListPolicyVersions` on the policy, and by a discovery to confirm that
nothing else changed.

`s3:prefix` values: `access/env:/` is the prefix the S3 backend actually lists
with. The two state keys are the rest of the access namespace. Whether a
prefix-conditioned `s3:ListBucket` also makes S3 answer 404 rather than 403 for
the not-yet-existing state object is not documented; gate G5 verifies it.

`ManagementAccountInlinePolicyProvisioning`: this account is the Organizations
management account. There, Identity Center performs the IAM operations of a
provisioning with the credentials of the caller instead of its service-linked
role, whose provisioning statement excludes the management account. Rewriting
the inline policy of an existing reserved role needs `iam:PutRolePolicy`; the
reads it needs come from `ProvisionedRoleDriftRead`. It is granted on the two
exact role ARNs only. Creating, deleting or re-shaping roles, attachments,
trust or boundaries is outside what this root does. A provisioning that fails
with `not authorized to perform: iam:<action>` is a STOP: the action is
reviewed, never added by reflex.

### Changing the `ECPortfolioAccessAdmin` policy

The document above is the source of truth; the console only ever receives a
rendering of it from merged `main`.

1. Merge the change to this document first.
2. Render the document from merged `main` with the placeholders filled, and
   compare the SHA-256 of the rendering with the one recorded in the change
   before pasting it. A rendering taken from an unmerged branch is not used.
3. In the console, replace the inline policy of `ECPortfolioAccessAdmin` with
   the rendering, and let Identity Center provision it.
4. Verify read-only, as `ec-portfolio-access-admin`: the step 5 checks of the
   bootstrap, the reserved role reads (`iam:GetRole`, `iam:ListRolePolicies`,
   `iam:GetRolePolicy`, `iam:ListAttachedRolePolicies`), `iam:GetPolicy` and
   `iam:ListPolicyVersions` on each of the 15 customer managed policies, and
   an AccessDenied from `iam:GetPolicy` on an AWS managed policy outside the
   list (for example `arn:aws:iam::aws:policy/ReadOnlyAccess`).
5. Run the discovery again; its baseline must equal the previous one.

## Discovery and baseline

```sh
AWS_PROFILE=ec-portfolio-access-admin \
PLAN_ROLE_NAME=<Plan reserved role name> \
APPLY_ROLE_NAME=<Apply reserved role name> \
OUT_DIR="$HOME/.ec-portfolio-access-baseline/$(date +%Y%m%dT%H%M%S)" \
scripts/discover-permission-sets.sh
```

Read-only; it stops at the first failure and never retries. It refuses to run
as anyone but `ECPortfolioAccessAdmin` and refuses an `OUT_DIR` inside a Git
work tree, because the export carries account and principal IDs. It writes:

- `<permission set>.inline-policy.json`: the inline policy exactly as Identity
  Center returns it.
- `baseline.txt`: raw and canonical SHA-256 of each policy, statement count,
  size, metadata, attachments, boundary, provisioned accounts, assignments and
  the reserved role comparison.

It stops if a provisioned role does not carry the current inline policy: an
earlier change was never provisioned, and adopting that state would hide it.

Two baselines are compared with:

```sh
diff <(grep -v '^discovered_at=' "$OLD/baseline.txt") <(grep -v '^discovered_at=' "$NEW/baseline.txt")
```

## Adoption gates

Every gate must pass before the next one starts. Plan files and baselines stay
outside the repository.

| Gate | Action | Pass condition |
| --- | --- | --- |
| G0 | One-time bootstrap | All four step 5 checks behave as listed |
| G1 | Discovery | Completes without STOP |
| G2 | Baseline | Digests recorded; the freeze starts |
| G3 | Reproduce | `policy_plan.tf` and `policy_apply.tf` rebuild each exported statement with `aws_iam_policy_document`, Sid for Sid |
| G4 | Static checks | `terraform fmt -check`, `terraform init -backend-config=backend.hcl`, `terraform validate` |
| G5 | First run on the empty key | `init` lists `access/env:/` and the first `plan` reads a missing `access/terraform.tfstate` as empty state |
| G6 | First plan | Saved plan; `scripts/policy-gate.sh verify-import-plan` passes; summary `Plan: 2 to import, 0 to add, 0 to change, 0 to destroy.` |
| G7 | Freeze re-check | A new discovery's baseline equals G2 |
| G8 | Import | Separate approval; `terraform apply <saved plan>` reports `2 imported, 0 added, 0 changed, 0 destroyed` |
| G9 | Convergence | `terraform plan -input=false -detailed-exitcode` exits 0 with `No changes.`; a new discovery's baseline equals G2 |
| G10 | Cleanup | A follow-up change removes `imports.tf`; the plan still exits 0 |

G6 in commands:

```sh
terraform plan -input=false -out="$PRIVATE_DIR/access-import.tfplan"
terraform show -json "$PRIVATE_DIR/access-import.tfplan" > "$PRIVATE_DIR/access-import.plan.json"
scripts/policy-gate.sh verify-import-plan "$PRIVATE_DIR/access-import.plan.json" \
  "aws_ssoadmin_permission_set_inline_policy.plan=$BASELINE_DIR/ECPortfolioTerraformPlan.inline-policy.json" \
  "aws_ssoadmin_permission_set_inline_policy.apply=$BASELINE_DIR/ECPortfolioTerraformApply.inline-policy.json"
```

`verify-import-plan` fails unless the plan imports exactly those two addresses,
changes no managed resource, and each rendered policy is semantically identical
to its export.

### STOP conditions

Stop and report the exact API and error; do not widen a permission, switch
profile or retry:

- any AccessDenied, including the G5 backend calls
  (`Unable to list objects ... with prefix "access/env:/"`,
  `Unable to access object "access/terraform.tfstate"`);
- a discovery STOP: no inline policy, provisioning drift, provisioning outside
  this account, wrong caller;
- a plan with any create, update, replace or delete, or a policy mismatch;
- a baseline that changed between G2 and G7 or G9.

## Rollback and break-glass

- **Before G8:** nothing to undo; the apply never ran.
- **Hand ownership back to the console** without touching AWS:
  ```hcl
  removed {
    from = aws_ssoadmin_permission_set_inline_policy.plan
    lifecycle {
      destroy = false
    }
  }
  ```
  (and the same for `.apply`), reviewed through a normal plan.
- **A bad policy change (after adoption):** revert the change and apply; the
  provider writes and provisions the previous document.
- **Provisioning failed after a write:** Identity Center then holds the new
  policy while the role still has the old one, and a plan shows no difference.
  Run `aws sso-admin provision-permission-set --target-type ALL_PROVISIONED_ACCOUNTS`
  as the access-admin and re-run the discovery to confirm the reserved role
  matches.
- **Break-glass:** an Identity Center administrator can always restore a policy
  in the console from the baseline export or from the rendered document of the
  last applied commit. The next plan of this root then shows the difference to
  reconcile.

## Guardrails

`policy_guardrails.tf` reports, as check blocks, an inline policy that exceeds
the Identity Center size limit (10,240 non-whitespace characters), allows a
whole service or `*`, combines Allow with NotAction, or grants an Identity
Center, identity store or Organizations action. They are warnings while existing
policies are adopted and become blocking preconditions after cleanup.

## Changing a policy after adoption

A Demo change that adds AWS resources changes the access policies in the same
development phase, in its own change applied first: Apply gets the mutations it
needs, and Plan gets the reads that the post-apply convergence plan will make.
An AccessDenied in a Demo plan is fixed here, never in the console.
