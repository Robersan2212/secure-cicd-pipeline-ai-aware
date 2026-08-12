# Log-integrity agent (ephemeral ECS task)

## What it does
1. Downloads CI job logs + a status manifest from S3 (`logs/<run_id>/`)
2. Loads the LLM API key from Secrets Manager
3. Calls a generic OpenAI-compatible Chat Completions API
4. Writes a Markdown report to `results/<run_id>/<sha>.md` on the audit bucket

## Build and push (after `terraform apply` creates ECR)

```bash
cd terraform
export AWS_PROFILE=cursor-mcp
export AWS_REGION=us-west-2
ECR_URL=$(terraform output -raw ecr_repository_url)

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_URL"

cd ../agent
docker build -t "${ECR_URL}:latest" .
docker push "${ECR_URL}:latest"
```

If the task definition already pointed at `:latest`, force a new deployment by
re-running apply or registering a new revision (any no-op apply that replaces
the task definition). Prefer an immutable tag (`v1`) in production.

## Secret format
`aws secretsmanager put-secret-value` may use either:
- plain API key string, or
- JSON: `{"api_key":"...","api_url":"https://api.openai.com/v1/chat/completions","model":"gpt-4o-mini"}`

Optional task env overrides: `LLM_API_URL`, `LLM_MODEL`.
