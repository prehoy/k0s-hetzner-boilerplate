# Backoffice management box

Single-node **Docker Swarm** on the backoffice/NAT server (`backoffice-nat`, public + private),
running the non-critical management stack.

**Roles of this box:** WireGuard admin VPN, external monitoring, bastion.
NAT/egress for the private nodes runs on the **HA LB pair** (route gateway swapped on keepalived
failover — see `ansible/playbooks/loadbalancer`), so this box is **off the critical path**: its
failure costs admin VPN + monitoring UI, not serving or cluster egress.
It still NATs only its own WireGuard clients (`10.200.200.0/24`).

## GitOps: pull-based reconciler + SOPS (no plaintext .env, no third-party controller)
A tiny systemd timer (`reconcile/`) runs an ArgoCD-style loop on the box: `git pull` →
SOPS-decrypt each stack's secrets → `docker stack deploy` every stack under `stacks/`.
- Secrets are **SOPS-encrypted** in git (age recipient
  `age1YOUR_PUBLIC_AGE_RECIPIENT`); the private age key
  lives only at `/etc/infra/age.key`.
- On-box state: `/etc/infra/{age.key,ssh/}`, `/opt/infra` (clone),
  `/usr/local/bin/infra-reconcile.sh`, `infra-reconcile.{service,timer}`.
- Add a stack = drop `stacks/<name>/stack.yml` (+ SOPS `secrets/`) and push. No controller.

## Stacks
| stack | host | notes |
|-------|------|-------|
| traefik | (edge) | TLS via Let's Encrypt + Cloudflare DNS-01 (SOPS Docker secret) |
| swarmpit | `swarmpit.bo.example.com` | Swarm management UI (app + couchdb + influxdb + global agent) |
| gatus | `status.bo.example.com` | code-defined health monitoring (replaced uptime-kuma). Endpoints in `stacks/gatus/config.yaml` (IaC); Brevo SMTP email alerts, password injected as `$SMTP_PASSWORD` from `gatus.env.sops` |
| databasus | `databasus.bo.example.com` | DB backup manager (Postgres/MySQL/Mongo); reaches Patroni nodes over the private net; first-run admin + targets set in the UI |
| wg-portal | `vpn.bo.example.com` | WireGuard admin UI; host-network Swarm service (`cap_add: NET_ADMIN`) managing the kernel `wg0`. Config (admin/session secrets) in `config.yaml.sops`. Traefik reaches it via the file provider (`stacks/traefik/dynamic/wg-portal.yml` → `172.18.0.1:8888`); UFW allows only the docker bridge to `:8888`. |

DNS: point `*.bo.example.com` A-records at the backoffice box public IP (Cloudflare).

## Bootstrap (one-time, on the box)
```bash
# swarm already init'd; secrets at /etc/infra/{age.key,ssh/id_rsa,ssh/known_hosts}
# authenticate Docker Hub so image pulls aren't throttled by the anonymous rate limit:
echo "$DOCKERHUB_PAT" | docker login -u YOUR_DOCKERHUB_USER --password-stdin
git clone <repo> /opt/infra        # via the deploy key
install -m755 /opt/infra/backoffice/reconcile/reconcile.sh /usr/local/bin/infra-reconcile.sh
cp /opt/infra/backoffice/reconcile/infra-reconcile.{service,timer} /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now infra-reconcile.timer
systemctl start infra-reconcile.service   # first run
```
