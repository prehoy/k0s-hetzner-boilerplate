#!/usr/bin/env bash
# Idempotent GitOps bootstrap for the cluster.
#
# This is the only manual step after Terraform + Ansible have provisioned the cluster.
# It installs ArgoCD, then hands control to GitOps: the root app-of-apps pulls in
# sealed-secrets, ingress routes, monitoring, logging, and the rest of the platform.
#
# Prereqs:
#   - KUBECONFIG points at the cluster (reach the private API via the WireGuard bastion)
#   - helm + kubectl installed
#   - the repo deploy key registered in ArgoCD (see README.md)
#   - BEFORE first sync of any SealedSecret: the sealing key exists so committed SealedSecrets
#     decrypt (see ../certs/README.md). Either let the controller self-generate one, or:
#       kubectl apply -f ../certs/sealing-key.secret.yaml   # gitignored; label = active
#
# Usage:
#   export KUBECONFIG=~/.kube/cluster.conf
#   ./bootstrap.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ARGOCD_CHART_VERSION="9.4.15"   # keep in sync with apps/argocd.yaml.deferred

echo "==> Installing/upgrading ArgoCD via Helm"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version "$ARGOCD_CHART_VERSION" \
  -f "$DIR/../base/argocd/values.yaml" \
  --wait

echo "==> Applying root app-of-apps"
kubectl apply -f "$DIR/root.yaml"

cat <<'EOF'

==> Done. ArgoCD will now converge the cluster from git.

Watch progress:
  kubectl get applications -n argocd -w

If apps are stuck on the repo, register the git deploy key in ArgoCD (README.md).
Reminder: the sealing key must exist BEFORE SealedSecrets sync, or they won't decrypt.
EOF
