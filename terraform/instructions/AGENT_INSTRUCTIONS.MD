# Agent Instructions — Terraform Authoring Only (AWS)

**Cloud provider: AWS, explicitly and exclusively.** Use real AWS
resource types (`aws_ecs_task_definition`, `aws_iam_openid_connect_provider`,
`aws_s3_bucket`, etc.), not abstract/generic equivalents. Do not write
multi-cloud abstractions or conditionals for other providers.

**LLM/API provider: stay generic.** The compute task calls an external
LLM API to analyze log content. Do not hardcode this to a specific LLM
vendor's naming (e.g., don't name resources/variables `anthropic_*` or
`openai_*` specifically) — use generic naming like `llm_api_key_arn` so
the human can point this at whichever LLM API they're currently using
without renaming resources.

## Scope of this agent's role

You are helping author Terraform (`.tf`) files for the infrastructure
described below. Your role is **file authoring only**.

**Hard boundaries — do not cross these under any circumstance:**
- Do NOT run `terraform apply`, `terraform destroy`, or any command that
  would provision, modify, or delete real infrastructure.
- Do NOT run `terraform plan` unprompted — if you believe running plan
  would help validate your work, ask first and let the human run it.
- Do NOT insert real credentials, access keys, account IDs, ARNs, or any
  value that looks like a live secret. Use obvious placeholders only:
  `<ACCOUNT_ID>`, `<REGION>`, `<REPO_OWNER>/<REPO_NAME>`,
  `<SECRET_ARN>`. Never fabricate a plausible-looking real value.
- Do NOT weaken, remove, or "simplify away" any security control listed
  below to make a resource easier to write or to resolve an error you
  can't otherwise fix. If a requirement seems to conflict with making
  something work, STOP and flag the conflict back to the human instead
  of resolving it yourself in either direction.
- Do NOT add remote state backend credentials or backend config values —
  leave `backend` blocks as placeholders for the human to fill in.

If any instruction below is ambiguous, ask a clarifying question rather
than guessing toward the more permissive interpretation.

---

## What we're building

Infrastructure to run an ephemeral, sandboxed AI agent that reads CI/CD
job logs and flags cases where a job's reported status (pass/fail)
doesn't match what actually happened in the log content. The agent has
exactly one write capability: append a result to an audit log. It has
no other write access anywhere.

This is implemented on **AWS**. Use AWS's native services directly —
ECS Fargate for compute, IAM + STS for identity, VPC/security groups for
networking, S3 for storage. Do not build provider-agnostic abstractions.

---

## Required resources, grouped by control

### 1. Ephemeral compute — ECS Fargate
- Use `aws_ecs_cluster` + `aws_ecs_task_definition` with
  `requires_compatibilities = ["FARGATE"]`. No EC2 instances, no
  always-on server.
- Smallest practical size: `cpu = "256"`, `memory = "512"` unless the
  human specifies otherwise.

### 2. Capability-dropped, read-only runtime
- In the task definition's `container_definitions`, set
  `readonlyRootFilesystem = true`.
- Set `linuxParameters.capabilities.drop = ["ALL"]`.
- Provide scratch space via an in-memory `volume` block mounted at
  `/tmp` — not a persistent writable volume.

### 3. Network: deny-by-default — VPC + security group
- `aws_vpc` with a **private subnet** (the task runs here) and a public
  subnet (hosts the NAT Gateway only).
- `aws_nat_gateway` + `aws_internet_gateway` so the private subnet has
  outbound-only internet access — no route allowing inbound.
- `aws_security_group` with **no `ingress` block at all** (zero inbound)
  and exactly one `egress` rule: port 443/tcp to `0.0.0.0/0`. No other
  egress rules.
- Add an `aws_vpc_endpoint` (Gateway type, free) for S3 so traffic to
  this project's own audit bucket never traverses the NAT Gateway or
  public internet.
