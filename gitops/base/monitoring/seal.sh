#!/usr/bin/env bash
# Seal the monitoring secrets into sealedsecret.yaml (committed; plaintext never is).
#   - grafana-secrets:      admin-password (Grafana admin login)
#   - alertmanager-secrets: slack_url, smtp_password (Brevo), pushover_token, pushover_user_key
#
# Re-run to rotate. Env overrides (else: random grafana pw + REPLACE_ME placeholders):
#   GRAFANA_ADMIN_PASSWORD=...  SLACK_WEBHOOK_URL=...  SMTP_PASSWORD=...  \
#   PUSHOVER_TOKEN=...  PUSHOVER_USER_KEY=...  ./seal.sh
# Brevo SMTP + Pushover creds are the same ones Gatus uses (ns gatus, secret gatus-smtp).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
CERT="$DIR/../../certs/sealed-secrets.pem"
NS=monitoring

GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-$(head -c18 /dev/urandom | base64 | tr -d '/+=')}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-REPLACE_ME}"
SMTP_PASSWORD="${SMTP_PASSWORD:-REPLACE_ME}"
PUSHOVER_TOKEN="${PUSHOVER_TOKEN:-REPLACE_ME}"
PUSHOVER_USER_KEY="${PUSHOVER_USER_KEY:-REPLACE_ME}"

{
  kubectl create secret generic grafana-secrets -n "$NS" \
    --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
    --dry-run=client -o yaml | kubeseal --format yaml --cert "$CERT"
  echo "---"
  kubectl create secret generic alertmanager-secrets -n "$NS" \
    --from-literal=slack_url="$SLACK_WEBHOOK_URL" \
    --from-literal=smtp_password="$SMTP_PASSWORD" \
    --from-literal=pushover_token="$PUSHOVER_TOKEN" \
    --from-literal=pushover_user_key="$PUSHOVER_USER_KEY" \
    --dry-run=client -o yaml | kubeseal --format yaml --cert "$CERT"
} > "$DIR/sealedsecret.yaml"

echo "Wrote $DIR/sealedsecret.yaml"
for v in SLACK_WEBHOOK_URL SMTP_PASSWORD PUSHOVER_TOKEN PUSHOVER_USER_KEY; do
  [ "${!v}" = REPLACE_ME ] && echo "  NOTE: $v is a placeholder — re-run with $v=..."
done
echo "  Grafana admin password: $GRAFANA_ADMIN_PASSWORD"
