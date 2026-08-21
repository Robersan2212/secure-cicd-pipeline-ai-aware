# Architecture

This project is a long-lived AWS security lab for a GitHub Actions CI pipeline. The lab stays up between runs. Individual agent workloads are short-lived ECS Fargate tasks. Scan jobs and PR comments stay in GitHub Actions. The agents never receive a GitHub token.

The application under `app/` (OWASP Juice Shop) is scanned by SAST, dependency, secrets, and container jobs. The pipeline posts integrity and triage reviews on the PR. Selected findings and remediations are documented in [findings.md](findings.md) to show a find-then-fix loop.

---

## Design principles

1. **Build the lab once; run disposable tasks inside it.** Terraform provisions networking, identity, storage, and task definitions. Each PR or push starts ephemeral Fargate tasks that exit when done.
2. **CI owns GitHub. Agents own analysis.** GitHub Actions assumes AWS via OIDC, uploads inputs to S3, starts tasks, downloads results, and posts PR comments. Agent containers only talk to AWS APIs and the LLM provider.
3. **Fail closed between agents.** Triage refuses to summarize findings unless log-integrity wrote `integrity.json` with `"passed": true`.
4. **Least privilege and hardened runtime.** Separate IAM roles for GitHub Actions vs task execution vs task runtime. Fargate tasks use a read-only root filesystem, dropped Linux capabilities, and an in-memory `/tmp`.
5. **Immutable audit trail.** Agent outputs land in an S3 bucket with Object Lock (COMPLIANCE) so published results are hard to silently rewrite.

---

## Creation flow (how the lab is brought up)

This is the order a reader should understand when reproducing or explaining the stack.

### 1. Remote Terraform state (one-time)

State lives in an S3 bucket with DynamoDB locking (configured via `terraform/backend.hcl`, not committed with secrets). After `terraform init -backend-config=backend.hcl`, all applies share one state file for this project.

### 2. Apply infrastructure (`terraform apply`)

Terraform creates the long-lived resources below (see `terraform/`). Outputs feed GitHub Actions secrets and image push commands.

**Networking**

- Dedicated VPC with DNS enabled.
- Public subnet hosting only the NAT Gateway path.
- Private subnet where Fargate tasks run (no public IPs).
- Internet Gateway for the public subnet.
- NAT Gateway + Elastic IP so private tasks can reach the LLM API and other HTTPS egress.
- Private route table default route via NAT; public route table via IGW.
- Security group for agents: deny-by-default inbound; egress limited to HTTPS (443).
- S3 gateway VPC endpoint so S3 traffic from the private subnet does not need the NAT path.

**Identity**

- GitHub Actions OIDC identity provider (trust limited to this repository using immutable owner/repo IDs and allowed branch / pull_request subjects).
- IAM role for GitHub Actions (`<project>-github-actions`): short sessions from CI; can `RunTask` / `DescribeTasks`, `PassRole` only the ECS execution and task roles, upload to `logs/*` and `findings/*`, and read audit objects. Explicit denies block privilege-escalation IAM and destructive S3/ECS actions.
- ECS task execution role: pull images from ECR and write CloudWatch logs (AWS managed execution policy).
- ECS task role (runtime): `GetSecretValue` on the single LLM secret; `GetObject` on `logs/*`, `findings/*`, and `results/*`; `PutObject` on `results/*` and `triage/*`; no `DeleteObject`.

**Compute**

- One ECS cluster (Fargate; Container Insights off for cost).
- Two task definitions (256 CPU / 512 MiB): log-integrity and triage. Same hardening profile; different container images and log stream prefixes.
- One CloudWatch Logs group with explicit retention for both agents.

**Storage and secrets**

- Audit S3 bucket: versioning, public access block, Object Lock COMPLIANCE with a retention window.
- Secrets Manager secret shell for the LLM API key (value set out of band, never in Terraform).

**Container registries**

- ECR repository for the log-integrity image.
- ECR repository for the triage image.
- Lifecycle policies keep a bounded number of images.

