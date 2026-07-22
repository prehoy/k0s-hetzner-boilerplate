# Build runbook — from zero to a converged cluster

Order matters: Terraform provisions the hosts, Ansible turns them into an HA k0s cluster + HA
services, then GitOps fills the cluster.

**`./up` runs all of it**, in the order below. This document is what it does, step by step — read it
to understand the build, to drive one step by hand, or to debug a failed one.

```bash
./up            # everything, from nothing — asks for the secrets it can't generate
./up init       # just write the config/secret files
./up check      # preflight only: tools, config files, tokens
./up k0s        # one step — see `STEPS` in ./up for the list
./up --yes      # don't prompt on `terraform apply`
```

Steps are individually re-runnable, so a failure resumes with `./up <failed-step>` rather than
starting over. `./up --yes` with the config already in place is fully unattended — `init` writes
plaintext (gitignored, 0600) secrets files and `./up` skips the vault prompt for those; if you
`ansible-vault encrypt` them it detects that and asks, or set `ANSIBLE_VAULT_PASSWORD_FILE`.

All `ansible-playbook` commands run from `ansible/` — that's where `ansible.cfg` is, and Ansible only
picks it up from the cwd.

## 0. Prerequisites  (`./up init`)

Installed locally: `terraform`, `ansible`, `kubectl`, `helm`, `kubeseal`, `wg`, `openssl`.

Have these three to hand — they're minted in a web console and can't be generated:

| | Where |
|---|---|
| Hetzner Cloud API token | Console → Security → API tokens (Read & Write) |
| Cloudflare API token | dashboard → My Profile → API Tokens (Zone:DNS:Edit) |
| Hetzner Object Storage keys | Console → Object Storage → Manage credentials (**not** the API token) |

Plus a **domain whose Cloudflare zone already exists** — terraform looks the zone up, it doesn't
create it.

`./up init` asks for those, generates the rest (SSH keypair at `~/.ssh/infra-hetzner`, the keepalived
VRRP password, the pgBackRest cipher passphrase), and writes every config file below. It never
overwrites an existing file, so it's safe to re-run and safe to hand-edit around. Each secret is
asked for once even where several files need it — the Hetzner token alone lands in three places.

> `init` prints the generated `pgbackrest_cipher_pass` once. **Save it outside the cluster** — it
> encrypts every Postgres backup and is stored nowhere else.

`./up check` then verifies tools, files, and tokens before anything is provisioned.

## 1. Terraform — provision Hetzner + DNS  (`./up infra`)

`./up init` writes `secrets.auto.tfvars` (both API tokens) and `terraform.tfvars` (domain,
location); the `.example` files document the format.

```bash
cd terraform
terraform init
terraform apply
```

## 1b. Inventory  (`./up inventory`)

Rendered from terraform state — IPs and DRBD volume ids are never copied by hand:

```bash
terraform -chdir=terraform output -raw ansible_inventory > ansible/inventory
```

`ansible/inventory.example` documents the format; the generated file is gitignored.

## 2. Ansible — backoffice + load balancer first  (`./up backoffice`, `./up vpn`, `./up lb`)

The private nodes have no public IP; you reach them through the WireGuard bastion, and egress/API
HA depends on the LB pair. Bring these up first.

```bash
cd ../ansible
ansible-playbook playbooks/backoffice/backoffice_init/playbook.yaml   # WireGuard + fail2ban + ufw
ansible-playbook playbooks/loadbalancer/playbook.yaml   # keepalived + haproxy + NAT-HA
```

Bring up the WireGuard tunnel (client config fetched to `ansible/wireguard.conf`) before touching the
private API:

```bash
sudo wg-quick up ./wireguard.conf
```

## 3. Ansible — k0s control plane + workers  (`./up k0s`)

```bash
ansible-playbook playbooks/k0s_main/init_k0s/playbook.yaml      # leader controller, fetches kubeconfig
ansible-playbook playbooks/k0s_main/add_managers/playbook.yaml  # controllers 2 & 3 (HA, etcd quorum)
ansible-playbook playbooks/k0s_main/add_workers/playbook.yaml   # workers join via VIP 10.0.0.240
```

## 4. Terraform — backup bucket  (`./up bucket`)

Must come **before** the Postgres playbook: pgBackRest's `stanza-create` needs the bucket to exist.

```bash
cd ../terraform/backups
terraform init && terraform apply     # tfvars written by ./up init
```

## 5. Ansible — stateful HA + node tuning  (`./up stateful`)

The Postgres playbook reads `playbooks/postgres/secrets.yml` (S3 keys + the pgBackRest cipher
passphrase), written by `./up init` — see `playbooks/postgres/README.md`.

```bash
cd ../../ansible
ansible-playbook playbooks/nfs/nfs_ha/playbook.yaml -e hcloud_token=$TOKEN  # DRBD + VIP failover
ansible-playbook playbooks/postgres/playbook.yaml                 # etcd + Patroni + pgBackRest
ansible-playbook playbooks/node_swap/playbook.yaml
ansible-playbook playbooks/node_reservations/playbook.yaml
ansible-playbook playbooks/log_hardening/playbook.yaml
```

## 6. GitOps — ArgoCD app-of-apps  (`./up gitops`)

```bash
export KUBECONFIG=$PWD/main_kubeconfig.conf   # fetched by init_k0s
cd ../gitops/bootstrap
# sealing key must exist before SealedSecrets sync — see ../certs/README.md
./bootstrap.sh
# register the repo deploy key + install Traefik — see bootstrap/README.md
```

## Reaching the cluster afterwards

The k8s API listens on the private VIP `10.0.0.240`. Keep the WireGuard tunnel up (`wg-quick up`)
whenever you run `kubectl`/`helm` against the cluster.
