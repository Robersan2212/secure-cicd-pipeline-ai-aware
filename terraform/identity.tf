# Control 4 — Identity: federated, short-lived credentials (IAM OIDC for GitHub Actions)
# Control 5 — Identity: agent runtime task role + separate ECS execution role

locals {
  # GitHub immutable OIDC subjects (repos using the new claim format):
  #   repo:OWNER@OWNER_ID/REPO@REPO_ID:pull_request
  #   repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:refs/heads/<branch>
  github_oidc_repo_prefix = format(
    "repo:%s@%s/%s@%s",
    split("/", var.github_org_repo)[0],
    var.github_owner_id,
    split("/", var.github_org_repo)[1],
    var.github_repo_id,
  )
  github_oidc_sub_branch       = "${local.github_oidc_repo_prefix}:ref:refs/heads/${var.github_branch}"
  github_oidc_sub_pull_request = "${local.github_oidc_repo_prefix}:pull_request"
}

resource "aws_iam_openid_connect_provider" "github" {
  # Control 4: trust GitHub Actions OIDC (audience sts.amazonaws.com)
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com",
  ]

  # Public GitHub Actions IdP certificate thumbprints (not secrets).
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]
}

data "aws_iam_policy_document" "github_actions_assume" {
  # Control 4: aud StringEquals + sub StringLike scoped to this repo only
  # (main branch pushes + pull_request events — not refs/heads/*)
  statement {
    sid     = "GitHubActionsOIDC"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        local.github_oidc_sub_branch,
        local.github_oidc_sub_pull_request,
      ]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  # Control 4: short-lived federated role for GitHub Actions.
  # AWS IAM requires max_session_duration >= 3600 (role ceiling). Enforce the
  # intended 15-minute sessions in CI via AssumeRole DurationSeconds / 
  # role-duration-seconds: 900 (callers may request less than this ceiling).
  name                 = "${var.project_name}-github-actions"
  assume_role_policy   = data.aws_iam_policy_document.github_actions_assume.json
  max_session_duration = 3600
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "github_actions" {
  # Control 4: least-privilege Allow + explicit Deny defense-in-depth
  statement {
    sid    = "RunAgentTask"
    effect = "Allow"
    actions = [
      "ecs:RunTask",
    ]
    resources = [
      aws_ecs_task_definition.agent.arn,
      aws_ecs_task_definition.triage.arn,
      aws_ecs_cluster.agent.arn,
    ]
  }

  statement {
    sid    = "DescribeAgentTasks"
    effect = "Allow"
    actions = [
      "ecs:DescribeTasks",
    ]
    # Task ARNs look like …:task/<cluster-name>/<id> — needed to wait for completion.
    resources = [
      "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:task/${aws_ecs_cluster.agent.name}/*",
    ]
  }

  statement {
    sid    = "PassAgentRolesOnly"
    effect = "Allow"
    actions = [
      "iam:PassRole",
    ]
    resources = [
      aws_iam_role.ecs_task.arn,
      aws_iam_role.ecs_execution.arn,
    ]
  }

  statement {
    sid    = "ReadAuditObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
    ]
    resources = [
      "${aws_s3_bucket.audit.arn}/*",
    ]
  }

  statement {
    sid    = "UploadCiLogsForAgent"
    effect = "Allow"
    actions = [
      "s3:PutObject",
    ]
    resources = [
      "${aws_s3_bucket.audit.arn}/logs/*",
    ]
  }

  statement {
    sid    = "UploadScanFindingsForTriage"
    effect = "Allow"
    actions = [
      "s3:PutObject",
    ]
    resources = [
      "${aws_s3_bucket.audit.arn}/findings/*",
    ]
  }

  statement {
    sid    = "ListAuditBucketForLogUpload"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.audit.arn,
    ]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["logs/*", "findings/*"]
    }
  }

  # Control 4: Deny privilege-escalation IAM actions (not iam:*), so the
  # tightly-scoped PassRole Allow above still functions.
  statement {
    sid    = "DenyDangerousMutations"
    effect = "Deny"
    actions = [
      "iam:CreateUser",
      "iam:CreateAccessKey",
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:CreatePolicy",
      "iam:UpdateAssumeRolePolicy",
      "iam:AttachUserPolicy",
      "iam:PutUserPolicy",
      "s3:Delete*",
      "ecs:Delete*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions" {
  # Control 4: inline policy on the GitHub Actions role
  name   = "${var.project_name}-github-actions"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions.json
}

data "aws_iam_policy_document" "ecs_task_assume" {
  # Control 5: task role assumed only by ECS tasks
  statement {
    sid     = "ECSTasksAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task" {
  # Control 5: agent runtime permissions (distinct from execution role)
  name               = "${var.project_name}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

data "aws_iam_policy_document" "ecs_task" {
  # Control 5: GetSecretValue on exactly one secret; PutObject on audit bucket only; no DeleteObject
  statement {
    sid    = "ReadLlmApiKey"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
    ]
    resources = [
      aws_secretsmanager_secret.llm_api_key.arn,
    ]
  }

  statement {
    sid    = "AppendAuditResults"
    effect = "Allow"
    actions = [
      "s3:PutObject",
    ]
    resources = [
      "${aws_s3_bucket.audit.arn}/results/*",
    ]
  }

  statement {
    sid    = "AppendTriageSummaries"
    effect = "Allow"
    actions = [
      "s3:PutObject",
    ]
    resources = [
      "${aws_s3_bucket.audit.arn}/triage/*",
    ]
  }

  statement {
    sid    = "ReadCiLogs"
    effect = "Allow"
    actions = [
      "s3:GetObject",
    ]
    resources = [
      "${aws_s3_bucket.audit.arn}/logs/*",
    ]
  }

  statement {
    sid    = "ReadIntegrityResults"
    effect = "Allow"
    actions = [
      "s3:GetObject",
    ]
    resources = [
      "${aws_s3_bucket.audit.arn}/results/*",
    ]
  }

  statement {
    sid    = "ReadScanFindings"
    effect = "Allow"
    actions = [
      "s3:GetObject",
    ]
    resources = [
      "${aws_s3_bucket.audit.arn}/findings/*",
    ]
  }

  statement {
    sid    = "ListCiLogsPrefix"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.audit.arn,
    ]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["logs/*", "findings/*", "results/*"]
    }
  }

  statement {
    sid    = "DenyDangerousMutations"
    effect = "Deny"
    actions = [
      "s3:Delete*",
      "iam:*",
      "ecs:*",
      "ec2:*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ecs_task" {
  # Control 5: inline policy for the agent's own runtime role
  name   = "${var.project_name}-ecs-task"
  role   = aws_iam_role.ecs_task.id
  policy = data.aws_iam_policy_document.ecs_task.json
}

resource "aws_iam_role" "ecs_execution" {
  # Control 5: separate execution role — image pull + logs only (not agent runtime perms)
  name               = "${var.project_name}-ecs-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  # Control 5: AWS-managed AmazonECSTaskExecutionRolePolicy only
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
