#!/usr/bin/env bash
# Wildcard certificate helper for TLS_MODE=selfsigned (called by `infra platform cert …`).
#
#   cert status                      what Traefik is serving: subject, names, issuer, expiry
#   cert import <crt> <key>          replace the self-signed certificate with one your browsers trust
#                                    (mkcert, an internal CA, or one bought/issued elsewhere)
#   cert check                       exit 1 and warn when the certificate expires within 30 days (used by `platform up`)
#
# Environment (set by platform.sh): DOMAIN, TLS_MODE, CERT_DIR (= $STATE_DIR/traefik/certs).
# Only the wildcard certificate this platform created or was handed is ever touched.
set -euo pipefail

: "${DOMAIN:?}" "${TLS_MODE:?}" "${CERT_DIR:?}"
CRT="$CERT_DIR/wildcard.crt" KEY="$CERT_DIR/wildcard.key" MARK="$CERT_DIR/.imported"
WARN_DAYS=${CERT_WARN_DAYS:-30}

die() { echo "cert: $*" >&2; exit 1; }
need_mode() {
  [[ $TLS_MODE == selfsigned ]] || die "TLS_MODE=$TLS_MODE: the certificate is not managed here (letsencrypt renews itself; external means your own proxy holds it)"
}
days_left() {   # days until notAfter (negative = expired)
  local end now
  end=$(date -d "$(openssl x509 -in "$1" -noout -enddate | cut -d= -f2)" +%s)
  now=$(date +%s)
  echo $(( (end - now) / 86400 ))
}
pubkey_hash() {   # fingerprint of the public key inside a certificate (x509) or private key (pkey)
  if [[ $1 == x509 ]]; then openssl x509 -in "$2" -noout -pubkey | openssl sha256
  else openssl pkey -in "$2" -pubout | openssl sha256; fi
}

status() {
  [[ -f $CRT ]] || die "no certificate yet at $CRT (run: infra platform up)"
  echo "file:     $CRT"
  echo "subject:  $(openssl x509 -in "$CRT" -noout -subject | sed 's/^subject= *//')"
  echo "issuer:   $(openssl x509 -in "$CRT" -noout -issuer | sed 's/^issuer= *//')"
  echo "names:    $(openssl x509 -in "$CRT" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' \n')"
  echo "expires:  $(openssl x509 -in "$CRT" -noout -enddate | cut -d= -f2)  ($(days_left "$CRT") days left)"
  if [[ -f $MARK ]]; then echo "source:   imported (kept as is; renew it yourself and import again)"
  elif [[ $(openssl x509 -in "$CRT" -noout -subject) == "$(openssl x509 -in "$CRT" -noout -issuer | sed 's/^issuer/subject/')" ]]; then
    echo "source:   self-signed by the platform (browsers will warn once per host — import a trusted one: infra platform cert import)"
  else echo "source:   signed by $(openssl x509 -in "$CRT" -noout -issuer | sed 's/^issuer= *//')"; fi
}

check() {
  [[ -f $CRT ]] || exit 0
  local d; d=$(days_left "$CRT")
  if (( d < WARN_DAYS )); then
    if (( d < 0 )); then echo "cert: WARNING the wildcard certificate EXPIRED $(( -d )) days ago — browsers and webhooks will fail" >&2
    else echo "cert: WARNING the wildcard certificate expires in $d days" >&2; fi
    [[ -f $MARK ]] && echo "cert: it was imported, so it will not be replaced automatically — import a renewed one: infra platform cert import <crt> <key>" >&2
    exit 1
  fi
}

import() {
  need_mode
  local crt=${1:-} key=${2:-}
  [[ -n $crt && -n $key ]] || die "usage: infra platform cert import <certificate.crt|pem> <private.key>"
  [[ -r $crt ]] || die "cannot read $crt"
  [[ -r $key ]] || die "cannot read $key"
  openssl x509 -in "$crt" -noout 2>/dev/null || die "$crt is not a PEM certificate (a full chain is fine; the first certificate must be yours)"
  openssl pkey -in "$key" -noout 2>/dev/null || die "$key is not a readable unencrypted PEM private key"
  [[ $(pubkey_hash x509 "$crt") == "$(pubkey_hash pkey "$key")" ]] || die "the private key does not belong to this certificate"
  openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | grep -qF "DNS:*.$DOMAIN" \
    || die "the certificate does not cover *.$DOMAIN (its names: $(openssl x509 -in "$crt" -noout -ext subjectAltName 2>/dev/null | tail -n +2 | tr -d ' \n'))"
  openssl x509 -in "$crt" -noout -checkend 0 >/dev/null || die "the certificate has already expired"
  local d; d=$(days_left "$crt")
  (( d >= 1 )) || die "the certificate expires within a day"
  (( d >= WARN_DAYS )) || echo "cert: note — it expires in $d days" >&2

  mkdir -p "$CERT_DIR"
  if [[ -f $CRT ]]; then cp -p "$CRT" "$CRT.bak"; [[ -f $KEY ]] && cp -p "$KEY" "$KEY.bak"; fi
  cp "$crt" "$CRT.new" && cp "$key" "$KEY.new" && chmod 644 "$CRT.new" && chmod 600 "$KEY.new"
  mv "$KEY.new" "$KEY" && mv "$CRT.new" "$CRT"      # key first: Traefik never sees a certificate without its key
  : > "$MARK"
  echo "cert: installed — valid for $d more days. Previous certificate kept as wildcard.crt.bak"
  echo "cert: now run: infra platform up   (re-renders the TLS config so Traefik reloads it)"
}

case ${1:-status} in
  status) status ;;
  import) shift; import "$@" ;;
  check)  check ;;
  *) die "usage: infra platform cert status | import <crt> <key> | check" ;;
esac
