# infra console: web UI over the infra CLI. Built by `infra platform up`.
FROM docker:cli@sha256:5e6baf67325a79f64ed3bed6863954d5e05d0f3d4e57cbdb14809346814bbfdb AS docker

FROM python:3.12-slim@sha256:a6e34c598f2467ed0e9a8d349809fcd8b5c603269512df273a0bb1784edc11b1
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
