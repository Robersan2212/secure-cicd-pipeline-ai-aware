variable "aws_region" {
  description = "AWS region for all resources (e.g. <REGION>)."
  type        = string
}

variable "project_name" {
  description = "Stable project identifier applied via provider default_tags."
  type        = string
  default     = "secure-cicd-pipeline-ai-aware"
}

variable "github_org_repo" {
  description = "GitHub org/repo for OIDC trust, form <REPO_OWNER>/<REPO_NAME>."
  type        = string
}

variable "github_branch" {
  description = "Branch name allowed to assume the GitHub Actions role (no wildcards)."
  type        = string
}

variable "container_image" {
  description = "Container image URI for the agent task (e.g. <ECR_REPO_URI>:tag)."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR for the public subnet (NAT Gateway only)."
  type        = string
  default     = "10.0.0.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR for the private subnet (ECS task)."
  type        = string
  default     = "10.0.1.0/24"
}

variable "object_lock_retention_days" {
  description = "S3 Object Lock COMPLIANCE retention window in days."
  type        = number
  default     = 30
}

variable "log_retention_days" {
  description = "CloudWatch log group retention in days (must be set explicitly)."
  type        = number
  default     = 14
}

variable "tmpfs_size_mib" {
  description = "Size in MiB of the in-memory /tmp scratch space for the Fargate task."
  type        = number
  default     = 64
}
