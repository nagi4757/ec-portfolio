# Phase 6C-3: immutable delivery of the Spot runtime bundle.
#
# A replacement Spot host has to receive bootstrap-spot-host.sh and the eleven
# artifacts it requires before it can build itself, and the launch template's
# user_data cannot carry them: the bootstrap alone is larger than the 16 KiB
# raw user-data limit. The bundle therefore lives in S3 and the launch template
# carries only a loader.
#
# This is deliberately a separate bucket from the origin TLS archive rather
# than another prefix inside it. The instance role holds s3:PutObject on that
# bucket so a host can write back a renewed certificate; runtime artifacts must
# be read-only to the same host. Keeping the two in one bucket would put a
# write grant and a read-only grant inside a single blast radius, and would
# also make the TLS bucket's noncurrent-version expiry apply to runtime
# bundles, which must not expire while any launch template version still
# references them.
#
# Identity is content, not a name. The object key is stable and the version ID
# is what the launch template pins, so publishing a new bundle never changes
# what an existing launch template version executes.

locals {
  # The eleven artifacts bootstrap-spot-host.sh requires, and the manifest it
  # checks them against. The bootstrap verifies that the manifest names each of
  # these exactly once before it runs sha256sum, because sha256sum --check only
  # validates the entries a manifest happens to list: a manifest that simply
  # omitted one would pass while that file was whatever the delivery left
  # behind. Generating the manifest from the same list keeps the two in step.
  #
  # The same names appear in REQUIRED_BUNDLE_ARTIFACTS in
  # bootstrap-spot-host.sh and in the loader's file-mode lists in
  # templates/ecs-spot-user-data.sh.tftpl. spot-runtime-bundle.test.sh fails
  # when the three disagree.
  #
  # Three are Phase 6C-4a: the container IMDS guard and its unit, and the
  # post-bootstrap unit that finishes the host after user data. The last two are
  # Phase 6C-5c-2: the origin Elastic IP promotion and its unit.
  spot_bundle_manifest_artifacts = [
    "sync-origin-tls.sh",
    "renew-origin-cert.sh",
    "configure-origin.sh",
    "origin-smoke-check-ecs.sh",
    "ec-portfolio-certbot-renew.service",
    "ec-portfolio-certbot-renew.timer",
    "imds-guard.sh",
    "ec-portfolio-imds-guard.service",
    "ec-portfolio-spot-post-bootstrap.service",
    "promote-origin-eip.sh",
    "ec-portfolio-spot-eip-promotion.service",
  ]

  # bootstrap-spot-host.sh is not a required manifest entry -- it is the
  # consumer of the manifest, not something the manifest is expected to cover.
  # It is protected one level up instead: the archive SHA256 the launch
  # template pins covers the bootstrap, the manifest and all eleven artifacts
  # together, which is the anchor the manifest itself cannot provide.
  spot_bundle_files = concat(
    ["bootstrap-spot-host.sh"],
    local.spot_bundle_manifest_artifacts,
  )

  # sha256sum's own text-mode format: the digest, two spaces, the file name.
  # Written from filesha256 over the reviewed repository files, so the manifest
  # cannot describe anything other than what the archive carries.
  spot_bundle_manifest_content = join("", [
    for name in local.spot_bundle_manifest_artifacts :
    format("%s  %s\n", filesha256("${local.spot_runtime_source_directory}/${name}"), name)
  ])
}

# Exactly the thirteen files the bundle contract names, listed one by one rather
# than swept up from the runtime directory. That directory also holds the
# standalone host's scripts and every test suite; source_dir would ship all of
# them to a production host and would quietly grow the bundle whenever an
# unrelated file was added next to them.
data "archive_file" "spot_runtime_bundle" {
  type = "tar.gz"

  # .terraform/ is ignored by Git, so building the bundle never dirties the
  # working tree.
  output_path = "${path.module}/.terraform/ec-portfolio/spot-runtime.tar.gz"

  dynamic "source" {
    for_each = local.spot_bundle_files

    content {
      content  = file("${local.spot_runtime_source_directory}/${source.value}")
      filename = source.value
    }
  }

  source {
    content  = local.spot_bundle_manifest_content
    filename = local.spot_bundle_manifest_name
  }
}

resource "aws_s3_bucket" "runtime_artifacts" {
  bucket_prefix = "${local.name_prefix}-runtime-artifacts-"
  force_destroy = false

  tags = {
    Name = "${local.name_prefix}-runtime-artifacts"
  }
}

resource "aws_s3_bucket_public_access_block" "runtime_artifacts" {
  bucket                  = aws_s3_bucket.runtime_artifacts.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "runtime_artifacts" {
  bucket = aws_s3_bucket.runtime_artifacts.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "runtime_artifacts" {
  bucket = aws_s3_bucket.runtime_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# Versioning is not a backup here, it is the addressing scheme. The launch
# template pins a version ID, so every published bundle has to remain
# retrievable for as long as a launch template version references it.
resource "aws_s3_bucket_versioning" "runtime_artifacts" {
  bucket = aws_s3_bucket.runtime_artifacts.id

  versioning_configuration {
    status = "Enabled"
  }
}

# No noncurrent_version_expiration, deliberately. Expiring an old bundle would
# break every launch template version that still points at it, and the breakage
# would only surface at the next launch -- as an AccessDenied, because the
# instance role has no s3:ListBucket and S3 cannot return NoSuchVersion to a
# caller that cannot list. A bundle is about 26 KiB, so retaining the history
# costs nothing worth trading that for.
resource "aws_s3_bucket_lifecycle_configuration" "runtime_artifacts" {
  bucket     = aws_s3_bucket.runtime_artifacts.id
  depends_on = [aws_s3_bucket_versioning.runtime_artifacts]

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Only the transport rule, for the same reason the origin TLS bucket carries
# only this one: a blanket "deny every principal except the instance role"
# would also lock out Terraform and any operator holding legitimate
# administrative access, and recovering from that needs the root account.
# Access is narrowed on the identity side instead.
data "aws_iam_policy_document" "runtime_artifacts_bucket" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]

    resources = [
      aws_s3_bucket.runtime_artifacts.arn,
      "${aws_s3_bucket.runtime_artifacts.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "runtime_artifacts" {
  bucket = aws_s3_bucket.runtime_artifacts.id
  policy = data.aws_iam_policy_document.runtime_artifacts_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.runtime_artifacts]
}

# The dependency on versioning is load-bearing rather than cosmetic. An object
# written before versioning is enabled has the version ID "null", and the
# launch template would pin that string instead of a real version.
resource "aws_s3_object" "spot_runtime_bundle" {
  bucket = aws_s3_bucket.runtime_artifacts.id
  key    = local.spot_runtime_object_key

  source = data.archive_file.spot_runtime_bundle.output_path

  # The archive digest, not an ETag. An ETag is not a content hash for
  # multipart or encrypted objects, and this is the same value the launch
  # template pins, so a content change moves the object and the loader's
  # expected hash together by construction.
  source_hash = data.archive_file.spot_runtime_bundle.output_sha256

  content_type = "application/gzip"

  depends_on = [aws_s3_bucket_versioning.runtime_artifacts]

  tags = {
    Name = "${local.name_prefix}-spot-runtime-bundle"
  }
}
