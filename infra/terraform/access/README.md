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
        "arn:aws:iam::<ACCOUNT_ID>:policy/ECPortfolioTerraformApplyPhase5F2a",
        "arn:aws:iam::<ACCOUNT_ID>:policy/ECPortfolioTerraformApplySpotFoundation",
        "arn:aws:iam::<ACCOUNT_ID>:policy/ECPortfolioTerraformApplyEcsApplication"
      ]
    },
    {
      "Sid": "OriginTlsPolicyVersionWrite",
      "Effect": "Allow",
      "Action": "iam:CreatePolicyVersion",
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:policy/ECPortfolioTerraformApplyOriginTls"
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
policy mutation other than `OriginTlsPolicyVersionWrite`
(`iam:CreatePolicy`, `iam:CreatePolicyVersion` on any other policy,
`iam:SetDefaultPolicyVersion`, `iam:DeletePolicyVersion`, `iam:DeletePolicy`,
`iam:TagPolicy`, `iam:UntagPolicy`), and any access to workload resources or to
the Demo state.

`CustomerManagedPolicyRead`: the Plan and Apply permission sets also carry
customer managed policies (5 and 12). They are read-only here so that their
content can be baselined and reviewed; the list is exactly the policies the two
permission sets reference, as the discovery records them. A new reference means
a new ARN in this statement, never a wildcard. The eleventh Apply policy,
`ECPortfolioTerraformApplySpotFoundation`, was listed here before it was
attached (see [Phase 6C-3 Spot foundation permissions](#phase-6c-3-spot-foundation-permissions)).
The twelfth, `ECPortfolioTerraformApplyEcsApplication`, follows the same rule:
the console update of this statement waits until the discovery shows the
attachment (see [Phase 6C-4 ECS application permissions](#phase-6c-4-ecs-application-permissions)).

`OriginTlsPolicyVersionWrite`: rotating the `X-Origin-Verify` token ends with
CloudFront sending the new token (step `OR4` in the runtime README). That needs
`cloudfront:UpdateDistribution` on the Demo API distribution, and the Apply
permission set has no such permission. The attempt stopped on that
AccessDenied without changing anything, while the origin already accepted both
tokens. The Apply inline policy has no room left and all ten of its customer
managed policy slots are taken, so the permission is added as a new version of
`ECPortfolioTerraformApplyOriginTls`. No Apply customer managed policy grants a
CloudFront action. That one already owns the Terraform changes on the API
origin side, and `X-Origin-Verify` is the origin protection between CloudFront
and that origin. The new version adds exactly one statement and leaves the
existing ones unchanged:

```json
{
  "Sid": "UpdateExactDemoApiDistribution",
  "Effect": "Allow",
  "Action": "cloudfront:UpdateDistribution",
  "Resource": "arn:aws:cloudfront::<ACCOUNT_ID>:distribution/<API_DISTRIBUTION_ID>"
}
```

- AccessAdmin creates that version with
  `iam:CreatePolicyVersion --set-as-default`, on this one policy ARN only.
- `iam:CreatePolicyVersion` alone can create a version and make it the default,
  so `iam:SetDefaultPolicyVersion` is not granted.
- The policy holds three versions. The new one makes four, and a roll-forward
  rollback would make five, the quota. `iam:DeletePolicyVersion` is therefore
  not granted yet; a later change that needs a sixth version needs it first.
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

It replaces `PreMigrationSnapshotPolicyVersionWrite`, which allowed the same
action on `ECPortfolioPreMigrationSnapshot` only for the DB phase (Phase B) of
the rotation. That policy's version 2 added `rds:ModifyDBInstance` on the exact
Demo DB instance ARN (`ModifyExactDemoDbInstance`), and that version stays in
effect. With the recovery complete, AccessAdmin keeps no write to that policy.

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
   `iam:ListPolicyVersions` on each of the 17 customer managed policies, and
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

## Phase 6C-3 Spot foundation permissions

Phase 6C-3 adds the ECS on EC2 Spot foundation to the Demo root: 24 resources
(ECS cluster and capacity provider, Spot launch template, Auto Scaling group and
lifecycle hook, host IAM role, instance profile and inline policies, runtime
artifacts bucket and bundle object). With the Auto Scaling group at desired 0,
the apply launches no instance.

| Permission set | Change | Where |
| --- | --- | --- |
| `ECPortfolioTerraformPlan` | 6 read-only statements for the post-apply convergence plan | `policy_plan_spot_foundation.tf`, applied by this root |
| `ECPortfolioTerraformApply` | new customer managed policy `ECPortfolioTerraformApplySpotFoundation`, attached as its eleventh | created and attached by an administrator from the document below; this root manages neither |

The Apply inline policy and its ten existing customer managed policies are not
changed. The applied IAM quota "Managed policies per role" was confirmed in the
Service Quotas console to be at least 11 before this change; the
`OriginTlsPolicyVersionWrite` note above predates that check.

Both documents were derived from the API calls AWS provider 6.62 makes for these
resources on create, read, update and delete, mapped to IAM actions through the
AWS service reference and the API references. None comes from resource names
alone. A provider upgrade, or new arguments on these resources (warm pool, load
balancers, object lock, `force_destroy`, a lifecycle hook role), needs the same
check again; a missing permission then fails closed with an AccessDenied.

### `ECPortfolioTerraformApplySpotFoundation`

Maintained by hand; this root does not manage it. The document below is the
reviewed source.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CreateDemoEcsCluster",
      "Effect": "Allow",
      "Action": [
        "ecs:CreateCluster"
      ],
      "Resource": "arn:aws:ecs:ap-northeast-1:<ACCOUNT_ID>:cluster/ec-portfolio-demo",
      "Condition": {
        "StringEquals": {
          "aws:RequestTag/Name": "ec-portfolio-demo",
          "aws:RequestTag/Project": "ec-portfolio",
          "aws:RequestTag/Environment": "demo"
        }
      }
    },
    {
      "Sid": "ManageExactDemoEcsCluster",
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeClusters",
        "ecs:UpdateCluster",
        "ecs:PutClusterCapacityProviders",
        "ecs:DeleteCluster",
        "ecs:TagResource",
        "ecs:UntagResource"
      ],
      "Resource": "arn:aws:ecs:ap-northeast-1:<ACCOUNT_ID>:cluster/ec-portfolio-demo"
    },
    {
      "Sid": "ManageExactEcsSpotCapacityProvider",
      "Effect": "Allow",
      "Action": [
        "ecs:CreateCapacityProvider",
        "ecs:DescribeCapacityProviders",
        "ecs:UpdateCapacityProvider",
        "ecs:DeleteCapacityProvider",
        "ecs:TagResource",
        "ecs:UntagResource"
      ],
      "Resource": "arn:aws:ecs:ap-northeast-1:<ACCOUNT_ID>:capacity-provider/ec-portfolio-demo-ecs-spot"
    },
    {
      "Sid": "DescribeAutoScaling",
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeLifecycleHooks",
        "autoscaling:DescribeScalingActivities"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ManageExactEcsSpotAutoScalingGroup",
      "Effect": "Allow",
      "Action": [
        "autoscaling:CreateAutoScalingGroup",
        "autoscaling:UpdateAutoScalingGroup",
        "autoscaling:DeleteAutoScalingGroup",
        "autoscaling:PutLifecycleHook",
        "autoscaling:DeleteLifecycleHook",
        "autoscaling:CreateOrUpdateTags",
        "autoscaling:DeleteTags"
      ],
      "Resource": "arn:aws:autoscaling:ap-northeast-1:<ACCOUNT_ID>:autoScalingGroup:*:autoScalingGroupName/ec-portfolio-demo-ecs-spot"
    },
    {
      "Sid": "CreateEcsSpotLaunchTemplate",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateLaunchTemplate"
      ],
      "Resource": "arn:aws:ec2:ap-northeast-1:<ACCOUNT_ID>:launch-template/*",
      "Condition": {
        "StringEquals": {
          "aws:RequestTag/Name": "ec-portfolio-demo-ecs-spot",
          "aws:RequestTag/Project": "ec-portfolio",
          "aws:RequestTag/Environment": "demo"
        }
      }
    },
    {
      "Sid": "ManageEcsSpotLaunchTemplate",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateLaunchTemplateVersion",
        "ec2:ModifyLaunchTemplate",
        "ec2:DeleteLaunchTemplate"
      ],
      "Resource": "arn:aws:ec2:ap-northeast-1:<ACCOUNT_ID>:launch-template/*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/Name": "ec-portfolio-demo-ecs-spot",
          "aws:ResourceTag/Project": "ec-portfolio"
        }
      }
    },
    {
      "Sid": "ManageExactEcsSpotRole",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:GetRole",
        "iam:UpdateRoleDescription",
        "iam:UpdateAssumeRolePolicy",
        "iam:DeleteRole",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "iam:PutRolePolicy",
        "iam:GetRolePolicy",
        "iam:DeleteRolePolicy"
      ],
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/ec-portfolio-demo-ecs-spot"
    },
    {
      "Sid": "ManageExactEcsSpotInstanceProfile",
      "Effect": "Allow",
      "Action": [
        "iam:CreateInstanceProfile",
        "iam:GetInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:DeleteInstanceProfile",
        "iam:TagInstanceProfile",
        "iam:UntagInstanceProfile"
      ],
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:instance-profile/ec-portfolio-demo-ecs-spot"
    },
    {
      "Sid": "PassEcsSpotRoleToEc2",
      "Effect": "Allow",
      "Action": [
        "iam:PassRole"
      ],
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/ec-portfolio-demo-ecs-spot",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ec2.amazonaws.com"
        }
      }
    },
    {
      "Sid": "ManageRuntimeArtifactsBucket",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket",
        "s3:TagResource",
        "s3:DeleteBucket",
        "s3:PutBucketTagging",
        "s3:PutBucketPolicy",
        "s3:DeleteBucketPolicy",
        "s3:PutBucketVersioning",
        "s3:PutEncryptionConfiguration",
        "s3:PutLifecycleConfiguration",
        "s3:PutBucketPublicAccessBlock",
        "s3:PutBucketOwnershipControls",
        "s3:ListBucketVersions",
        "s3:GetAccelerateConfiguration",
        "s3:GetBucketAcl",
        "s3:GetBucketCORS",
        "s3:GetBucketLogging",
        "s3:GetBucketObjectLockConfiguration",
        "s3:GetBucketOwnershipControls",
        "s3:GetBucketPolicy",
        "s3:GetBucketPublicAccessBlock",
        "s3:GetBucketRequestPayment",
        "s3:GetBucketTagging",
        "s3:GetBucketVersioning",
        "s3:GetBucketWebsite",
        "s3:GetEncryptionConfiguration",
        "s3:GetLifecycleConfiguration",
        "s3:GetReplicationConfiguration",
        "s3:ListBucket"
      ],
      "Resource": "arn:aws:s3:::ec-portfolio-demo-runtime-artifacts-*"
    },
    {
      "Sid": "ManageSpotRuntimeBundleObject",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:PutObjectTagging",
        "s3:GetObject",
        "s3:GetObjectTagging",
        "s3:DeleteObject",
        "s3:DeleteObjectVersion"
      ],
      "Resource": "arn:aws:s3:::ec-portfolio-demo-runtime-artifacts-*/runtime/spot-runtime.tar.gz"
    }
  ]
}
```

`scripts/policy-gate.sh canonical` of this block as written (placeholder
included): `5b6249a24c950a17829a9d7fd7328a8679157a9908b3ef5763945bcbe16d880a`.
12 statements, 80 actions, 4,366 of the 6,144 non-whitespace characters a
managed policy allows.

- **Exact ARNs.** The cluster, the capacity provider, the role and the instance
  profile. `ecs:CreateCluster` additionally requires the `Name`, `Project` and
  `Environment` request tags.
- **`Resource "*"`.** Only `DescribeAutoScaling`: the service reference lists
  no resource type for `autoscaling:DescribeAutoScalingGroups`,
  `DescribeLifecycleHooks` and `DescribeScalingActivities`.
- **Patterns.** Only where AWS or Terraform assigns part of the name:
  - the Auto Scaling group ID (the group name is fixed);
  - the launch template ID (create is request-tag conditioned, changes are
    resource-tag conditioned);
  - the bucket suffix that `bucket_prefix` appends.
- **`iam:PassRole`.** Only the host role, and only to `ec2.amazonaws.com`.
  `iam:PassedToService` names the final service that assumes the role, which
  covers the launch template, the Auto Scaling launch check and the instance
  profile.
- **Reused, not repeated.** The existing inline statement `Ec2DemoApply`
  already allows the following in the Demo region; narrowing it means moving
  the needed actions here:
  - `ec2:Describe*`;
  - `ec2:CreateTags` and `ec2:DeleteTags`;
  - `ec2:RunInstances`. Auto Scaling checks the caller's `ec2:RunInstances` and
    `iam:PassRole` with a RunInstances dry run on `CreateAutoScalingGroup` and
    `UpdateAutoScalingGroup`.
- **Bucket tags.** `s3:TagResource` is granted because `CreateBucket` with tags
  requires it (the provider always sends them). Tag reads and tag updates try
  `s3:ListTagsForResource` and `s3:UntagResource` first. When those are denied,
  the provider falls back to `s3:GetBucketTagging` and `s3:PutBucketTagging`,
  the same path the existing buckets take.
- **Deliberately absent:**
  - `iam:CreateServiceLinkedRole`;
  - `ec2:RunInstances` or `ec2:TerminateInstances` of its own;
  - security group changes;
  - `s3:PutBucketAcl` (`CreateBucket` with the `private` ACL needs only
    `s3:CreateBucket`) and `s3:PutObjectAcl`;
  - object lock and governance bypass;
  - every action on existing Demo resources (the On-Demand host, RDS,
    CloudFront, Route 53, SSM parameters).

### Plan reads (`policy_plan_spot_foundation.tf`)

Only what the refresh of the new resources reads and the existing statements do
not already allow:
- ECS describe on the exact cluster and capacity provider;
- the two Auto Scaling describes;
- the policy lists of the host role;
- the bucket configuration reads;
- `s3:GetObject` and `s3:GetObjectTagging` on the one bundle key.

No write, tagging or permissions management action. The rendered Plan inline
policy grows from 31 to 37 statements and from 5,915 to 7,384 of the 10,240
non-whitespace characters. Every existing statement renders unchanged.

### Service-linked roles

Neither `AWSServiceRoleForAutoScaling` nor `AWSServiceRoleForECS` exists yet.
Auto Scaling creates its role on the first `CreateAutoScalingGroup`, and ECS
creates its role on the first cluster. Each uses the caller's
`iam:CreateServiceLinkedRole`, which Apply is not given. An administrator
creates them once, before the first Spot apply. For each pair
(`AWSServiceRoleForAutoScaling`, `autoscaling.amazonaws.com`) and
(`AWSServiceRoleForECS`, `ecs.amazonaws.com`):

1. `aws iam get-role --role-name <role>`.
   - It exists: check that `Path` is `/aws-service-role/<service>/` and that
     the trust principal is `<service>`, then skip it.
   - `NoSuchEntity`: continue to step 2.
   - Any other error: STOP; an error is never read as "absent".
2. `aws iam create-service-linked-role --aws-service-name <service>`, once.
   A repeated call is not assumed to succeed. After an error or an unclear
   outcome, go back to step 1 instead of calling it again.
3. `get-role` again with the step 1 checks. A `NoSuchEntity` right after a
   successful create is re-checked read-only, not created again.

ECS deletes `AWSServiceRoleForECS` when the last cluster in every Region is
deleted, so a later recreate starts again at step 1.

### Order after merge

Each step is approved separately; any AccessDenied or unexpected plan is a STOP.

1. Service-linked roles, as above.
2. An administrator renders the JSON above from merged `main`, checks its
   canonical SHA-256 against the one recorded here, fills `<ACCOUNT_ID>` and
   creates the policy. AccessAdmin has no `iam:CreatePolicy`.
3. The administrator attaches it to `ECPortfolioTerraformApply` as a customer
   managed policy reference in the Identity Center console and provisions. The
   Apply reserved role then carries 11 customer managed policies.
4. Discovery: Apply lists the 11 references and nothing else changed.
5. `ECPortfolioAccessAdmin` update from merged `main`, as in
   [Changing the `ECPortfolioAccessAdmin` policy](#changing-the-ecportfolioaccessadmin-policy),
   now with 16 customer managed policies.
6. This root: a plan that changes only
   `aws_ssoadmin_permission_set_inline_policy.plan` (6 statements added), then
   apply, convergence and a discovery.
7. The Demo root: the Phase 6C-3 plan and apply.

## Phase 6C-4 ECS application permissions

Phase 6C-4 adds the ECS application layer to the Demo root: 7 resources
(`aws_cloudwatch_log_group.ecs_api`, `aws_iam_role.ecs_task_execution` and its
three inline policies `aws_iam_role_policy.ecs_task_execution_ecr_pull`,
`aws_iam_role_policy.ecs_task_execution_runtime_secrets` and
`aws_iam_role_policy.ecs_task_execution_logs`, `aws_ecs_task_definition.api`
and `aws_ecs_service.api`). The service uses the DAEMON scheduling strategy
with launch type EC2, no load balancer, no task role and
`enable_execute_command = false`. Created while the Auto Scaling group is at
desired 0, it starts no task and no instance.

The names below are fixed by this change. The Demo root must use exactly these,
or its plan and apply fail with an AccessDenied.

| Resource | Name |
| --- | --- |
| Log group | `/ec-portfolio/demo/ecs/api` |
| Task execution role | `ec-portfolio-demo-ecs-task-execution` |
| Task definition family | `ec-portfolio-demo-api` |
| Service | `ec-portfolio-demo-api` in cluster `ec-portfolio-demo` |

| Permission set | Change | Where |
| --- | --- | --- |
| `ECPortfolioTerraformPlan` | 5 read-only statements for the post-apply convergence plan | `policy_plan_ecs_application.tf`, applied by this root |
| `ECPortfolioTerraformApply` | new customer managed policy `ECPortfolioTerraformApplyEcsApplication`, attached as its twelfth | created and attached by an administrator from the document below; this root manages neither |
| `ECPortfolioAccessAdmin` | `CustomerManagedPolicyRead` lists the new policy (16 → 17 ARNs) | the document above; no new write |

The Apply inline policy and its eleven existing customer managed policies are
not changed. The IAM quota "Managed policies per role" was confirmed in the
Service Quotas console on 2026-09-29 at an applied account-level value of 20,
so a twelfth policy fits.

Both documents were derived from the API calls AWS provider 6.62 makes for
these resources on create, read, update and delete, mapped to IAM actions
through the AWS service reference (v1.4) and the API references. None comes
from resource names alone. A provider upgrade, or new arguments on these
resources (`wait_for_steady_state`, load balancers, service connect, a task
role, `kms_key_id`, `deletion_protection_enabled`, `skip_destroy`), needs the
same check again; a missing permission then fails closed with an AccessDenied.

### `ECPortfolioTerraformApplyEcsApplication`

Maintained by hand; this root does not manage it. The document below is the
reviewed source.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ManageExactEcsApiLogGroup",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:PutRetentionPolicy",
        "logs:DeleteLogGroup",
        "logs:ListTagsForResource",
        "logs:TagResource",
        "logs:UntagResource"
      ],
      "Resource": [
        "arn:aws:logs:ap-northeast-1:<ACCOUNT_ID>:log-group:/ec-portfolio/demo/ecs/api",
        "arn:aws:logs:ap-northeast-1:<ACCOUNT_ID>:log-group:/ec-portfolio/demo/ecs/api:*"
      ]
    },
    {
      "Sid": "DescribeLogGroups",
      "Effect": "Allow",
      "Action": [
        "logs:DescribeLogGroups"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ManageExactEcsTaskExecutionRole",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:GetRole",
        "iam:UpdateRoleDescription",
        "iam:UpdateAssumeRolePolicy",
        "iam:DeleteRole",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "iam:PutRolePolicy",
        "iam:GetRolePolicy",
        "iam:DeleteRolePolicy"
      ],
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/ec-portfolio-demo-ecs-task-execution"
    },
    {
      "Sid": "PassEcsTaskExecutionRoleToEcsTasks",
      "Effect": "Allow",
      "Action": [
        "iam:PassRole"
      ],
      "Resource": "arn:aws:iam::<ACCOUNT_ID>:role/ec-portfolio-demo-ecs-task-execution",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "ecs-tasks.amazonaws.com"
        }
      }
    },
    {
      "Sid": "ManageDemoApiTaskDefinitionFamily",
      "Effect": "Allow",
      "Action": [
        "ecs:RegisterTaskDefinition",
        "ecs:TagResource",
        "ecs:UntagResource"
      ],
      "Resource": "arn:aws:ecs:ap-northeast-1:<ACCOUNT_ID>:task-definition/ec-portfolio-demo-api:*"
    },
    {
      "Sid": "DescribeTaskDefinitions",
      "Effect": "Allow",
      "Action": [
        "ecs:DescribeTaskDefinition"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DeregisterTaskDefinitions",
      "Effect": "Allow",
      "Action": [
        "ecs:DeregisterTaskDefinition"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ManageExactDemoApiService",
      "Effect": "Allow",
      "Action": [
        "ecs:CreateService",
        "ecs:DescribeServices",
        "ecs:UpdateService",
        "ecs:DeleteService",
        "ecs:TagResource",
        "ecs:UntagResource"
      ],
      "Resource": "arn:aws:ecs:ap-northeast-1:<ACCOUNT_ID>:service/ec-portfolio-demo/ec-portfolio-demo-api"
    }
  ]
}
```

