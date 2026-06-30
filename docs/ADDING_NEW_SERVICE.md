# Adding a new service (GitOps + Sealed Secrets)

Workloads are deployed by ArgoCD's app-of-apps: drop manifests under `gitops/base/<app>/`, add an
`Application` under `gitops/apps/<app>.yaml`, and the root app picks it up on the next sync.

## 1. Manifests

```
gitops/base/myapp/
  kustomization.yaml
  deployment.yaml
  service.yaml
  ingressroute.yaml        # Traefik IngressRoute -> myapp.<your-domain>
  sealedsecret.yaml        # only if the app needs secrets (see step 3)
```

`kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: myapp
resources:
  - deployment.yaml
  - service.yaml
  - ingressroute.yaml
  # - sealedsecret.yaml
```

## 2. ArgoCD Application

`gitops/apps/myapp.yaml`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git@github.com:YOUR_ORG/infra.git
    targetRevision: main
    path: gitops/base/myapp
  destination:
    server: https://kubernetes.default.svc
    namespace: myapp
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions: [CreateNamespace=true]
```

## 3. Secrets (if needed)

Never commit plaintext. Seal against the cluster cert:

```bash
kubectl create secret generic myapp-secrets -n myapp \
  --from-env-file=./myapp.plain.env --dry-run=client -o yaml |   # *.plain.env is gitignored
  kubeseal --format yaml --cert gitops/certs/sealed-secrets.pem \
  > gitops/base/myapp/sealedsecret.yaml
```

Then uncomment `sealedsecret.yaml` in the kustomization. See `gitops/certs/README.md`.

## 4. DNS + ship it

```bash
# add the host to terraform/cloudflare.tf local.dns_records, then:
cd terraform && terraform apply -target='cloudflare_record.rec["myapp"]'
# commit + push the gitops changes; ArgoCD converges automatically
git add gitops/ && git commit -m "feat: add myapp" && git push
```

Watch it land:

```bash
kubectl get applications -n argocd -w
```
