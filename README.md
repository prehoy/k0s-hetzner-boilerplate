# Highly available k0s cluster boilerplate

> by [@misterkuka](https://github.com/misterkuka)

A batteries-included, **fully HA** Kubernetes ([k0s](https://k0sproject.io/)) cluster on
[Hetzner Cloud](https://www.hetzner.com/cloud), provisioned end-to-end as code: **Terraform** for the
infrastructure, **Ansible** for the cluster + stateful HA, and **ArgoCD** (app-of-apps) for everything
running inside. No single node can take the cluster down.

Everything is parameterized and ships with `.example` placeholders — **no real secrets in this repo**.
Fill them in, set your `domain`, and `terraform apply`.

---

## Architecture

```mermaid
flowchart TB
  internet([Internet]) --> cf[Cloudflare DNS]
  cf --> fip[[Floating IP]]

  subgraph net["Private network 10.0.0.0/16"]
    fip --> lb["LB pair · keepalived + haproxy<br/>VIP 10.0.0.240 (k8s API) · floating IP (ingress)"]
    lb --> cp["Control plane ×3<br/>k0s controllers + etcd quorum"]
    lb --> wk["Workers ×N<br/>+ cluster-autoscaler"]
    cp -. schedules .-> wk
    wk --> nfs["NFS pair · DRBD<br/>VIP 10.0.0.199 (RWX storage)"]
    wk --> pg["Patroni Postgres ×3<br/>1 primary + 2 replicas"]
    wk -. egress .-> nat["NAT-HA<br/>(via LB pair)"]
  end

  bastion["Backoffice box · Docker Swarm<br/>WireGuard VPN · swarmpit · gatus · db-backups"] -. admin VPN .-> net
  nat --> internet
  admin([Admin]) -. WireGuard .-> bastion
```

<details>
<summary>ASCII fallback</summary>

```
                Internet
                   │
            Cloudflare DNS
                   │
              Floating IP
                   │
   ┌───────────────┴───────────────────────── private net 10.0.0.0/16 ──┐
   │   LB pair (keepalived + haproxy)                                    │
   │   VIP 10.0.0.240 = k8s API · floating IP = ingress                  │
   │        │                         │                                  │
   │  control plane ×3           workers ×N ── cluster-autoscaler        │
   │  (etcd quorum)                   │                                  │
   │                          ┌───────┼─────────┐                        │
   │                   NFS pair (DRBD)   Patroni Postgres ×3   NAT-HA     │
   │                   VIP 10.0.0.199    1 primary + 2 replica  (egress)  │
   └────────────────────────────────────────────────────────────────────┘
        ▲ admin VPN
   Backoffice box (Docker Swarm): WireGuard · swarmpit · gatus · db-backups
```
</details>

## How HA is covered

Every layer removes a single point of failure. The "Implemented in" column points at the code.

| Layer | SPOF removed by | Survives | Implemented in |
|---|---|---|---|
| **Control plane** | 3 k0s controllers + etcd quorum behind VIP `10.0.0.240` | 1 controller down | `ansible/playbooks/k0s_main` |
| **Ingress / API LB** | LB pair, keepalived owns the floating IP + API VIP | 1 LB node down | `ansible/playbooks/loadbalancer` |
| **Workers** | N workers + Hetzner cluster-autoscaler | node loss / load spikes | `gitops/base/cluster-autoscaler` |
| **Storage (RWX)** | DRBD NFS pair, keepalived alias-IP `10.0.0.199`, diskless tiebreaker for quorum | 1 NFS node down | `ansible/playbooks/nfs/nfs_ha` |
| **Database** | 3-node Patroni (1 primary + 2 replicas), automatic failover | primary loss | `ansible/playbooks/postgres` |
| **DNS** | Cloudflare as-code, low TTL | record drift / fast cutover | `terraform/cloudflare.tf` |
| **Egress (NAT)** | NAT-HA on the LB pair (route → `10.0.0.210`) | NAT node down | `ansible/playbooks/loadbalancer` |
| **GitOps** | ArgoCD self-heal + app-of-apps | config drift / manual change | `gitops/` |
| **Admin access** | WireGuard bastion to the private net | — | `ansible/playbooks/backoffice` |

## What's inside

```
terraform/   Hetzner servers/network/volumes/floating IPs + Cloudflare DNS  (+ databasus/ for backups)
ansible/     k0s install, LB/keepalived, DRBD NFS, Patroni Postgres, WireGuard, node tuning
gitops/      ArgoCD app-of-apps: sealed-secrets, traefik, nfs-provisioner, cluster-autoscaler,
             monitoring (Prometheus/Grafana/Alertmanager), hyperdx + otel logs, tetragon, keydb,
             db-access, gatus, woodpecker CI
backoffice/  Docker-Swarm management box: WireGuard VPN, swarmpit, gatus, databasus, db_lb, traefik
docs/        BUILD.md (full runbook) · ADDING_NEW_SERVICE.md
```

## Topology (defaults, all in `terraform/main.tf`)

3 controllers · N workers (+ autoscaled burst pool) · 3 Postgres (Patroni) · 2 NFS (DRBD) ·
2 LB (keepalived) · 1 backoffice/NAT box. Private network `10.0.0.0/16`; IP plan: managers `.3–.49`,
workers `.50–.99`, db `.100–.149`, backoffice `.150`, nfs `.200–.209`, lb `.210–.211`.

## Before you start

1. Replace **`example.com`** with your domain (global find/replace) — or just set `var.domain` in
   Terraform; the in-cluster manifests use `example.com` as the placeholder host.
2. Fill the `.example` files: `terraform/secrets.auto.tfvars`, `terraform/terraform.tfvars`,
   `ansible/inventory`, `ansible/playbooks/loadbalancer/secrets.yml`, `backoffice/.sops.yaml` + age key.
3. Drop your SSH public key in `terraform/ssh_keys/admin.pub`.
4. Generate a fresh Sealed-Secrets sealing key and **reseal** the placeholder `sealedsecret.yaml`
   files — they contain no real secret (`gitops/certs/README.md`).

## Bootstrap order

```
terraform apply
  → ansible: backoffice + loadbalancer
  → ansible: k0s init → add_managers → add_workers
  → ansible: nfs_ha → postgres → node tuning
  → terraform/databasus apply        (optional, DB backups)
  → gitops/bootstrap/bootstrap.sh    (ArgoCD app-of-apps)
```

Full step-by-step with commands: **[`docs/BUILD.md`](docs/BUILD.md)**.