`scripts/policy-gate.sh canonical` of this block as written (placeholder
included): `b2089da66621d1693e6a4ea7b53d4fb2181e98f1ab15abc5811ee432edc056ce`.
8 statements, 30 actions, 1,929 of the 6,144 non-whitespace characters a
managed policy allows. By the service reference access levels: write 12,
tagging 6, permissions management 3, read 4, list 5.

- **Exact ARNs.** The log group, the role and the service. The log group is
  named in both of its forms, `log-group:NAME` and `log-group:NAME:*`, because
  log group actions can be evaluated against either; the second form reaches
  only that group's own log streams.
- **Pattern.** Only the task definition: `task-definition/ec-portfolio-demo-api:*`.
  Every registration creates a new revision whose number AWS assigns; the
  family is fixed.
- **`Resource "*"`.** Only the three actions the service reference lists with
  no resource type:
  - `logs:DescribeLogGroups` (list) and `ecs:DescribeTaskDefinition` (read);
  - `ecs:DeregisterTaskDefinition` (write), the only write on `*`. Terraform
    calls it when a task definition revision is destroyed or replaced, and AWS
    offers no resource-level control for it. Setting `skip_destroy = true` on
    the task definition would remove the need for it, at the cost of leaving
    old revisions ACTIVE; that choice belongs to the Phase 6C-4 Demo change.
