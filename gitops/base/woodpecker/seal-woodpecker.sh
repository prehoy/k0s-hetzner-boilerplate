#!/usr/bin/env bash
# Seal the single woodpecker-secrets Secret (DB datasource + GitHub OAuth + agent
# secret) into woodpecker-sealedsecret.yaml, using the PROD sealing cert. Keys are named
# as the env vars the Woodpecker chart loads via extraSecretNamesForEnvFrom. Plaintext
# never committed.
#
# Prereqs:
#   - kubeseal matching the prod controller
#   - a GitHub OAuth App (homepage https://ci.example.com, callback
#     https://ci.example.com/authorize) -> client id + secret
#   - a 'woodpecker' role + db on PROD Patroni (see below); know its password:
#       psql "postgres://<superuser>@haproxy-patroni.databases:5432/postgres" \
#         -c "CREATE ROLE woodpecker LOGIN PASSWORD '<pw>';" \
#         -c "CREATE DATABASE woodpecker OWNER woodpecker;"
#
# Usage:
#   ./seal-woodpecker.sh <github_client_id> <github_client_secret> <db_password>
set -euo pipefail

GH_CLIENT="${1:?github oauth client id}"
GH_SECRET="${2:?github oauth client secret}"
DB_PW="${3:?patroni woodpecker db password}"
DIR="$(cd "$(dirname "$0")" && pwd)"
CERT="$DIR/../../certs/sealed-secrets.pem"

AGENT_SECRET="$(openssl rand -hex 32)"
DATASOURCE="postgres://woodpecker:${DB_PW}@haproxy-patroni.databases:5432/woodpecker?sslmode=disable"

kubectl create secret generic woodpecker-secrets -n ci-build \
  --from-literal=WOODPECKER_DATABASE_DATASOURCE="$DATASOURCE" \
  --from-literal=WOODPECKER_GITHUB_CLIENT="$GH_CLIENT" \
  --from-literal=WOODPECKER_GITHUB_SECRET="$GH_SECRET" \
  --from-literal=WOODPECKER_AGENT_SECRET="$AGENT_SECRET" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml --cert "$CERT" > "$DIR/woodpecker-sealedsecret.yaml"

echo "Wrote woodpecker-sealedsecret.yaml — uncomment it in kustomization.yaml and commit."
