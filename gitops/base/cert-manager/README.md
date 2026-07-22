# cert-manager — TLS for the in-cluster Traefik

Traefik here is a **DaemonSet on every node** (hostNetwork, so HAProxy can hit any node). If each pod
ran its own ACME resolver — as the old `certificatesResolvers` block in
`gitops/cluster-setup/traefik/values.yaml` did — then on every boot or rollout all N pods would
request the same certs at once. That trips Let's Encrypt's **duplicate-certificate limit (5/week per
identical host set)** and makes the pods race on the shared `_acme-challenge` DNS record. Traefik OSS
has no distributed ACME store, so a shared `acme.json` can't fix it either (multi-writer file
corruption). The pods used an `emptyDir`, so a restart re-triggered the whole flood.

**cert-manager does the ACME challenge once**, centrally, with state in etcd, and writes the result to
a Secret. Traefik does zero ACME — it just serves the Secret.

## Shape

- Two `ClusterIssuer`s (staging + prod) sharing the Cloudflare DNS-01 solver — `clusterissuers.yaml`.
- One wildcard `Certificate` with SANs `*.example.com` **and** `*.bo.example.com` (a single-label
  wildcard doesn't cross a dot, and `status.bo.example.com` needs the second) → the `wildcard-tls`
  Secret in the **traefik** namespace — `wildcard-certificate.yaml`.
- A `TLSStore` named `default` pointing Traefik at that Secret. Every IngressRoute just sets
  `tls: {}` and gets the wildcard — no cert config duplicated per namespace.
- The Cloudflare token as a **placeholder** SealedSecret in the `cert-manager` namespace
  (`sealedsecret-cloudflare.yaml`, key `api-token`). Reseal it before it works — same as every other
  SealedSecret here (`gitops/certs/README.md`). This replaces the token Traefik used to hold.

Deployed by two ArgoCD apps: `cert-manager` (controller + CRDs, sync-wave 1) and `cert-manager-config`
(this base, sync-wave 2).

## Dry-run before spending the real rate limit

Point the Certificate's `issuerRef` at `letsencrypt-staging`, sync, and confirm the `wildcard-tls`
Secret populates and Traefik serves it (the cert will be untrusted — browsers warn, that's expected).
Then switch back to `letsencrypt-prod`.

## Requirements

- The `traefik` namespace must exist (the manual Traefik Helm release creates it — see the values
  file header). The Certificate and TLSStore live there.
- Traefik's kubernetesCRD provider must be on (it is — IngressRoutes already work).