- **`iam:PassRole`.** Only the task execution role, and only to
  `ecs-tasks.amazonaws.com`. `RegisterTaskDefinition` passes it as
  `executionRoleArn`. `CreateService` and `UpdateService` also list
  `iam:PassRole` in the service reference; with no `role` and no load
  balancer, the only role this configuration can pass is the same one.
- **Tags on create.** `ecs:TagResource` for `RegisterTaskDefinition` and
  `CreateService`, `iam:TagRole` for `CreateRole`, and `logs:TagResource` for
  `CreateLogGroup`. The CreateLogGroup reference accepts either
  `logs:TagResource` or the legacy `logs:TagLogGroup`; only the former is
  granted.
- **No other condition.** `ecs:enable-execute-command` and `ecs:privileged`
  exist as condition keys, but how they evaluate when a request omits the
  field is not documented in a form this change can cite, and a wrong guess
  in a hand-maintained policy would deny a correct apply. No execute command,
  no privileged container and no root container are enforced by the Demo root
  in Phase 6C-4 instead.
- **Not reached, not granted** (provider source):
  - `ecs:ListServiceDeployments`, `ecs:DescribeServiceDeployments` and
    `ecs:StopServiceDeployment`: only with `wait_for_steady_state = true`;
  - `ecs:DeleteTaskDefinitions`: never called;
  - `ecs:ListTagsForResource` and `iam:ListRoleTags`: the reads return tags;
  - `iam:UpdateRole`: only for `max_session_duration` or a boundary;
  - `iam:RemoveRoleFromInstanceProfile`: the role has no instance profile;
  - `logs:DeleteRetentionPolicy`, `logs:PutLogGroupDeletionProtection`,
    `logs:AssociateKmsKey` and `logs:DisassociateKmsKey`: those arguments are
    not set.
