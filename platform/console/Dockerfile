# infra console: web UI over the infra CLI. Built by `infra platform up`.
FROM docker:cli@sha256:1a4c7cb63513f349bdad01fcc6e0f3f2f67d37b9da86f14dc0d4a0942eecda00 AS docker

FROM python:3.14-slim@sha256:a2b82f3c48559aa0a8446d9af49826b6e2b2016f4cd2afabfe6013ec53729170
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
