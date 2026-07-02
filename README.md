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

## What it costs — vs managed GKE / EKS / DOKS

This is the pitch. You get **managed-grade HA** — 3-node control plane, autoscaling, HA
Postgres, HA storage, LB failover — at **self-managed prices**, because Hetzner doesn't charge
a control-plane fee and its egress is effectively free. This repo is what automates the "self-managed"
part away.

Same cluster, four providers. On-demand, NET (ex-VAT), **730 hrs/mo**, EU regions, matched instance
classes (RAM noted where a provider has no exact shape). Managed control planes (GKE-regional,
EKS, DOKS-HA) bundle HA into their fee; on Hetzner you run three small controllers — priced in below.

### Small · non-HA (dev/staging) — 3× 4 vCPU / 8–16 GB · 1 LB · 100 GB

| | **Hetzner (this repo)** | GKE | EKS | DOKS |
|---|--:|--:|--:|--:|
| Monthly | **≈ $217** | $351 | $524 | $166 |

> The one config where DigitalOcean's shared droplets undercut Hetzner. Fine — these are *HA*
> boilerplates; the fight that matters is below.

### Medium · HA (prod baseline, ≈ this boilerplate's shape) — HA control plane + 4× 4 vCPU / 16 GB · 2 LB · 500 GB

| | **Hetzner (this repo)** | GKE | EKS | DOKS |
|---|--:|--:|--:|--:|
| Monthly | **≈ $529** | $590 | $808 | $618 |
| vs Hetzner | — | +12% | **+53%** | +17% |

### Large · HA — HA control plane + 8× 8 vCPU / 32 GB · 3 LB · 2 TB

| | **Hetzner (this repo)** | GKE | EKS | DOKS |
|---|--:|--:|--:|--:|
| Monthly | **≈ $1,568** | $2,050 | $2,999 | $2,292 |
| vs Hetzner | — | +31% | **+91%** | +46% |

### …then egress makes it a rout

The tables above are *before traffic*. Push **5 TB/mo** outbound — a modest API/app load — and the
gap explodes:

| | Hetzner | DOKS | GKE | EKS |
|---|--:|--:|--:|--:|
| Egress on 5 TB/mo | **$0** | **$0** | ≈ $600 | ≈ $450 |

Hetzner includes **20 TB per server** (overage €1/TB); DigitalOcean pools a free multi-TB allotment.
GKE bills **$0.12/GB** and EKS **$0.09/GB** — so on a busy prod cluster egress alone can cost more than
the entire Hetzner bill.

**The honest asterisk:** "managed" clusters give you a vendor-run, SLA-backed control plane. Here *you*
own the three controllers — but Terraform + Ansible + ArgoCD in this repo stand them up and keep them
healed, so the operational delta is small and the savings are not. Prices are list rates as of 2026
(Hetzner post-June-2026 hike); your mileage varies with commitments/savings plans on the hyperscalers.
Track your real bill with **[hetzner-cost-monitor](https://github.com/prehoy/hetzner-cost-monitor)**.

## Related projects

- **[k0s-hetzner-boilerplate-multizone](https://github.com/prehoy/k0s-hetzner-boilerplate-multizone)** —
  the same stack spread across **three EU datacenters** (survives a full-DC outage), with split LBs and
  round-robin ingress. Reach for it when a single availability zone isn't enough.
- **[hetzner-cost-monitor](https://github.com/prehoy/hetzner-cost-monitor)** — a self-hostable cost
  explorer for Hetzner Cloud (live €/hr burn, month-to-date, spend by project/type/location). Point it
  at the same project to watch what this cluster actually costs; it deploys onto the cluster you just
  built.