- **Deliberately absent:**
  - `iam:CreateServiceLinkedRole`. `AWSServiceRoleForECS` exists since
    2026-09-28 (Phase 6C-3), and `CreateService` uses it;
  - `ecs:RunTask`, `ecs:StartTask` and `ecs:ExecuteCommand`;
  - every cluster, capacity provider and container instance write;
  - every Auto Scaling, EC2, security group, network, CloudFront, RDS,
    Route 53, SSM, KMS and ECR write.
- **Reused, not repeated.** Nothing: no statement of the Apply inline policy or
  of the other eleven policies covers these resources. The Spot foundation
  policy's ECS statements stop at the cluster and the capacity provider.

### Plan reads (`policy_plan_ecs_application.tf`)

Only what the refresh of the new resources reads and the existing statements
do not already allow:
- `ecs:DescribeTaskDefinition` on `*` (no resource type);
- `ecs:DescribeServices` on the exact service;
- `logs:DescribeLogGroups` on `*` (no resource type);
- `logs:ListTagsForResource` on the exact log group. The log group read sets no
  tags, so the tag interceptor lists them;
- `iam:ListRolePolicies` and `iam:ListAttachedRolePolicies` on the task
  execution role. `iam:GetRole` and `iam:GetRolePolicy` are already allowed on
  `*` by the baseline.

