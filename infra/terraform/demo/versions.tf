terraform {
  required_version = "~> 1.16.0"

  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.62.0"
    }

    # Pinned exactly, not to a range. This provider's output_sha256 is what the
    # launch template's loader demands of the bundle it downloads, and the tar
    # framing that hash covers is provider implementation rather than a
    # documented contract. A minor upgrade that changed the framing would move
    # the hash with no change to any reviewed file, silently producing a new
    # launch template version. Upgrades happen through a PR that changes this
    # value, for the same reason the AMI IDs are pinned in locals.tf.
    archive = {
      source  = "hashicorp/archive"
      version = "= 2.8.1"
    }
  }
}
