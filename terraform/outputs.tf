output "github_actions_role_arn" {
  description = "IAM role ARN for GitHub Actions to assume via OIDC."
  value       = aws_iam_role.github_actions.arn
}

output "ecs_task_role_arn" {
  description = "IAM task role ARN used by the agent at runtime."
  value       = aws_iam_role.ecs_task.arn
}

output "ecs_execution_role_arn" {
  description = "IAM execution role ARN used by ECS to pull images and ship logs."
  value       = aws_iam_role.ecs_execution.arn
}

output "ecs_cluster_arn" {
  description = "ECS cluster ARN for RunTask."
  value       = aws_ecs_cluster.agent.arn
}

output "ecs_cluster_name" {
  description = "ECS cluster name for RunTask."
  value       = aws_ecs_cluster.agent.name
}

output "ecs_task_definition_arn" {
  description = "ECS task definition ARN (family revision)."
  value       = aws_ecs_task_definition.agent.arn
}

output "ecs_task_definition_family" {
  description = "ECS task definition family name for log-integrity."
  value       = aws_ecs_task_definition.agent.family
}

output "ecs_triage_task_definition_arn" {
  description = "ECS task definition ARN for the triage agent."
  value       = aws_ecs_task_definition.triage.arn
}

output "ecs_triage_task_definition_family" {
  description = "ECS task definition family name for triage."
  value       = aws_ecs_task_definition.triage.family
}

output "private_subnet_id" {
  description = "Private subnet ID where the Fargate task runs."
  value       = aws_subnet.private.id
}

output "agent_security_group_id" {
  description = "Security group ID for the agent task (egress 443 only)."
  value       = aws_security_group.agent.id
}

output "audit_bucket_name" {
  description = "Name of the immutable audit log S3 bucket."
  value       = aws_s3_bucket.audit.id
}

output "audit_bucket_arn" {
  description = "ARN of the immutable audit log S3 bucket."
  value       = aws_s3_bucket.audit.arn
}

output "llm_api_key_secret_arn" {
  description = "ARN of the Secrets Manager secret for the LLM API key (value set out of band)."
  value       = aws_secretsmanager_secret.llm_api_key.arn
}

output "cloudwatch_log_group_name" {
  description = "CloudWatch log group name for the ECS task."
  value       = aws_cloudwatch_log_group.agent.name
}

output "ecr_repository_url" {
  description = "ECR repository URL for the log-integrity agent image."
  value       = aws_ecr_repository.agent.repository_url
}

output "ecr_triage_repository_url" {
  description = "ECR repository URL for the triage agent image."
  value       = aws_ecr_repository.triage_agent.repository_url
}

output "agent_image" {
  description = "Image URI wired into the log-integrity ECS task definition."
  value       = local.agent_image
}

output "triage_image" {
  description = "Image URI wired into the triage ECS task definition."
  value       = local.triage_image
}
