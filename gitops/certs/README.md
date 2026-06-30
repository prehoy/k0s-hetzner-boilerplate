# Sealed Secrets — sealing key & cert

This cluster uses [Bitnami Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets):
plaintext never enters git, only encrypted `SealedSecret` CRs. To seal a secret offline you need
the controller's public **cert**; to decrypt them in-cluster the controller needs the matching
**private key**.

## Files

| File | Committed? | What it is |
|------|-----------|------------|
| `sealed-secrets.pem` | **yes** (public) | The sealing **cert**. Seal offline with `kubeseal --cert`. Safe to commit. |
| `sealing-key.key` | **no** (gitignored) | The **private** sealing key. Back up OFFLINE. Never commit. |
| `sealing-key.secret.yaml` | **no** (gitignored) | The private key as a restorable k8s `Secret`. |

> This repo ships **no key material** — generate your own (below).

## Option A — let the controller generate its own key (simplest)

1. Bootstrap installs the sealed-secrets controller (it self-generates a key on first start).
2. Fetch the cert so you can seal offline:
   ```bash
   kubeseal --controller-namespace kube-system --fetch-cert > gitops/certs/sealed-secrets.pem
   ```
3. Seal your secrets against it (see each `base/<app>/seal.sh`), commit the `sealedsecret.yaml`.
4. **Back up the controller's key** for DR:
   ```bash
   kubectl get secret -n kube-system -l sealedsecrets.bitnami.com/sealing-key=active \
     -o yaml > sealing-key.secret.yaml   # gitignored — store offline
   ```

## Option B — pre-generate a key (seal before the cluster exists)

```bash
openssl req -x509 -nodes -newkey rsa:4096 -keyout sealing-key.key \
  -out sealed-secrets.pem -subj "/CN=sealed-secret/O=sealed-secret" -days 3650
# wrap the private key as the Secret the controller adopts on startup:
kubectl -n kube-system create secret tls sealing-key \
  --cert=sealed-secrets.pem --key=sealing-key.key --dry-run=client -o yaml \
  | kubectl label --local -f - sealedsecrets.bitnami.com/sealing-key=active -o yaml \
  > sealing-key.secret.yaml
```
At bootstrap, **apply `sealing-key.secret.yaml` BEFORE any SealedSecret syncs** so they decrypt:
```bash
kubectl apply -f gitops/certs/sealing-key.secret.yaml
```

## Sealing a secret

```bash
APP=my-app
kubectl create secret generic ${APP}-secrets --namespace my-ns \
  --from-env-file=/path/to/${APP}.plain.env --dry-run=client -o yaml |   # *.plain.env is gitignored
  kubeseal --format yaml --cert gitops/certs/sealed-secrets.pem \
  > gitops/base/${APP}/sealedsecret.yaml
```

> The placeholder `sealedsecret.yaml` files in `base/*/` contain **no real secret** — reseal them
> with your own values + key before applying.
