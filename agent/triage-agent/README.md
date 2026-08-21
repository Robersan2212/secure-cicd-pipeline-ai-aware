# Triage-summary agent (ephemeral ECS task)

Synthesizes scanner findings into plain-language summaries with remediation
hints. Detects nothing itself — it only summarizes what CI already uploaded.

## Trust boundary
- No GitHub token in the task (same as log-integrity)
- Inputs: S3 `findings/<run_id>/` + `results/<run_id>/integrity.json`
- Output: S3 `triage/<run_id>.json`
- CI runs Gitleaks on that JSON, then posts the PR comment

## Integrity gate
`main()` calls `integrity_check_passed()` first. If
`results/<run_id>/integrity.json` is missing, unreadable, or `"passed": false`,
the agent exits without writing triage output.

## Build and push

```bash
cd terraform
export AWS_PROFILE=cursor-mcp
export AWS_REGION=us-west-2
ECR_URL=$(terraform output -raw ecr_triage_repository_url)

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$ECR_URL"

cd ../agent/triage-agent
docker build -t "${ECR_URL}:latest" .
docker push "${ECR_URL}:latest"
```

## Runtime env
| Variable | Required | Purpose |
|----------|----------|---------|
| `AUDIT_BUCKET` | yes | Audit bucket |
| `RUN_ID` / `GITHUB_RUN_ID` | yes | Workflow run id |
| `FINDINGS_PREFIX` | yes | e.g. `findings/<run_id>` |
| `TRIAGE_OBJECT_KEY` | yes | e.g. `triage/<run_id>.json` |
| `INTEGRITY_OBJECT_KEY` | yes | e.g. `results/<run_id>/integrity.json` |
| `LLM_API_KEY_SECRET_ARN` | yes | Same secret as log-integrity |

## Output shape
```json
{
  "run_id": "...",
  "summarized": [
    {
      "tool": "container-scan",
      "rule_id": "...",
      "file_location": "...",
      "plain_language_summary": "...",
      "suggested_remediation": "...",
      "severity": "high"
    }
  ],
  "unsummarized": []
}
```

Findings that fail schema / tool-rule cross-check land in `unsummarized`
without discarding the rest of the run.

## Selection (24-finding cap = 6 × 4 scanners)
Takes **at most 6** findings from each of: semgrep, container/Trivy, dependency/npm,
secrets/Gitleaks — severity-sorted within each tool. No leftover fill (Trivy cannot
expand into empty Semgrep/npm slots). Filenames classify artifacts (Semgrep SARIF
bodies that mention "trivy" are no longer mislabeled as container findings).
