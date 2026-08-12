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
  description = "ECS task definition family name."
  value       = aws_ecs_task_definition.agent.family
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
