#!/usr/bin/env bash
# Seal the basic-auth creds for the exposed monitoring UIs (alertmanager.example.com / prometheus.example.com)
# into monitoring-auth-sealedsecret.yaml. Traefik's basicAuth middleware reads this
# kubernetes.io/basic-auth secret (username + password). Re-run to rotate.
#   [MONITORING_AUTH_USER=admin] [MONITORING_AUTH_PASSWORD=...] ./seal-auth.sh
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
CERT="$DIR/../../certs/sealed-secrets.pem"
USER="${MONITORING_AUTH_USER:-admin}"
PW="${MONITORING_AUTH_PASSWORD:-$(head -c18 /dev/urandom | base64 | tr -d '/+=')}"

kubectl create secret generic monitoring-auth -n monitoring \
  --type=kubernetes.io/basic-auth \
  --from-literal=username="$USER" \
  --from-literal=password="$PW" \
  --dry-run=client -o yaml | kubeseal --format yaml --cert "$CERT" \
  > "$DIR/monitoring-auth-sealedsecret.yaml"

echo "Wrote monitoring-auth-sealedsecret.yaml"
echo "  basic-auth user: $USER"
echo "  basic-auth pass: $PW"
