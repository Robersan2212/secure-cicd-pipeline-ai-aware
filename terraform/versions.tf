# Shared provider / backend bootstrap (Control 7: default_tags on every resource)

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }

  # Placeholder only — human fills bucket/key/region (and any locking) before real use.
  # Do not put credentials or live backend values here.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      project = var.project_name
    }
  }
}
