#!/usr/bin/env bash
# Render the join cloud-init + build HCLOUD_CLUSTER_CONFIG and seal both into sealedsecret.yaml.
#
# Why a script: HCLOUD_CLUSTER_CONFIG embeds the k0s join token (a bootstrap credential), so it must
# be sealed, never committed in cleartext. Re-run this to rotate the token (yearly) or change pool
# config (min/max/subnet). See docs/RUNBOOK-node-autoscaling.md.
#
# Prereqs:
#   - kubeseal CLI + the sealed-secrets controller running (apps/sealed-secrets.yaml)
#   - a long-lived worker token repointed at the VIP, e.g.:
#       ssh <controller> "k0s token create --role=worker --expiry=8760h \
#         | base64 -d | gunzip | sed 's#https://<ctrl-ip>:6443#https://10.0.0.240:6443#' \
#         | gzip | base64 -w0" > join.token
#
# Usage:  ./seal.sh /path/to/join.token
set -euo pipefail
TOKEN_FILE="${1:?usage: seal.sh <join-token-file>}"
DIR="$(cd "$(dirname "$0")" && pwd)"
CERT="$DIR/../../certs/sealed-secrets.pem"
HCLOUD_TOKEN="${HCLOUD_TOKEN:?export HCLOUD_TOKEN before running}"

# 1. render cloud-init with the token
CLOUD_INIT="$(sed "s|__JOIN_TOKEN__|$(cat "$TOKEN_FILE")|" "$DIR/cloud-init.yaml")"

# 2. build the cluster config JSON (cloudInit is RAW; the whole JSON is base64'd into the env var)
CLUSTER_CONFIG_B64="$(python3 - "$CLOUD_INIT" <<'PY'
import sys, json, base64
ci = sys.argv[1]
cfg = {
    "imagesForArch": {"amd64": "ubuntu-24.04", "arm64": ""},
    "nodeConfigs": {
        "cas-pool": {
            "cloudInit": ci,
            "subnetIPRange": "10.0.1.0/24",
            # node-pool=burst so CAS's scheduling template matches the real node label (set via
            # kubelet --node-labels in cloud-init); lets monitoring singletons repel the pool.
            "labels": {"role": "worker", "node-pool": "burst"},
            "taints": [],
        }
    },
}
print(base64.b64encode(json.dumps(cfg).encode()).decode())
PY
)"

# 3. seal
kubectl create secret generic cluster-autoscaler-hcloud \
  --namespace kube-system \
  --from-literal=HCLOUD_TOKEN="$HCLOUD_TOKEN" \
  --from-literal=HCLOUD_CLUSTER_CONFIG="$CLUSTER_CONFIG_B64" \
  --dry-run=client -o yaml |
  kubeseal --format yaml --cert "$CERT" \
  > "$DIR/sealedsecret.yaml"

echo "Wrote $DIR/sealedsecret.yaml"
