#!/bin/sh
# Runs at container start (nginx image entrypoint). Writes /env.js exposing selected
# environment variables to the browser: RUNTIME_ENV_KEYS plus anything named PUBLIC_*.
# Never put secrets in these — everything here is public.
set -eu

KEYS="${RUNTIME_ENV_KEYS:-API_URL APP_ENV PUBLIC_URL}"
OUT=/usr/share/nginx/html/env.js

{
  printf 'window.__ENV__ = {\n'
  for k in $KEYS $(env | sed -n 's/^\(PUBLIC_[A-Za-z0-9_]*\)=.*/\1/p'); do
    v=$(printenv "$k" || true)
    v=$(printf '%s' "$v" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '  "%s": "%s",\n' "$k" "$v"
  done
  printf '};\n'
} > "$OUT"

echo "runtime env written to $OUT"
