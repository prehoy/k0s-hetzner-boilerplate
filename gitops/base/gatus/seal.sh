#!/usr/bin/env bash
# Full (re)seal of the gatus-smtp Secret: Brevo SMTP password + Pushover tokens (safe to commit).
# Same SMTP password as the backoffice Gatus (gatus.env.sops -> SMTP_PASSWORD); same Pushover
# "Infra Alerts" app token + user key as the backoffice Gatus.
#
# Usage (full reseal, e.g. after cert rotation — needs ALL three plaintexts):
#   SMTP_PASSWORD='<pw>' PUSHOVER_APP_TOKEN='<tok>' PUSHOVER_USER_KEY='<key>' ./seal.sh
#
# To add/rotate just ONE key without the others' plaintext, seal it --raw and paste into
# encryptedData (strict scope = name+namespace), e.g.:
#   printf '%s' '<value>' | kubeseal --raw --namespace gatus --name gatus-smtp \
#     --cert ../../certs/sealed-secrets.pem
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
CERT="$DIR/../../certs/sealed-secrets.pem"
PW="${SMTP_PASSWORD:-$( [ -n "${1:-}" ] && cat "$1" )}"
[ -n "$PW" ] || { echo "set SMTP_PASSWORD env or pass a file arg" >&2; exit 1; }
[ -n "${PUSHOVER_APP_TOKEN:-}" ] || { echo "set PUSHOVER_APP_TOKEN env" >&2; exit 1; }
[ -n "${PUSHOVER_USER_KEY:-}" ]  || { echo "set PUSHOVER_USER_KEY env" >&2; exit 1; }

kubectl create secret generic gatus-smtp \
  --namespace gatus \
  --from-literal=SMTP_PASSWORD="$PW" \
  --from-literal=PUSHOVER_APP_TOKEN="$PUSHOVER_APP_TOKEN" \
  --from-literal=PUSHOVER_USER_KEY="$PUSHOVER_USER_KEY" \
  --dry-run=client -o yaml |
  kubeseal --format yaml --cert "$CERT" \
  > "$DIR/sealedsecret.yaml"

echo "Wrote $DIR/sealedsecret.yaml"
