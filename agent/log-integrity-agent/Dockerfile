FROM python:3.12-slim

# Non-root user; writable work only via /tmp at runtime (task sets readonlyRootFilesystem).
RUN useradd --create-home --uid 10001 agent \
    && mkdir -p /app \
    && chown -R agent:agent /app

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

USER agent

ENV PYTHONUNBUFFERED=1
ENTRYPOINT ["python", "-u", "main.py"]