### 3. Set the LLM secret (out of band)

Store the provider API key in the Secrets Manager secret Terraform created (plain string or JSON with `api_key` / `provider` / `model`). Agents resolve it at runtime via the task role.

### 4. Build and push agent images

Human-operated (or scripted) Docker build/push to each ECR URL from Terraform outputs. Task definitions reference the `:latest` image tag. A new push is required whenever agent code changes.

### 5. Wire GitHub Actions secrets

CI reads configuration from repository secrets (no account IDs or ARNs in workflow source). Required secrets:

- `AWS_ROLE_ARN`, `AWS_REGION`
- `ECS_CLUSTER`, `ECS_TASK_DEFINITION`, `ECS_TRIAGE_TASK_DEFINITION`
- `ECS_SUBNET_ID`, `ECS_SECURITY_GROUP_ID`
- `AUDIT_BUCKET_NAME`, `LLM_API_KEY_SECRET_ARN`

After this, a push or pull request to `main` runs the full pipeline against the live lab.

---

## Runtime flow (what happens on each CI run)

### Stage A — Security scans (parallel)

Four GitHub Actions jobs run on `ubuntu-latest`:

| Job | Purpose | Artifact for triage |
|-----|---------|---------------------|
| `semgrep-scan` | SAST (OWASP / security-audit rules) | `semgrep.sarif` |
| `dependency-scan` | `npm ci` + `npm audit` in `app/` | `npm-audit.json` |
| `secrets-scan` | Gitleaks on the repository (full history) | `gitleaks-report.json` |
| `container-scan` | Build app image + Trivy HIGH/CRITICAL; SARIF to GitHub Security | `trivy-results.sarif` |

Jobs may fail when findings exceed thresholds. That is expected for the demo app. Artifacts are uploaded with `if: always()` so later stages still receive scan output.

### Stage B — Log-integrity agent

Job `log-integrity-agent` runs after the four scans (`needs` them, `if: always()`).

1. Assumes the GitHub Actions IAM role via OIDC (about 15 minutes).
2. Downloads sibling job logs from the GitHub API and uploads them to S3 under `logs/<run_id>/`, plus a `manifest.json` of job names and conclusions.
3. Starts the log-integrity Fargate task with environment pointing at the bucket, log prefix, result keys, and LLM secret ARN.
4. Waits for the task to stop.
5. Downloads the Markdown report from S3 and posts it as a PR comment (CI uses `GITHUB_TOKEN`).

Inside the task, the agent loads the LLM key from Secrets Manager, compares reported conclusions to log content, and writes:

- `results/<run_id>/<sha>.md` — human-readable review for the PR.
- `results/<run_id>/integrity.json` — machine gate: `{"passed": true|false, "run_id", "sha"}`. The boolean comes from a structured model JSON field (`passed` + `markdown`), not keyword guessing on prose. Missing logs or invalid model output → `passed: false`.

PR comment from a successful integrity review (scan jobs failed as expected for the demo app; conclusions matched the logs):

![Log integrity agent PR comment](./images/findings/log-integrity-agent-githubactions.png)

*GitHub Actions posts the Markdown report from S3; the agent never holds a GitHub token.*

### Stage C — Triage agent

Job `triage-summary-agent` runs after log-integrity (and the scans), `if: always()`.

1. Assumes the same GitHub Actions role via OIDC.
2. Downloads scan artifacts and uploads them to S3 under `findings/<run_id>/`.
3. Starts the triage Fargate task.
4. Waits for stop; downloads `triage/<run_id>.json` if present.
5. Runs Gitleaks on that JSON (`--no-git`). On a hit, skips the PR comment.
6. Posts a grouped triage comment on the PR (four scanner sections).

Inside the task:

