# GitOps Bootstrap

One root Application drives the whole cluster. After Terraform + Ansible bring up k0s, this is the
only manual step.

## Layout

```
gitops/
  bootstrap/      root.yaml (app-of-apps) + bootstrap.sh
  apps/           one Argo Application per platform component
                  (argocd.yaml.deferred -> rename to .yaml to let Argo self-manage, last)
  base/           the manifests & helm values each app points at
  certs/          sealed-secrets cert + README (DR / sealing key) — no key material committed
  cluster-setup/  traefik values (MANUAL helm release, not Argo)
```

## First-time bootstrap

```bash
# 1. Reach the private API through the WireGuard bastion, then point kubeconfig at the cluster
export KUBECONFIG=~/.kube/cluster.conf

# 2. Make sure the sealing key exists BEFORE committed SealedSecrets sync (see ../certs/README.md).
#    Either let the controller self-generate one, or restore a pre-generated key:
kubectl apply -f ../certs/sealing-key.secret.yaml      # gitignored; label sealing-key=active

# 3. Install ArgoCD + apply the root app
./bootstrap.sh

# 4. Register the git repo deploy key so ArgoCD can pull (private repo).
#    Generate a deploy key, add the public half to the repo's Deploy Keys, then:
kubectl -n argocd create secret generic infra-repo \
  --from-literal=type=git \
  --from-literal=url=git@github.com:YOUR_ORG/infra.git \
  --from-file=sshPrivateKey=/path/to/deploy_key
kubectl -n argocd label secret infra-repo argocd.argoproj.io/secret-type=repository

# 5. Traefik is a MANUAL helm release (not in app-of-apps):
helm repo add traefik https://traefik.github.io/charts && helm repo update
helm -n traefik upgrade --install traefik traefik/traefik --version 39.0.0 \
  -f ../cluster-setup/traefik/values.yaml
```

Watch it converge:

```bash
kubectl get applications -n argocd -w
```

## Secrets (Sealed Secrets)

Plaintext never enters git — only encrypted `SealedSecret` CRs, sealed against the cert at
`../certs/sealed-secrets.pem`. The `base/*/sealedsecret.yaml` files shipped here are **placeholders
with no real secret** — reseal each with your own values (`base/<app>/seal.sh`) and your own sealing
key before applying. See `../certs/README.md`.
