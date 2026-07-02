# Build runbook — from zero to a converged cluster

Order matters: Terraform provisions the hosts, Ansible turns them into an HA k0s cluster + HA
services, then GitOps fills the cluster. All `ansible-playbook` commands run from `ansible/` against
your filled-in `inventory` (copy `inventory.example`).

## 0. Prerequisites

- `terraform`, `ansible`, `kubectl`, `helm`, `kubeseal`, `wg` installed locally.
- Hetzner Cloud API token + Cloudflare API token (see `terraform/secrets.auto.tfvars.example`).
- Your SSH public key in `terraform/ssh_keys/admin.pub`, private key at `~/.ssh/infra-hetzner`
  (matches `ansible/ansible.cfg`).

## 1. Terraform — provision Hetzner + DNS

```bash
cd terraform
cp secrets.auto.tfvars.example secrets.auto.tfvars   # fill in tokens
cp terraform.tfvars.example   terraform.tfvars       # set domain, location
terraform init
terraform apply
terraform output                                     # IPs + nfs_drbd_volume_ids -> inventory
```

Copy the outputs into `ansible/inventory` (from `inventory.example`).

## 2. Ansible — backoffice + load balancer first

The private nodes have no public IP; you reach them through the WireGuard bastion, and egress/API
HA depends on the LB pair. Bring these up first.

```bash
cd ../ansible
cp playbooks/loadbalancer/secrets.yml.example playbooks/loadbalancer/secrets.yml   # fill + vault
ansible-playbook playbooks/backoffice/backoffice_init/playbook.yaml   # WireGuard + fail2ban + ufw
ansible-playbook playbooks/loadbalancer/playbook.yaml --ask-vault-pass # keepalived + haproxy + NAT-HA
```

Bring up the WireGuard tunnel (client config fetched to `ansible/wireguard.conf`) before touching the
private API:

```bash
sudo wg-quick up ./wireguard.conf
```

## 3. Ansible — k0s control plane + workers

```bash
ansible-playbook playbooks/k0s_main/init_k0s/playbook.yaml      # leader controller, fetches kubeconfig
ansible-playbook playbooks/k0s_main/add_managers/playbook.yaml  # controllers 2 & 3 (HA, etcd quorum)
ansible-playbook playbooks/k0s_main/add_workers/playbook.yaml   # workers join via VIP 10.0.0.240
```

## 4. Ansible — stateful HA + node tuning

```bash
ansible-playbook playbooks/nfs/nfs_ha/playbook.yaml -e hcloud_token=$HCLOUD_TOKEN  # DRBD + VIP failover
ansible-playbook playbooks/postgres/playbook.yaml                                  # etcd + Patroni (3-node)
ansible-playbook playbooks/node_swap/playbook.yaml
ansible-playbook playbooks/node_reservations/playbook.yaml
ansible-playbook playbooks/log_hardening/playbook.yaml
```

## 5. GitOps — ArgoCD app-of-apps

```bash
export KUBECONFIG=$PWD/main_kubeconfig.conf   # fetched by init_k0s
cd ../gitops/bootstrap
# sealing key must exist before SealedSecrets sync — see ../certs/README.md
./bootstrap.sh
# register the repo deploy key + install Traefik — see bootstrap/README.md
```

## 6. Optional — DB backups

```bash
cd ../../terraform/databasus
cp terraform.tfvars.example terraform.tfvars   # fill in
terraform init && terraform apply
```

## Reaching the cluster afterwards

The k8s API listens on the private VIP `10.0.0.240`. Keep the WireGuard tunnel up (`wg-quick up`)
whenever you run `kubectl`/`helm` against the cluster.