No write, tagging or permissions management action, by the service reference
access levels. Rendered offline with the provider, the Plan inline policy grows
from 37 to 42 statements and from 7,384 to 8,251 of the 10,240 non-whitespace
characters; every existing statement renders unchanged. The canonical SHA-256
of the addition is `adcae7ca88333f5402c81c03805ec8616da5388ba74a67a4503991b63ba3f925`.

### Task execution role (Demo root, Phase 6C-4)

Not an access-root document. These are the runtime permissions of
`aws_iam_role.ecs_task_execution`, which the Demo root writes as its three
inline policies. They are reviewed here so that the Terraform identity above
and the identity the ECS agent uses at run time are not confused.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "GetEcrAuthorizationToken",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken"
      ],
      "Resource": "*"
    },
    {
      "Sid": "PullDemoApiImage",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage"
      ],
      "Resource": "arn:aws:ecr:ap-northeast-1:<ACCOUNT_ID>:repository/ec-portfolio-demo-api"
    },
    {
      "Sid": "ReadApiRuntimeSecrets",
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameters"
      ],
      "Resource": [
        "arn:aws:ssm:ap-northeast-1:<ACCOUNT_ID>:parameter/ec-portfolio/demo/db/master-password",
        "arn:aws:ssm:ap-northeast-1:<ACCOUNT_ID>:parameter/ec-portfolio/demo/app/auth-jwt-secret"
      ]
    },
    {
      "Sid": "WriteApiTaskLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ],
      "Resource": "arn:aws:logs:ap-northeast-1:<ACCOUNT_ID>:log-group:/ec-portfolio/demo/ecs/api:log-stream:*"
    }
  ]
}
```

Canonical `77dcb0cccd66dd1b32d4c59bd4a8ebbc1752c957f7b7f90c758aa2bcb9da3374`,
4 statements, 7 actions.

- `ecr:GetAuthorizationToken` has no resource type; the pull actions are on
  the one repository.
- `ssm:GetParameters`, the action the ECS agent calls, on the database password
  and the JWT secret only. No `kms:Decrypt`: both parameters use the AWS
  managed key `alias/aws/ssm`, and the ECS guide requires `kms:Decrypt` only
  for a customer managed key. The On-Demand host already reads the same two
  parameters with no KMS permission.
- `logs:CreateLogStream` and `logs:PutLogEvents` on the log group's streams
  only.
- Trust: `ecs-tasks.amazonaws.com`. No task role: the API makes no AWS call.
- Prerequisite for the Phase 6C-4 Demo change, found during this review: the
  ECS guide requires `ECS_ENABLE_AWSLOGS_EXECUTIONROLE_OVERRIDE=true` in the
  agent configuration for tasks on the EC2 launch type to use Parameter Store
  secrets. `bootstrap-spot-host.sh` writes it into `/etc/ecs/ecs.config`
  (Phase 6C-4 bootstrap prerequisite).

### Order after merge

Each step is approved separately; any AccessDenied or unexpected plan is a STOP.

1. An administrator renders the JSON above from merged `main`, checks its
   canonical SHA-256 against the one recorded here, fills `<ACCOUNT_ID>` and
   creates the policy. AccessAdmin has no `iam:CreatePolicy`.
2. The administrator attaches it to `ECPortfolioTerraformApply` as a customer
   managed policy reference in the Identity Center console and provisions. The
   Apply reserved role then carries 12 customer managed policies.
3. Discovery: Apply lists the 12 references and nothing else changed.
4. `ECPortfolioAccessAdmin` update from merged `main`, as in
   [Changing the `ECPortfolioAccessAdmin` policy](#changing-the-ecportfolioaccessadmin-policy),
   now with 17 customer managed policies.
5. This root: a plan that changes only
   `aws_ssoadmin_permission_set_inline_policy.plan` (5 statements added), then
   apply, convergence and a discovery.
6. The Demo root: the Phase 6C-4 plan and apply.
