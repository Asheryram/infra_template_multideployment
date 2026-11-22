# infra console: web UI over the infra CLI. Built by `infra platform up`.
FROM docker:cli@sha256:34507eb5069d8be82c95dd3b6987d4250fd5fee49b82e2509b7d7a7030740d6d AS docker

FROM python:3.15-slim@sha256:65a65fc7b30b06cb6df4930fd4650697cb23f4c2698ab81fc87e4b031bc36928
RUN apt-get update \
 && apt-get install -y --no-install-recommends bash git jq openssl curl ca-certificates gettext-base util-linux procps \
 && rm -rf /var/lib/apt/lists/*
# Docker CLI + compose plugin, so the console runs the exact same scripts as the CLI and CI.
COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker /usr/local/libexec/docker/cli-plugins /usr/local/libexec/docker/cli-plugins
COPY entrypoint.sh console.py access.py policy.py index.html /app/
RUN chmod +x /app/entrypoint.sh
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s --retries=3 \
  CMD python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2)"
ENTRYPOINT ["/app/entrypoint.sh"]
