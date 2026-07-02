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

Same cluster, four providers, **matched vCPU and RAM per node** (exact instance shown in each row).
On-demand, NET (ex-VAT), **730 hrs/mo**, EU regions. Managed control planes (GKE-regional, EKS, DOKS-HA)
bundle HA into their fee; on Hetzner you run three small controllers — priced in below.

> **vCPU class matters, so it's shown.** `d` = dedicated cores, `s` = shared/burstable. Note Hetzner's
> `CCX` rows are **dedicated** while GKE's `e2` is **shared** — i.e. Hetzner is cheaper *and* gives the
> stronger vCPU class in configs B & C.

### Small · non-HA (dev/staging) — 3 nodes @ **4 vCPU / 8 GB** · 1 LB · 100 GB

| Provider | Node × 3 | Ctrl plane | LB | Storage | **Total/mo** |
|---|---|---|--:|--:|--:|
| **Hetzner** | CPX31 · 4/8 s | folded into node ($0) | LB11 $8 | $6 | **≈ $217** |
| GKE | e2-custom-4-8192 · 4/8 s | free zonal ($0) | $18 | $10 | **≈ $292** |
| EKS | c6i.xlarge · 4/8 **d** | $73 (mandatory) | ALB $16 | $10 | **≈ $524** |
| DOKS | Basic · 4/8 s | free ($0) | $12 | $10 | **≈ $166** |

> DigitalOcean's shared droplets undercut Hetzner here, and EKS can't skip its $73 control-plane fee.
> Fine — these are *HA* boilerplates; the fight that matters is below.

### Medium · HA (prod baseline, ≈ this boilerplate's shape) — 4 workers @ **4 vCPU / 16 GB** + HA control plane · 2 LB · 500 GB

| Provider | Worker × 4 | HA ctrl plane | LB | Storage | **Total/mo** | vs Hetzner |
|---|---|---|--:|--:|--:|--:|
| **Hetzner** | CCX23 · 4/16 **d** | 3× CPX21 (~$104) | 2× LB11 $16 | $31 | **≈ $529** | — |
| GKE | e2-standard-4 · 4/16 s | regional $73 | 2× $37 | $50 | **≈ $590** | +12% |
| EKS | m5.xlarge · 4/16 **d** | $73 | 2× ALB $33 | $48 | **≈ $825** | **+56%** |
| DOKS | GP · 4/16 **d** | +$40 | 2× $24 | $50 | **≈ $618** | +17% |

### Large · HA — 8 workers @ **8 vCPU / 32 GB** + HA control plane · 3 LB · 2 TB

| Provider | Worker × 8 | HA ctrl plane | LB | Storage | **Total/mo** | vs Hetzner |
|---|---|---|--:|--:|--:|--:|
| **Hetzner** | CCX33 · 8/32 **d** | 3× CPX31 (~$203) | 3× LB11 $24 | $124 | **≈ $1,568** | — |
| GKE | e2-standard-8 · 8/32 s | regional $73 | 3× $55 | $200 | **≈ $2,050** | +31% |
| EKS | m5.2xlarge · 8/32 **d** | $73 | 3× ALB $49 | $190 | **≈ $2,999** | **+91%** |
| DOKS | GP · 8/32 **d** | +$40 | 3× $36 | $200 | **≈ $2,292** | +46% |

### …then egress makes it a rout

The tables above are *before traffic*. Push **5 TB/mo** outbound — a modest API/app load — and the
gap explodes:

| | Hetzner | DOKS | GKE | EKS |
|---|--:|--:|--:|--:|
| Egress on 5 TB/mo | **$0** | **$0** | ≈ $600 | ≈ $450 |

Hetzner includes **20 TB per server** (overage €1/TB); DigitalOcean pools a free multi-TB allotment.
GKE bills **$0.12/GB** and EKS **$0.09/GB** — so on a busy prod cluster egress alone can cost more than
the entire Hetzner bill.

**The honest asterisks:** (1) "managed" clusters give you a vendor-run, SLA-backed control plane — here
*you* own the three controllers, but Terraform + Ansible + ArgoCD in this repo stand them up and keep
them healed, so the operational delta is small and the savings are not. (2) Prices are provider list
rates as of 2026 (Hetzner post-June-2026 hike), €→$ at ~1.08; the hyperscalers drop 30–60% under
1–3yr commitments/savings plans, which Hetzner doesn't require because its list price is already lower.
(3) GKE's `e2` rows are shared-vCPU; matching Hetzner's dedicated `CCX` with GKE `n2`/`c2` widens the
gap further. Track your real bill with **[hetzner-cost-monitor](https://github.com/prehoy/hetzner-cost-monitor)**.

## Related projects

- **[k0s-hetzner-boilerplate-multizone](https://github.com/prehoy/k0s-hetzner-boilerplate-multizone)** —
  the same stack spread across **three EU datacenters** (survives a full-DC outage), with split LBs and
  round-robin ingress. Reach for it when a single availability zone isn't enough.
- **[hetzner-cost-monitor](https://github.com/prehoy/hetzner-cost-monitor)** — a self-hostable cost
  explorer for Hetzner Cloud (live €/hr burn, month-to-date, spend by project/type/location). Point it
  at the same project to watch what this cluster actually costs; it deploys onto the cluster you just
  built.
