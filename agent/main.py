"""Ephemeral log-integrity agent.

Reads CI job logs + reported statuses from S3 (uploaded by GitHub Actions),
calls an LLM API using a key from Secrets Manager, and writes an audit report
to S3. Scratch I/O must stay under /tmp (read-only root FS).

Supports:
  - Anthropic Messages API (default for sk-ant-* keys)
  - OpenAI-compatible Chat Completions (Bearer token APIs)
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

import boto3

TMP = Path("/tmp")
MAX_LOG_CHARS = 12_000
MAX_JOBS = 8

SYSTEM_PROMPT = (
    "You are a CI log-integrity reviewer. Compare each job's reported "
    "conclusion (success/failure) with the log content. Flag only clear "
    "mismatches (e.g. reported success but log shows fatal errors / reported "
    "failure but log shows clean success). Be concise. Reply in GitHub-flavored "
    "Markdown with a short summary and a bullet list of findings. If nothing "
    "looks inconsistent, say so explicitly."
)

ANTHROPIC_DEFAULT_URL = "https://api.anthropic.com/v1/messages"
ANTHROPIC_DEFAULT_MODEL = "claude-sonnet-4-20250514"
OPENAI_DEFAULT_URL = "https://api.openai.com/v1/chat/completions"
OPENAI_DEFAULT_MODEL = "gpt-4o-mini"


def env(name: str, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if value is None or value == "":
        raise SystemExit(f"missing required env var: {name}")
    return value


def redact_secrets(text: str, api_key: str) -> str:
    """Avoid echoing API keys in logs/errors."""
    redacted = text
    if api_key:
        redacted = redacted.replace(api_key, "[REDACTED]")
    redacted = re.sub(r"sk-ant-[A-Za-z0-9_\-]+", "sk-ant-[REDACTED]", redacted)
    redacted = re.sub(r"sk-(?:proj-)?[A-Za-z0-9_\-]+", "sk-[REDACTED]", redacted)
    return redacted


def load_llm_credentials(secret_arn: str) -> tuple[str, str, str, str]:
    """Return (api_key, api_url, model, provider).

    SecretString may be:
      - plain API key string, or
      - JSON: {"api_key":"...","api_url":"...","model":"...","provider":"anthropic|openai"}
    """
    client = boto3.client("secretsmanager")
    resp = client.get_secret_value(SecretId=secret_arn)
    raw = resp.get("SecretString") or ""
    api_key = raw
    provider_hint = os.environ.get("LLM_PROVIDER", "")
    api_url = os.environ.get("LLM_API_URL", "")
    model = os.environ.get("LLM_MODEL", "")

    try:
        parsed = json.loads(raw)
        if isinstance(parsed, dict):
            api_key = str(parsed.get("api_key") or parsed.get("apiKey") or "")
            api_url = str(parsed.get("api_url") or parsed.get("apiUrl") or api_url)
            model = str(parsed.get("model") or model)
            provider_hint = str(parsed.get("provider") or provider_hint)
    except json.JSONDecodeError:
        pass

    if not api_key:
        raise SystemExit("LLM secret did not contain an API key")

    provider = provider_hint.lower().strip()
    if not provider:
        if api_key.startswith("sk-ant-") or "anthropic.com" in api_url:
            provider = "anthropic"
        else:
            provider = "openai"

    if provider == "anthropic":
        api_url = api_url or ANTHROPIC_DEFAULT_URL
        model = model or ANTHROPIC_DEFAULT_MODEL
    else:
        api_url = api_url or OPENAI_DEFAULT_URL
        model = model or OPENAI_DEFAULT_MODEL

    return api_key, api_url, model, provider


def download_logs(bucket: str, prefix: str) -> tuple[dict[str, Any], list[tuple[str, str]]]:
    s3 = boto3.client("s3")
    manifest_key = f"{prefix.rstrip('/')}/manifest.json"
    manifest_obj = s3.get_object(Bucket=bucket, Key=manifest_key)
    manifest = json.loads(manifest_obj["Body"].read().decode("utf-8"))

    jobs: list[tuple[str, str]] = []
    for job in (manifest.get("jobs") or [])[:MAX_JOBS]:
        name = str(job.get("name") or "job")
        key = job.get("log_key")
        if not key:
            continue
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read().decode("utf-8", errors="replace")
        if len(body) > MAX_LOG_CHARS:
            body = body[-MAX_LOG_CHARS:]
        jobs.append((name, body))
    return manifest, jobs


def _http_json(url: str, payload: dict[str, Any], headers: dict[str, str], api_key: str) -> dict[str, Any]:
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(
            f"LLM API HTTP {exc.code}: {redact_secrets(detail[:500], api_key)}"
        ) from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"LLM API request failed: {exc}") from exc


def call_anthropic(api_key: str, api_url: str, model: str, prompt: str) -> str:
    payload = {
        "model": model,
        "max_tokens": 1024,
        "temperature": 0,
        "system": SYSTEM_PROMPT,
        "messages": [{"role": "user", "content": prompt}],
    }
    headers = {
        "Content-Type": "application/json",
        "x-api-key": api_key,
        "anthropic-version": "2023-06-01",
    }
    result = _http_json(api_url, payload, headers, api_key)
    try:
        blocks = result["content"]
        texts = [b.get("text", "") for b in blocks if b.get("type") == "text"]
        text = "\n".join(t for t in texts if t).strip()
        if not text:
            raise KeyError("empty text")
        return text
    except (KeyError, IndexError, TypeError, AttributeError) as exc:
        raise SystemExit(
            f"unexpected Anthropic response shape: {redact_secrets(json.dumps(result)[:500], api_key)}"
        ) from exc


def call_openai_compatible(api_key: str, api_url: str, model: str, prompt: str) -> str:
    payload = {
        "model": model,
        "temperature": 0,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": prompt},
        ],
    }
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
    }
    result = _http_json(api_url, payload, headers, api_key)
    try:
        return str(result["choices"][0]["message"]["content"])
    except (KeyError, IndexError, TypeError) as exc:
        raise SystemExit(
            f"unexpected OpenAI-compatible response shape: {redact_secrets(json.dumps(result)[:500], api_key)}"
        ) from exc


def call_llm(api_key: str, api_url: str, model: str, provider: str, prompt: str) -> str:
    if provider == "anthropic":
        return call_anthropic(api_key, api_url, model, prompt)
    return call_openai_compatible(api_key, api_url, model, prompt)


def build_prompt(manifest: dict[str, Any], jobs: list[tuple[str, str]]) -> str:
    lines = [
        f"Repository: {manifest.get('repository', 'unknown')}",
        f"Workflow run id: {manifest.get('run_id', 'unknown')}",
        f"SHA: {manifest.get('sha', 'unknown')}",
        "",
        "Reported job conclusions:",
    ]
    for job in manifest.get("jobs") or []:
        lines.append(
            f"- {job.get('name')}: conclusion={job.get('conclusion')} status={job.get('status')}"
        )
    lines.append("")
    lines.append("Log excerpts (truncated):")
    for name, body in jobs:
        lines.append(f"\n### Job: {name}\n```\n{body}\n```")
    return "\n".join(lines)


def write_audit(bucket: str, key: str, report: str) -> None:
    s3 = boto3.client("s3")
    s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=report.encode("utf-8"),
        ContentType="text/markdown; charset=utf-8",
    )


def main() -> None:
    bucket = env("AUDIT_BUCKET")
    audit_key = env("AUDIT_OBJECT_KEY")
    logs_prefix = env("LOGS_PREFIX")
    secret_arn = env("LLM_API_KEY_SECRET_ARN")

    print("loading LLM credentials from Secrets Manager", flush=True)
    api_key, api_url, model, provider = load_llm_credentials(secret_arn)

    # Do not log bucket names in portfolio-friendly mode; keep high-level progress only.
    print("downloading CI logs from S3", flush=True)
    manifest, jobs = download_logs(bucket, logs_prefix)
    if not jobs:
        report = (
            "## Log integrity agent findings\n\n"
            "No job logs were available under the provided logs prefix.\n"
        )
        write_audit(bucket, audit_key, report)
        print("wrote empty-log audit object", flush=True)
        return

    prompt = build_prompt(manifest, jobs)
    (TMP / "prompt.txt").write_text(prompt, encoding="utf-8")

    print(f"calling LLM provider={provider} model={model}", flush=True)
    analysis = call_llm(api_key, api_url, model, provider, prompt)

    report = (
        "## Log integrity agent findings\n\n"
        f"- Jobs analyzed: {len(jobs)}\n"
        f"- Workflow run: `{manifest.get('run_id', 'unknown')}`\n\n"
        f"{analysis.strip()}\n"
    )
    write_audit(bucket, audit_key, report)
    print("wrote audit findings object", flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001 — top-level task exit
        print(f"agent failed: {exc}", file=sys.stderr, flush=True)
        sys.exit(1)
