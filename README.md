# secure-cicd-pipeline-ai-aware

CI/CD pipeline with automated SAST, dependency, secrets, and container scanning,
plus ephemeral AWS Fargate agents that review log integrity and triage findings.

## Docs

- [Architecture](docs/architecture.md) — end-to-end flow, S3 prefixes, pause tips
- [Log-integrity agent](agent/log-integrity-agent/README.md) — build/push + runtime
- [Triage agent](agent/triage-agent/README.md) — build/push + integrity gate
- [Triage build blueprint](agent/triage-agent/triage-agent-build-blueprint.md) — design constraints (see adaptation section)

## Agents (high level)

| Agent | Role |
|-------|------|
| Log-integrity | CI uploads job logs → ECS reviews pass/fail vs logs → Markdown + `integrity.json` → PR comment |
| Triage | CI uploads scan SARIF/JSON → ECS summarizes findings (gated on integrity) → JSON → Gitleaks → PR comment |

Neither agent receives a GitHub token. Infrastructure lives under [`terraform/`](terraform/).

## Demo app

Vulnerable sample app under [`app/`](app/) (OWASP Juice Shop) for the scanners to exercise.
