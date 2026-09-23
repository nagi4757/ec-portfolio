# Phase 6B added the origin TLS backup bucket without granting the Plan
# permission set the reads its refresh needs, so every Demo plan since then
# fails on that bucket instead of reporting its real state.
#
# The action set is the one the Plan permission set holds on the store and admin
# buckets, measured against the live role. s3:GetBucketTagging is used rather
# than s3:ListTagsForResource: AWS provider 6.62 tries ListTagsForResource first
# and falls back to GetBucketTagging when it is denied, the path the store and
# admin buckets already take.
#
# Only the bucket is granted, never its objects: the bucket holds the archive of
# the origin TLS private key.
data "aws_iam_policy_document" "plan_origin_tls" {
  statement {
    sid    = "ReadExactOriginTlsBucket"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketPolicy",
      "s3:GetBucketAcl",
      "s3:GetBucketCORS",
      "s3:GetBucketWebsite",
      "s3:GetBucketVersioning",
      "s3:GetAccelerateConfiguration",
      "s3:GetBucketRequestPayment",
      "s3:GetBucketLogging",
      "s3:GetLifecycleConfiguration",
      "s3:GetReplicationConfiguration",
      "s3:GetEncryptionConfiguration",
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketOwnershipControls",
      "s3:GetBucketTagging",
      "s3:GetBucketLocation",
    ]
    resources = [
      # Output origin_tls_backup_bucket_name of the Demo root.
      "arn:aws:s3:::ec-portfolio-demo-origin-tls-776c2eab754b36a00164763604",
    ]
  }
}