- **Known, accepted limitation — note in a code comment, do not try to
  fix it:** this restricts by port only, not by destination domain.
  True domain-level allowlisting (e.g., "only reach api.github.com and
  the LLM API's domain specifically") would require AWS Network
  Firewall, which has an hourly cost not justified for a
  documentation-scope project. Do not add Network Firewall or a proxy
  — just comment the trade-off where the security group is defined.

### 4. Identity: federated, short-lived credentials — IAM OIDC
- `aws_iam_openid_connect_provider` trusting
  `token.actions.githubusercontent.com`, audience `sts.amazonaws.com`.
- `aws_iam_role` for GitHub Actions with an `assume_role_policy` that
  uses `StringEquals` on the `aud` claim and `StringLike` on the `sub`
  claim scoped to `repo:<REPO_OWNER>/<REPO_NAME>:ref:refs/heads/<BRANCH>`
  — never a wildcard org or "any branch" pattern.
- Set `max_session_duration = 900` (15 minutes) on that role.
- Attach an `aws_iam_role_policy` granting only: `ecs:RunTask`,
  `ecs:DescribeTasks` (scoped to this task definition's ARN),
  `iam:PassRole` (scoped to the two roles in section 5 below), and
  `s3:GetObject` (scoped to the audit bucket ARN). Add an explicit
  `Deny` statement covering `iam:*`, `s3:Delete*`, `ecs:Delete*` as
  defense-in-depth.

### 5. Identity: the agent's own runtime permissions — IAM task role
- Create a **task role** (`aws_iam_role`, assumed by
  `ecs-tasks.amazonaws.com`) separate from ECS's own execution role.
- Task role policy: `secretsmanager:GetSecretValue` scoped to exactly
  one secret ARN (`var.llm_api_key_arn`), and `s3:PutObject` scoped to
  the audit bucket ARN only. No `s3:DeleteObject`. Add an explicit
  `Deny` on `s3:Delete*`, `iam:*`, `ecs:*`, `ec2:*` as defense-in-depth.
- Create a **separate execution role** (also assumed by
  `ecs-tasks.amazonaws.com`) attached to the AWS-managed
  `AmazonECSTaskExecutionRolePolicy` — used only for ECS to pull the
  image and ship logs, kept distinct from the task role above so the
  agent's own runtime permissions stay independently auditable.

### 6. Audit storage: genuinely immutable — S3 Object Lock
- `aws_s3_bucket` created with `object_lock_enabled = true` (this
  cannot be added after bucket creation — must be set here).
- `aws_s3_bucket_versioning` set to `Enabled` (hard requirement for
  Object Lock).
- `aws_s3_bucket_object_lock_configuration` with `mode = "COMPLIANCE"`
  and a short `days` value (e.g. 30) appropriate for a documentation
  project — comment that Compliance mode means not even the account
  root user can delete these objects before that window expires, and
  that this bucket's objects will outlive a `terraform destroy` of
  everything else until then.
- `aws_s3_bucket_public_access_block` with all four settings `true`.

### 7. Observability
- `aws_cloudwatch_log_group` for the ECS task's logs, with
  `retention_in_days` set explicitly (not indefinite/unset).
- Wire the task definition's `logConfiguration` to use the `awslogs`
  driver pointed at that log group.
- Use a `default_tags` block on the `aws` provider so every resource
  is tagged with a consistent `project` identifier automatically.

---

## Style and structure expectations

- Split resources into separate files by concern (networking, identity,
  compute, storage) rather than one large file — mirror the numbered
  grouping above.
- Comment each resource block with which numbered control above it
  implements, so the mapping from protocol requirement to code stays
  traceable for someone reading the repo later.
- Use input variables for anything environment-specific (`aws_region`,
  `github_org_repo`, `github_branch`, `llm_api_key_arn`) — never inline
  a real value into a resource block.
- Prefer free AWS options where one exists over a paid equivalent (e.g.,
  S3 Gateway Endpoint over an Interface Endpoint) and note the cost
  trade-off in a comment if a paid option was chosen deliberately.
- Name resources/variables generically with respect to the LLM vendor
  (`llm_api_key_arn`, not `anthropic_api_key_arn` or `openai_api_key_arn`)
  so the human can swap LLM providers without renaming infrastructure.

---

## Before you finish

Reread your own output against the "hard boundaries" section at the
top. If anything you wrote contains a real-looking secret, a loosened
security control, or an unprompted terminal command, fix it before
presenting the result.