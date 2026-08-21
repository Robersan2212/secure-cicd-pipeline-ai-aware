# Control 6 — Audit storage: genuinely immutable S3 Object Lock
# Plus Secrets Manager secret shell for the LLM API key (value set out of band)

resource "aws_s3_bucket" "audit" {
  # Control 6: object_lock_enabled must be set at creation — cannot be added later
  bucket_prefix       = "${var.project_name}-audit-"
  object_lock_enabled = true
  force_destroy       = false

  tags = {
    Name = "${var.project_name}-audit"
  }
}

resource "aws_s3_bucket_versioning" "audit" {
  # Control 6: versioning Enabled is a hard requirement for Object Lock
  bucket = aws_s3_bucket.audit.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "audit" {
  # Control 6: COMPLIANCE mode — not even the account root user can delete these
  # objects before the retention window expires. Objects in this bucket will
  # outlive a `terraform destroy` of everything else until that window ends.
  bucket = aws_s3_bucket.audit.id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.object_lock_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.audit]
}

resource "aws_s3_bucket_public_access_block" "audit" {
  # Control 6: all four public-access-block settings true
  bucket = aws_s3_bucket.audit.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_secretsmanager_secret" "llm_api_key" {
  # LLM API key material is set out of band — no secret value is stored in Terraform.
  # Generic naming so the human can point this at whichever LLM API they use.
  name_prefix             = "${var.project_name}-llm-api-key-"
  description             = "LLM API key for the CI/CD log-analysis agent (value set outside Terraform)"
  recovery_window_in_days = 7
}