1. **Integrity gate first.** Reads `integrity.json`. If missing, unreadable, or `"passed"` is not true, exits without writing triage output.
2. Parses findings from S3. Classifies artifacts by **filename** (so Semgrep SARIF text that mentions other tools cannot be mislabeled).
3. Selects up to **six findings per scanner** (Semgrep, Trivy/container, npm/dependency, Gitleaks/secrets), severity-sorted within each tool. No leftover fill from one noisy scanner. Cap is 24 summarized items.
4. One LLM call per selected finding; schema validation; failures go to `unsummarized` without discarding the rest.
5. Writes only `triage/<run_id>.json`. Does not post to GitHub.

PR comment after Gitleaks clears the triage JSON (findings grouped by scanner):

![Triage summary agent PR comment](./images/findings/triage-summary-agent-githubactions.png)

*CI posts the grouped summary; each item includes location, plain-language summary, and remediation.*

---

## Cloud components (portfolio inventory)

### Network isolation

Tasks run in a private subnet. Inbound is closed. Outbound HTTPS goes through NAT. S3 uses a gateway endpoint. This matches a “deny by default, explicit egress” story suitable for a security portfolio.

### Identity and access

| Principal | Trust | Purpose |
|-----------|--------|---------|
| GitHub OIDC → Actions role | This repo’s OIDC subjects only | CI: upload inputs, run tasks, read results, never hold long-lived AWS keys in GitHub |
| ECS execution role | ECS tasks service | Image pull + log driver |
| ECS task role | ECS tasks service | Runtime: secret read, scoped S3 get/put |

Agents do not get `pull-requests: write` or a GitHub PAT. Commenting is a CI responsibility.

### Compute

- **Cluster:** shared, always defined, no always-on containers.
- **Task definitions:** two families (integrity and triage); same size and hardening; different images.
- **Runtime controls:** read-only root FS; `capabilities.drop = ALL`; tmpfs `/tmp` for scratch; non-root container user in the Dockerfiles.

### Data plane (audit bucket)

| Key prefix | Written by | Read by | Role |
|------------|------------|---------|------|
| `logs/<run_id>/` | GitHub Actions | Log-integrity task | Raw CI logs + manifest |
| `findings/<run_id>/` | GitHub Actions | Triage task | SARIF / JSON from scanners |
| `results/<run_id>/<sha>.md` | Log-integrity task | GitHub Actions | Integrity PR body |
| `results/<run_id>/integrity.json` | Log-integrity task | Triage task | Gate between agents |
| `triage/<run_id>.json` | Triage task | GitHub Actions | Triage PR body (after Gitleaks) |

Object Lock makes published audit objects retention-protected. Re-running the same workflow run id may create new object versions under Object Lock.

### Observability

Task stdout/stderr go to a shared CloudWatch log group (`/ecs/<project>-agent`) with stream prefixes `agent` and `triage`. Retention is set explicitly (not indefinite).

### External dependency

HTTPS calls from the private subnet to the configured LLM provider (Anthropic by default for `sk-ant-*` keys; OpenAI-compatible optional). The API key never enters Terraform or the GitHub workflow file.

---

## Repository map

| Path | Role |
|------|------|
| `.github/workflows/security-pipeline.yml` | Scans + OIDC + RunTask + PR comments |
| `terraform/` | Lab infrastructure as code |
| `agent/log-integrity-agent/` | Integrity container source |
| `agent/triage-agent/` | Triage container source |
| `app/` | Application under test (scanners target this tree) |
| `docs/architecture.md` | This document |
| `docs/findings.md` | Selected findings with remediations |

---

## What this architecture demonstrates

- Secure CI/CD integration with AWS using **OIDC instead of static cloud keys in GitHub**.
- **Separation of duties** between CI (orchestration, GitHub) and agents (analysis only).
- **Defense in depth** on the agent runtime (network, IAM, filesystem, capabilities).
- An **AI-assisted review loop** with an explicit integrity gate before triage publish.
- **Ephemeral agent compute** (Fargate tasks exit when done; no always-on application servers).
- An **immutable audit path** for agent outputs suitable for explaining compliance-minded design choices.
- A **find-then-fix** path: triage highlights issues; remediations for selected findings are documented in [findings.md](findings.md).
