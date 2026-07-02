#!/usr/bin/env bash
# Idempotent GitOps bootstrap for the cluster.
#
# Installs ArgoCD from its official HA kustomize manifest (pinned in ../base/argocd), then hands off
# to the root app-of-apps. NO Helm — the ArgoCD `Application` self-manages the same kustomize path,
# so upgrades are a version bump in ../base/argocd/kustomization.yaml.
#
# Prereqs:
#   - KUBECONFIG points at the cluster (reach the private API via the WireGuard bastion)
#   - kubectl installed
#   - the repo deploy key registered in ArgoCD (see README.md)
#   - BEFORE first sync of any SealedSecret: the sealing key exists (see ../certs/README.md)
#
# Usage:
#   export KUBECONFIG=~/.kube/cluster.conf
#   ./bootstrap.sh
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Installing/upgrading ArgoCD (kustomize HA manifest, server-side apply)"
# --server-side --force-conflicts: ArgoCD's CRDs exceed the client-side last-applied annotation limit,
# and SSA lets a re-run reconcile fields cleanly.
kubectl apply -k "$DIR/../base/argocd" --server-side --force-conflicts

echo "==> Waiting for ArgoCD to come up"
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s

echo "==> Applying root app-of-apps"
kubectl apply -f "$DIR/root.yaml"

cat <<'EOF'

==> Done. ArgoCD will now converge the cluster from git.

Watch progress:
  kubectl get applications -n argocd -w

If apps are stuck on the repo, register the git deploy key in ArgoCD (README.md).
Reminder: the sealing key must exist BEFORE SealedSecrets sync, or they won't decrypt.
EOF
