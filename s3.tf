################
#  sftp/s3.tf  #
################

module "s3" {
  source = "git::https://github.com/TechHoldingLLC/terraform-aws-s3-bucket.git?ref=v1.0.7"

  name          = "${var.name}-sftp"
  force_destroy = false

  versioning            = var.bucket_versioning ? "Enabled" : "Disabled"
  encryption_algorithm  = "AES256"
  bucket_key_enabled    = true
  block_http_request    = true
  create_lifecycle_rule = false
}

resource "aws_s3_bucket_public_access_block" "sftp_bucket" {
  bucket = module.s3.bucket_name

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "sftp_bucket" {
  bucket = module.s3.bucket_name

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "sftp_bucket" {
  bucket = module.s3.bucket_name

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_days
    }
  }

  # No-op unless bucket_versioning is true.
  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }
}
